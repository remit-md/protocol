// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {RemitBounty} from "../src/RemitBounty.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";
import {MockFeeCalculator} from "./helpers/MockFeeCalculator.sol";

/// @title RemitBountyFuzzTest
/// @notice Fuzz/property tests for RemitBounty.sol
contract RemitBountyFuzzTest is Test {
    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    RemitBounty internal bounty;

    address internal poster = makeAddr("poster");
    address internal submitter = makeAddr("submitter");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal admin = makeAddr("admin");

    bytes32 constant TASK_HASH = keccak256("fuzz-task");
    uint64 constant DEADLINE_DELTA = 7 days;

    function setUp() public {
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        bounty = new RemitBounty(address(usdc), address(feeCalc), feeRecipient, admin, address(0));

        usdc.mint(poster, type(uint96).max);
        usdc.mint(submitter, type(uint96).max);
        vm.prank(poster);
        usdc.approve(address(bounty), type(uint256).max);
        vm.prank(submitter);
        usdc.approve(address(bounty), type(uint256).max);
    }

    // =========================================================================
    // Fuzz: awardBounty — all funds accounted for
    // =========================================================================

    /// @dev After award: winnerGets + fee = amount; bond returned to winner.
    ///      Total out = amount + bond = total previously locked.
    function testFuzz_awardBounty_fundsConserved(uint96 amount, uint96 bond) public {
        amount = uint96(bound(amount, RemitTypes.MIN_AMOUNT, 10_000e6));
        bond = uint96(bound(bond, 0, 500e6));

        bytes32 id = keccak256(abi.encodePacked("fuzz-award", amount, bond));

        vm.prank(poster);
        bounty.postBounty(id, amount, uint64(block.timestamp + DEADLINE_DELTA), TASK_HASH, bond, 3);

        // Submitter claims
        bytes32 evidenceHash = keccak256("evidence");
        vm.prank(submitter);
        bounty.submitBounty(id, evidenceHash);

        uint256 posterBefore = usdc.balanceOf(poster);
        uint256 winnerBefore = usdc.balanceOf(submitter);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        vm.prank(poster);
        bounty.awardBounty(id, submitter);

        uint256 winnerGot = usdc.balanceOf(submitter) - winnerBefore;
        uint256 feeGot = usdc.balanceOf(feeRecipient) - feeBefore;
        uint256 posterDelta = posterBefore - usdc.balanceOf(poster); // poster gets nothing back

        // Poster gains nothing (already paid upfront)
        assertEq(posterDelta, 0, "poster should not receive anything on award");

        // Fee + winnerGets (excluding bond) = amount
        // winnerGot includes the bond return, so: (winnerGot - bond) + fee = amount
        uint256 winnerBountyGets = winnerGot > bond ? winnerGot - bond : 0;
        assertEq(winnerBountyGets + feeGot, amount, "winnerGets + fee must equal bounty amount");

        // Contract holds zero
        assertEq(usdc.balanceOf(address(bounty)), 0, "bounty contract must hold zero after award");
    }

    // =========================================================================
    // Fuzz: reclaimBounty — poster gets full amount back (no fee)
    // =========================================================================

    /// @dev When deadline passes with no submission, poster gets exact amount back.
    function testFuzz_reclaimBounty_posterGetsFullAmount(uint96 amount) public {
        amount = uint96(bound(amount, RemitTypes.MIN_AMOUNT, 10_000e6));

        bytes32 id = keccak256(abi.encodePacked("fuzz-reclaim", amount));

        vm.prank(poster);
        // No bond needed (0 bond), no maxClaims restriction (0 = unlimited)
        bounty.postBounty(id, amount, uint64(block.timestamp + DEADLINE_DELTA), TASK_HASH, 0, 0);

        // Warp past deadline with no submission
        vm.warp(block.timestamp + DEADLINE_DELTA + 1);

        uint256 posterBefore = usdc.balanceOf(poster);

        vm.prank(poster);
        bounty.reclaimBounty(id);

        uint256 posterGot = usdc.balanceOf(poster) - posterBefore;
        assertEq(posterGot, amount, "poster must get exact amount back on reclaim (no fee)");
        assertEq(usdc.balanceOf(address(bounty)), 0, "bounty contract must hold zero after reclaim");
    }

    // =========================================================================
    // Fuzz: fee safety cap — fee never exceeds bounty amount
    // =========================================================================

    /// @dev MockFeeCalculator charges 1%. Fee must never exceed amount.
    function testFuzz_feeNeverExceedsAmount(uint96 amount) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        uint96 fee = feeCalc.calculateFee(poster, amount);
        assertLe(fee, amount, "fee must not exceed bounty amount");
        // Winner payout is non-negative
        assertGe(amount - fee, 0);
    }

    // =========================================================================
    // Fuzz: independent bounties never cross-contaminate
    // =========================================================================

    /// @dev Two bounties with different IDs do not share funds.
    function testFuzz_independentBounties_noContamination(uint96 amountA, uint96 amountB) public {
        amountA = uint96(bound(amountA, RemitTypes.MIN_AMOUNT, 5_000e6));
        amountB = uint96(bound(amountB, RemitTypes.MIN_AMOUNT, 5_000e6));

        bytes32 idA = keccak256("bounty-A");
        bytes32 idB = keccak256("bounty-B");

        address posterB = makeAddr("posterB");
        usdc.mint(posterB, type(uint96).max);
        vm.prank(posterB);
        usdc.approve(address(bounty), type(uint256).max);

        vm.prank(poster);
        bounty.postBounty(idA, amountA, uint64(block.timestamp + DEADLINE_DELTA), TASK_HASH, 0, 0);
        vm.prank(posterB);
        bounty.postBounty(idB, amountB, uint64(block.timestamp + DEADLINE_DELTA), TASK_HASH, 0, 0);

        // Contract holds exactly amountA + amountB
        assertEq(usdc.balanceOf(address(bounty)), uint256(amountA) + uint256(amountB));

        // Reclaim A — B should be unaffected
        vm.warp(block.timestamp + DEADLINE_DELTA + 1);
        vm.prank(poster);
        bounty.reclaimBounty(idA);

        assertEq(usdc.balanceOf(address(bounty)), amountB, "B funds must be intact after A reclaim");

        vm.prank(posterB);
        bounty.reclaimBounty(idB);

        assertEq(usdc.balanceOf(address(bounty)), 0, "contract must hold zero after both reclaims");
    }
}
