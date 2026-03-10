// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/test/MockUSDC.sol";
import {MockFeeCalculator} from "./helpers/MockFeeCalculator.sol";
import {RemitBounty} from "../src/RemitBounty.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";
import {RemitErrors} from "../src/libraries/RemitErrors.sol";
import {RemitEvents} from "../src/libraries/RemitEvents.sol";

/// @title RemitBountyRejectionDisputeTest
/// @notice Unit tests for V2 bounty rejection dispute window
contract RemitBountyRejectionDisputeTest is Test {
    MockUSDC public usdc;
    MockFeeCalculator public feeCalc;
    RemitBounty public bounty;

    address public poster;
    address public submitter;
    address public admin;
    address public stranger;
    address public feeRecipient;

    bytes32 constant BID = keccak256("bounty-rjd-001");
    bytes32 constant TASK_HASH = keccak256("do the thing");
    bytes32 constant EVIDENCE = keccak256("here is my proof");

    uint96 constant AMOUNT = 100e6; // $100
    uint96 constant BOND = 10e6; // $10
    uint64 constant DEADLINE_DELTA = 7 days;
    string constant REASON = "output quality below spec";

    function setUp() public {
        vm.warp(1_000_000); // avoid boundary issues at timestamp=1

        poster = makeAddr("poster");
        submitter = makeAddr("submitter");
        admin = makeAddr("admin");
        stranger = makeAddr("stranger");
        feeRecipient = makeAddr("feeRecipient");

        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        bounty = new RemitBounty(address(usdc), address(feeCalc), feeRecipient, admin, address(0));

        usdc.mint(poster, 1000e6);
        vm.prank(poster);
        usdc.approve(address(bounty), type(uint256).max);

        usdc.mint(submitter, 200e6);
        vm.prank(submitter);
        usdc.approve(address(bounty), type(uint256).max);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _post() internal {
        vm.prank(poster);
        bounty.postBounty(BID, AMOUNT, uint64(block.timestamp + DEADLINE_DELTA), TASK_HASH, BOND, 0);
    }

    function _submit() internal {
        vm.prank(submitter);
        bounty.submitBounty(BID, EVIDENCE);
    }

    function _reject(string memory reason) internal {
        vm.prank(poster);
        bounty.rejectSubmission(BID, submitter, reason);
    }

    // =========================================================================
    // rejectSubmission: mandatory reason
    // =========================================================================

    function test_rejectSubmission_withReason_emitsEvent() public {
        _post();
        _submit();

        uint64 windowEnds = uint64(block.timestamp) + RemitTypes.BOUNTY_DISPUTE_WINDOW;

        vm.expectEmit(true, true, true, true);
        emit RemitEvents.BountyRejected(BID, submitter, poster, REASON, windowEnds);

        _reject(REASON);

        // Bond still held in contract
        assertEq(usdc.balanceOf(address(bounty)), AMOUNT + BOND, "bond should still be locked");
        // Status stays Claimed during window
        RemitTypes.Bounty memory b = bounty.getBounty(BID);
        assertEq(uint8(b.status), uint8(RemitTypes.BountyStatus.Claimed));
        assertEq(b.rejectedAt, uint64(block.timestamp));
    }

    function test_rejectSubmission_noReason_reverts() public {
        _post();
        _submit();

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.BountyRejectionNoReason.selector, BID));
        bounty.rejectSubmission(BID, submitter, "");
    }

    // =========================================================================
    // disputeRejection
    // =========================================================================

    function test_disputeRejection_withinWindow_succeeds() public {
        _post();
        _submit();
        _reject(REASON);

        // Dispute within the window
        vm.warp(block.timestamp + RemitTypes.BOUNTY_DISPUTE_WINDOW - 1);
        vm.prank(submitter);
        bounty.disputeRejection(BID);

        RemitTypes.Bounty memory b = bounty.getBounty(BID);
        assertEq(uint8(b.status), uint8(RemitTypes.BountyStatus.Disputed));
    }

    function test_disputeRejection_afterWindow_reverts() public {
        _post();
        _submit();
        _reject(REASON);

        // Past the dispute window
        vm.warp(block.timestamp + RemitTypes.BOUNTY_DISPUTE_WINDOW + 1);
        vm.prank(submitter);
        vm.expectRevert();
        bounty.disputeRejection(BID);
    }

    function test_disputeRejection_notSubmitter_reverts() public {
        _post();
        _submit();
        _reject(REASON);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        bounty.disputeRejection(BID);
    }

    function test_disputeRejection_withoutRejection_reverts() public {
        _post();
        _submit();
        // No rejection called — rejectedAt == 0

        vm.prank(submitter);
        vm.expectRevert();
        bounty.disputeRejection(BID);
    }

    // =========================================================================
    // finalizeRejection
    // =========================================================================

    function test_finalizeRejection_afterWindow_forfeitsBond() public {
        _post();
        _submit();
        _reject(REASON);

        uint256 posterBefore = usdc.balanceOf(poster);

        // Warp past dispute window
        vm.warp(block.timestamp + RemitTypes.BOUNTY_DISPUTE_WINDOW + 1);
        bounty.finalizeRejection(BID); // callable by anyone

        assertEq(usdc.balanceOf(poster) - posterBefore, BOND, "poster should receive forfeited bond");
        assertEq(usdc.balanceOf(address(bounty)), AMOUNT, "contract should still hold bounty amount");
        RemitTypes.Bounty memory b = bounty.getBounty(BID);
        assertEq(uint8(b.status), uint8(RemitTypes.BountyStatus.Open), "bounty should reopen");
        assertEq(b.rejectedAt, 0, "rejectedAt should be cleared");
        assertEq(bounty.getPendingSubmitter(BID), address(0), "pending submitter cleared");
        assertEq(bounty.getSubmission(BID, submitter), bytes32(0), "submission cleared");
    }

    function test_finalizeRejection_beforeWindow_reverts() public {
        _post();
        _submit();
        _reject(REASON);

        // Still within window
        vm.warp(block.timestamp + RemitTypes.BOUNTY_DISPUTE_WINDOW - 1);
        vm.expectRevert();
        bounty.finalizeRejection(BID);
    }

    // =========================================================================
    // resolveRejectionDispute
    // =========================================================================

    function test_resolveRejectionDispute_submitterWins() public {
        _post();
        _submit();
        _reject(REASON);
        vm.prank(submitter);
        bounty.disputeRejection(BID);

        uint256 submitterBefore = usdc.balanceOf(submitter);
        uint96 fee = uint96((uint256(AMOUNT) * 100) / 10_000); // 1%
        uint96 winnerGets = AMOUNT - fee;

        vm.prank(admin);
        bounty.resolveRejectionDispute(BID, true);

        assertEq(usdc.balanceOf(submitter) - submitterBefore, winnerGets + BOND, "submitter gets reward + bond");
        assertEq(usdc.balanceOf(feeRecipient), fee, "fee recipient gets fee");
        assertEq(usdc.balanceOf(address(bounty)), 0, "contract holds no funds");
        RemitTypes.Bounty memory b = bounty.getBounty(BID);
        assertEq(uint8(b.status), uint8(RemitTypes.BountyStatus.Awarded));
        assertEq(b.winner, submitter);
    }

    function test_resolveRejectionDispute_posterWins() public {
        _post();
        _submit();
        _reject(REASON);
        vm.prank(submitter);
        bounty.disputeRejection(BID);

        uint256 posterBefore = usdc.balanceOf(poster);

        vm.prank(admin);
        bounty.resolveRejectionDispute(BID, false);

        assertEq(usdc.balanceOf(poster) - posterBefore, BOND, "poster receives forfeited bond");
        assertEq(usdc.balanceOf(address(bounty)), AMOUNT, "bounty amount still locked");
        RemitTypes.Bounty memory b = bounty.getBounty(BID);
        assertEq(uint8(b.status), uint8(RemitTypes.BountyStatus.Open), "bounty re-opens");
    }

    function test_resolveRejectionDispute_notAdmin_reverts() public {
        _post();
        _submit();
        _reject(REASON);
        vm.prank(submitter);
        bounty.disputeRejection(BID);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        bounty.resolveRejectionDispute(BID, true);
    }
}
