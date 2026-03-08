// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {RemitBounty} from "../src/RemitBounty.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";
import {RemitErrors} from "../src/libraries/RemitErrors.sol";
import {RemitEvents} from "../src/libraries/RemitEvents.sol";
import {MockFeeCalculator} from "./helpers/MockFeeCalculator.sol";

/// @title RemitBountyTest
/// @notice Unit tests for RemitBounty.sol
contract RemitBountyTest is Test {
    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    RemitBounty internal bounty;

    address internal poster = makeAddr("poster");
    address internal submitter = makeAddr("submitter");
    address internal submitter2 = makeAddr("submitter2");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal stranger = makeAddr("stranger");

    bytes32 constant BOUNTY_ID = keccak256("bounty-1");
    bytes32 constant TASK_HASH = keccak256("do the thing");
    bytes32 constant EVIDENCE = keccak256("here is proof");
    bytes32 constant EVIDENCE_2 = keccak256("alternate proof");

    uint96 constant AMOUNT = 100e6; // $100 USDC
    uint96 constant BOND = 5e6; // $5 USDC bond
    uint64 constant DEADLINE_DELTA = 7 days;
    uint96 constant MINT = 200e6;

    function setUp() public {
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        bounty = new RemitBounty(address(usdc), address(feeCalc), feeRecipient);

        usdc.mint(poster, MINT);
        vm.prank(poster);
        usdc.approve(address(bounty), type(uint256).max);

        usdc.mint(submitter, MINT);
        vm.prank(submitter);
        usdc.approve(address(bounty), type(uint256).max);

        usdc.mint(submitter2, MINT);
        vm.prank(submitter2);
        usdc.approve(address(bounty), type(uint256).max);
    }

    // =========================================================================
    // postBounty
    // =========================================================================

    function test_postBounty_happyPath() public {
        vm.expectEmit(true, true, false, true);
        emit RemitEvents.BountyPosted(BOUNTY_ID, poster, AMOUNT, uint64(block.timestamp + DEADLINE_DELTA), TASK_HASH);

        vm.prank(poster);
        bounty.postBounty(BOUNTY_ID, AMOUNT, uint64(block.timestamp + DEADLINE_DELTA), TASK_HASH, BOND, 3);

        RemitTypes.Bounty memory b = bounty.getBounty(BOUNTY_ID);
        assertEq(b.poster, poster);
        assertEq(b.amount, AMOUNT);
        assertEq(b.submissionBond, BOND);
        assertEq(b.maxAttempts, 3);
        assertEq(b.attemptCount, 0);
        assertEq(uint8(b.status), uint8(RemitTypes.BountyStatus.Open));
        assertEq(usdc.balanceOf(address(bounty)), AMOUNT);
    }

    function test_postBounty_revert_duplicate() public {
        vm.prank(poster);
        bounty.postBounty(BOUNTY_ID, AMOUNT, uint64(block.timestamp + DEADLINE_DELTA), TASK_HASH, 0, 0);

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.EscrowAlreadyFunded.selector, BOUNTY_ID));
        bounty.postBounty(BOUNTY_ID, AMOUNT, uint64(block.timestamp + DEADLINE_DELTA), TASK_HASH, 0, 0);
    }

    function test_postBounty_revert_belowMinimum() public {
        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(RemitErrors.BelowMinimum.selector, RemitTypes.MIN_AMOUNT - 1, RemitTypes.MIN_AMOUNT)
        );
        bounty.postBounty(
            BOUNTY_ID, RemitTypes.MIN_AMOUNT - 1, uint64(block.timestamp + DEADLINE_DELTA), TASK_HASH, 0, 0
        );
    }

    function test_postBounty_revert_invalidDeadline() public {
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.InvalidTimeout.selector, block.timestamp));
        bounty.postBounty(BOUNTY_ID, AMOUNT, uint64(block.timestamp), TASK_HASH, 0, 0);
    }

    function test_postBounty_revert_zeroTaskHash() public {
        vm.prank(poster);
        vm.expectRevert(RemitErrors.ZeroAmount.selector);
        bounty.postBounty(BOUNTY_ID, AMOUNT, uint64(block.timestamp + DEADLINE_DELTA), bytes32(0), 0, 0);
    }

    // =========================================================================
    // submitBounty
    // =========================================================================

    function test_submitBounty_happyPath() public {
        _postBounty(BOND, 3);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.BountyClaimed(BOUNTY_ID, submitter, EVIDENCE);

        vm.prank(submitter);
        bounty.submitBounty(BOUNTY_ID, EVIDENCE);

        RemitTypes.Bounty memory b = bounty.getBounty(BOUNTY_ID);
        assertEq(uint8(b.status), uint8(RemitTypes.BountyStatus.Claimed));
        assertEq(b.attemptCount, 1);
        assertEq(bounty.getPendingSubmitter(BOUNTY_ID), submitter);
        assertEq(bounty.getSubmission(BOUNTY_ID, submitter), EVIDENCE);
        assertEq(usdc.balanceOf(address(bounty)), AMOUNT + BOND);
    }

    function test_submitBounty_noBond() public {
        _postBounty(0, 0); // no bond, unlimited attempts

        uint256 submitterBefore = usdc.balanceOf(submitter);
        vm.prank(submitter);
        bounty.submitBounty(BOUNTY_ID, EVIDENCE);

        assertEq(usdc.balanceOf(submitter), submitterBefore); // no bond deducted
    }

    function test_submitBounty_revert_notOpen() public {
        _postBounty(0, 0);

        vm.prank(submitter);
        bounty.submitBounty(BOUNTY_ID, EVIDENCE);

        // Status is now Claimed — second submission blocked
        vm.prank(submitter2);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.BountyClaimed.selector, BOUNTY_ID));
        bounty.submitBounty(BOUNTY_ID, EVIDENCE_2);
    }

    function test_submitBounty_revert_pastDeadline() public {
        _postBounty(0, 0);
        vm.warp(block.timestamp + DEADLINE_DELTA + 1);

        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.BountyExpired.selector, BOUNTY_ID));
        bounty.submitBounty(BOUNTY_ID, EVIDENCE);
    }

    function test_submitBounty_revert_maxAttempts() public {
        _postBounty(0, 1); // max 1 attempt

        vm.prank(submitter);
        bounty.submitBounty(BOUNTY_ID, EVIDENCE);

        // Reject to reset to Open
        vm.prank(poster);
        bounty.rejectSubmission(BOUNTY_ID, submitter);

        // Now maxAttempts reached (attemptCount == 1 == maxAttempts)
        vm.prank(submitter2);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.BountyMaxAttempts.selector, BOUNTY_ID));
        bounty.submitBounty(BOUNTY_ID, EVIDENCE_2);
    }

    function test_submitBounty_revert_selfSubmit() public {
        _postBounty(0, 0);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.SelfPayment.selector, poster));
        bounty.submitBounty(BOUNTY_ID, EVIDENCE);
    }

    function test_submitBounty_revert_zeroEvidence() public {
        _postBounty(0, 0);
        vm.prank(submitter);
        vm.expectRevert(RemitErrors.ZeroAmount.selector);
        bounty.submitBounty(BOUNTY_ID, bytes32(0));
    }

    // =========================================================================
    // awardBounty
    // =========================================================================

    function test_awardBounty_happyPath() public {
        _postBounty(BOND, 0);

        vm.prank(submitter);
        bounty.submitBounty(BOUNTY_ID, EVIDENCE);

        uint256 submitterBefore = usdc.balanceOf(submitter);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        uint96 fee = AMOUNT / 100; // 1%
        uint96 winnerGets = AMOUNT - fee;

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.BountyAwarded(BOUNTY_ID, submitter, winnerGets, fee);

        vm.prank(poster);
        bounty.awardBounty(BOUNTY_ID, submitter);

        assertEq(usdc.balanceOf(submitter), submitterBefore + winnerGets + BOND);
        assertEq(usdc.balanceOf(feeRecipient), feeBefore + fee);
        assertEq(usdc.balanceOf(address(bounty)), 0);

        RemitTypes.Bounty memory b = bounty.getBounty(BOUNTY_ID);
        assertEq(uint8(b.status), uint8(RemitTypes.BountyStatus.Awarded));
        assertEq(b.winner, submitter);
    }

    function test_awardBounty_revert_notPoster() public {
        _postBounty(0, 0);
        vm.prank(submitter);
        bounty.submitBounty(BOUNTY_ID, EVIDENCE);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        bounty.awardBounty(BOUNTY_ID, submitter);
    }

    function test_awardBounty_revert_notClaimed() public {
        _postBounty(0, 0);

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.AlreadyClosed.selector, BOUNTY_ID));
        bounty.awardBounty(BOUNTY_ID, submitter);
    }

    function test_awardBounty_revert_wrongWinner() public {
        _postBounty(0, 0);
        vm.prank(submitter);
        bounty.submitBounty(BOUNTY_ID, EVIDENCE);

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, submitter2));
        bounty.awardBounty(BOUNTY_ID, submitter2);
    }

    // =========================================================================
    // rejectSubmission
    // =========================================================================

    function test_rejectSubmission_bondForfeitedToPoster() public {
        _postBounty(BOND, 3);

        vm.prank(submitter);
        bounty.submitBounty(BOUNTY_ID, EVIDENCE);

        uint256 posterBefore = usdc.balanceOf(poster);

        vm.prank(poster);
        bounty.rejectSubmission(BOUNTY_ID, submitter);

        assertEq(usdc.balanceOf(poster), posterBefore + BOND); // bond forfeited to poster
        assertEq(uint8(bounty.getBounty(BOUNTY_ID).status), uint8(RemitTypes.BountyStatus.Open));
        assertEq(bounty.getPendingSubmitter(BOUNTY_ID), address(0));
        assertEq(bounty.getSubmission(BOUNTY_ID, submitter), bytes32(0)); // cleared
    }

    function test_rejectSubmission_andResubmit() public {
        _postBounty(BOND, 3);

        // First submitter
        vm.prank(submitter);
        bounty.submitBounty(BOUNTY_ID, EVIDENCE);
        vm.prank(poster);
        bounty.rejectSubmission(BOUNTY_ID, submitter);

        // Second submitter
        vm.prank(submitter2);
        bounty.submitBounty(BOUNTY_ID, EVIDENCE_2);

        assertEq(bounty.getPendingSubmitter(BOUNTY_ID), submitter2);
        assertEq(uint8(bounty.getBounty(BOUNTY_ID).status), uint8(RemitTypes.BountyStatus.Claimed));
    }

    function test_rejectSubmission_revert_notPoster() public {
        _postBounty(0, 0);
        vm.prank(submitter);
        bounty.submitBounty(BOUNTY_ID, EVIDENCE);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        bounty.rejectSubmission(BOUNTY_ID, submitter);
    }

    function test_rejectSubmission_revert_wrongSubmitter() public {
        _postBounty(0, 0);
        vm.prank(submitter);
        bounty.submitBounty(BOUNTY_ID, EVIDENCE);

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, submitter2));
        bounty.rejectSubmission(BOUNTY_ID, submitter2);
    }

    // =========================================================================
    // reclaimBounty
    // =========================================================================

    function test_reclaimBounty_afterDeadline() public {
        _postBounty(0, 0);
        vm.warp(block.timestamp + DEADLINE_DELTA + 1);

        uint256 posterBefore = usdc.balanceOf(poster);

        vm.expectEmit(true, false, false, true);
        emit RemitEvents.BountyExpired(BOUNTY_ID, AMOUNT);

        vm.prank(poster);
        bounty.reclaimBounty(BOUNTY_ID);

        assertEq(usdc.balanceOf(poster), posterBefore + AMOUNT);
        assertEq(usdc.balanceOf(address(bounty)), 0);
        assertEq(uint8(bounty.getBounty(BOUNTY_ID).status), uint8(RemitTypes.BountyStatus.Expired));
    }

    function test_reclaimBounty_claimedAtDeadline_bondReturnedToSubmitter() public {
        _postBounty(BOND, 0);
        vm.prank(submitter);
        bounty.submitBounty(BOUNTY_ID, EVIDENCE);

        vm.warp(block.timestamp + DEADLINE_DELTA + 1);

        uint256 submitterBefore = usdc.balanceOf(submitter);
        uint256 posterBefore = usdc.balanceOf(poster);

        vm.prank(poster);
        bounty.reclaimBounty(BOUNTY_ID);

        // Poster gets bounty amount back
        assertEq(usdc.balanceOf(poster), posterBefore + AMOUNT);
        // Pending submitter gets bond returned (good-faith edge case)
        assertEq(usdc.balanceOf(submitter), submitterBefore + BOND);
        assertEq(usdc.balanceOf(address(bounty)), 0);
    }

    function test_reclaimBounty_revert_notDeadline() public {
        _postBounty(0, 0);

        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(RemitErrors.InvalidTimeout.selector, uint64(block.timestamp + DEADLINE_DELTA))
        );
        bounty.reclaimBounty(BOUNTY_ID);
    }

    function test_reclaimBounty_revert_alreadyAwarded() public {
        _postBounty(0, 0);
        vm.prank(submitter);
        bounty.submitBounty(BOUNTY_ID, EVIDENCE);
        vm.prank(poster);
        bounty.awardBounty(BOUNTY_ID, submitter);

        vm.warp(block.timestamp + DEADLINE_DELTA + 1);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.AlreadyClosed.selector, BOUNTY_ID));
        bounty.reclaimBounty(BOUNTY_ID);
    }

    function test_reclaimBounty_revert_alreadyExpired() public {
        _postBounty(0, 0);
        vm.warp(block.timestamp + DEADLINE_DELTA + 1);
        vm.prank(poster);
        bounty.reclaimBounty(BOUNTY_ID);

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.AlreadyClosed.selector, BOUNTY_ID));
        bounty.reclaimBounty(BOUNTY_ID);
    }

    function test_reclaimBounty_revert_notPoster() public {
        _postBounty(0, 0);
        vm.warp(block.timestamp + DEADLINE_DELTA + 1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        bounty.reclaimBounty(BOUNTY_ID);
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    function test_constructor_revert_zeroUsdc() public {
        vm.expectRevert(RemitErrors.ZeroAddress.selector);
        new RemitBounty(address(0), address(feeCalc), feeRecipient);
    }

    function test_constructor_revert_zeroFeeCalc() public {
        vm.expectRevert(RemitErrors.ZeroAddress.selector);
        new RemitBounty(address(usdc), address(0), feeRecipient);
    }

    function test_constructor_revert_zeroFeeRecipient() public {
        vm.expectRevert(RemitErrors.ZeroAddress.selector);
        new RemitBounty(address(usdc), address(feeCalc), address(0));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _postBounty(uint96 bond, uint8 maxAttempts) internal {
        vm.prank(poster);
        bounty.postBounty(BOUNTY_ID, AMOUNT, uint64(block.timestamp + DEADLINE_DELTA), TASK_HASH, bond, maxAttempts);
    }
}
