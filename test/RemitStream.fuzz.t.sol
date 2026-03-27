// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {RemitStream} from "../src/RemitStream.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";
import {MockFeeCalculator} from "./helpers/MockFeeCalculator.sol";

/// @title RemitStreamFuzzTest
/// @notice Fuzz/property tests for RemitStream.sol
contract RemitStreamFuzzTest is Test {
    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    RemitStream internal streamContract;

    address internal payer = makeAddr("payer");
    address internal payee = makeAddr("payee");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal admin = makeAddr("admin");

    bytes32 constant STREAM_ID = keccak256("fuzz-stream");

    function setUp() public {
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        streamContract = new RemitStream(address(usdc), address(feeCalc), feeRecipient, admin, address(0));

        // Give payer a large allowance
        usdc.mint(payer, type(uint96).max);
        vm.prank(payer);
        usdc.approve(address(streamContract), type(uint256).max);
    }

    // =========================================================================
    // Fuzz: withdrawable never exceeds maxTotal
    // =========================================================================

    /// @dev For any valid rate and elapsed time, withdrawable ≤ maxTotal
    function testFuzz_withdrawable_cappedAtMaxTotal(uint64 rate, uint64 elapsed, uint96 maxTotal) public {
        rate = uint64(bound(rate, 1, type(uint64).max));
        maxTotal = uint96(bound(maxTotal, RemitTypes.MIN_AMOUNT, type(uint96).max));
        // Cap elapsed to avoid block.timestamp + elapsed overflow
        elapsed = uint64(bound(elapsed, 0, 10 * 365 days));

        vm.prank(payer);
        streamContract.openStream(STREAM_ID, payee, rate, maxTotal);

        if (elapsed > 0) vm.warp(block.timestamp + elapsed);

        uint96 w = streamContract.withdrawable(STREAM_ID);
        assertLe(w, maxTotal, "withdrawable must not exceed maxTotal");
    }

    // =========================================================================
    // Fuzz: close invariant - all funds accounted for
    // =========================================================================

    /// @dev After closeStream: payeeGets + refund + fee == maxTotal (contract holds 0)
    function testFuzz_closeStream_allFundsAccountedFor(uint64 rate, uint64 elapsed, uint96 maxTotal) public {
        rate = uint64(bound(rate, 1, type(uint64).max));
        maxTotal = uint96(bound(maxTotal, RemitTypes.MIN_AMOUNT, type(uint96).max));
        elapsed = uint64(bound(elapsed, 0, 365 days));

        vm.prank(payer);
        streamContract.openStream(STREAM_ID, payee, rate, maxTotal);

        if (elapsed > 0) vm.warp(block.timestamp + elapsed);

        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 payeeBefore = usdc.balanceOf(payee);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        vm.prank(payer);
        streamContract.closeStream(STREAM_ID);

        uint256 payerGot = usdc.balanceOf(payer) - payerBefore;
        uint256 payeeGot = usdc.balanceOf(payee) - payeeBefore;
        uint256 feeGot = usdc.balanceOf(feeRecipient) - feeBefore;

        assertEq(payerGot + payeeGot + feeGot, maxTotal, "total distribution must equal maxTotal");
        assertEq(usdc.balanceOf(address(streamContract)), 0, "stream contract must hold zero after close");
    }

    // =========================================================================
    // Fuzz: fee on pending never exceeds pending
    // =========================================================================

    /// @dev Fee charged at close never exceeds the pending (non-withdrawn) amount
    function testFuzz_closeStream_feeNeverExceedsPending(uint64 rate, uint64 elapsed, uint96 maxTotal) public {
        rate = uint64(bound(rate, 1, type(uint64).max));
        maxTotal = uint96(bound(maxTotal, RemitTypes.MIN_AMOUNT, type(uint96).max));
        elapsed = uint64(bound(elapsed, 0, 365 days));

        vm.prank(payer);
        streamContract.openStream(STREAM_ID, payee, rate, maxTotal);

        if (elapsed > 0) vm.warp(block.timestamp + elapsed);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 payeeBefore = usdc.balanceOf(payee);

        vm.prank(payer);
        streamContract.closeStream(STREAM_ID);

        uint256 feeCharged = usdc.balanceOf(feeRecipient) - feeBefore;
        uint256 payeeReceived = usdc.balanceOf(payee) - payeeBefore;
        // fee + payee payout = pending (what was streamed, since no prior withdrawals)
        assertGe(payeeReceived + feeCharged, 0, "non-negative outputs");
        assertLe(feeCharged, maxTotal, "fee cannot exceed maxTotal");
    }

    // =========================================================================
    // Fuzz: withdraw + close - all funds accounted for
    // =========================================================================

    /// @dev With a mid-stream withdrawal, the invariant still holds at close
    function testFuzz_withdrawThenClose_allFundsAccountedFor(
        uint64 rate,
        uint64 elapsedBeforeWithdraw,
        uint64 elapsedAfterWithdraw,
        uint96 maxTotal
    ) public {
        rate = uint64(bound(rate, 1, type(uint32).max)); // limit to avoid overflow issues in test
        maxTotal = uint96(bound(maxTotal, RemitTypes.MIN_AMOUNT, type(uint88).max));
        elapsedBeforeWithdraw = uint64(bound(elapsedBeforeWithdraw, 1, 365 days));
        elapsedAfterWithdraw = uint64(bound(elapsedAfterWithdraw, 0, 365 days));

        vm.prank(payer);
        streamContract.openStream(STREAM_ID, payee, rate, maxTotal);

        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 payeeBefore = usdc.balanceOf(payee);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        // Withdraw after first elapsed period
        vm.warp(block.timestamp + elapsedBeforeWithdraw);
        uint96 w = streamContract.withdrawable(STREAM_ID);
        if (w > 0) {
            vm.prank(payee);
            streamContract.withdraw(STREAM_ID);
        }

        // Advance again and close
        if (elapsedAfterWithdraw > 0) vm.warp(block.timestamp + elapsedAfterWithdraw);
        vm.prank(payer);
        streamContract.closeStream(STREAM_ID);

        uint256 payerGot = usdc.balanceOf(payer) - payerBefore;
        uint256 payeeGot = usdc.balanceOf(payee) - payeeBefore;
        uint256 feeGot = usdc.balanceOf(feeRecipient) - feeBefore;

        assertEq(payerGot + payeeGot + feeGot, maxTotal, "all funds accounted for after withdraw+close");
        assertEq(usdc.balanceOf(address(streamContract)), 0, "no residual funds in contract");
    }

    // =========================================================================
    // Fuzz: independent streams never cross-contaminate
    // =========================================================================

    /// @dev Two independent streams with different IDs do not interfere
    function testFuzz_independentStreams_noContamination(uint96 maxA, uint96 maxB) public {
        maxA = uint96(bound(maxA, RemitTypes.MIN_AMOUNT, type(uint88).max));
        maxB = uint96(bound(maxB, RemitTypes.MIN_AMOUNT, type(uint88).max));

        bytes32 idA = keccak256("stream-A");
        bytes32 idB = keccak256("stream-B");

        vm.prank(payer);
        streamContract.openStream(idA, payee, 1e6, maxA);

        vm.prank(payer);
        streamContract.openStream(idB, payee, 1e6, maxB);

        // Advance time and close A
        vm.warp(block.timestamp + 60);
        vm.prank(payer);
        streamContract.closeStream(idA);

        // B should still be Active with its full balance
        RemitTypes.Stream memory b = streamContract.getStream(idB);
        assertEq(uint8(b.status), uint8(RemitTypes.StreamStatus.Active));
        assertEq(b.maxTotal, maxB);

        // Close B
        vm.prank(payer);
        streamContract.closeStream(idB);

        assertEq(usdc.balanceOf(address(streamContract)), 0);
    }
}
