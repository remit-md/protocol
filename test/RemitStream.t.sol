// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {RemitStream} from "../src/RemitStream.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";
import {RemitErrors} from "../src/libraries/RemitErrors.sol";
import {RemitEvents} from "../src/libraries/RemitEvents.sol";
import {MockFeeCalculator} from "./helpers/MockFeeCalculator.sol";

/// @title RemitStreamTest
/// @notice Unit tests for RemitStream.sol
contract RemitStreamTest is Test {
    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    RemitStream internal stream;

    address internal payer = makeAddr("payer");
    address internal payee = makeAddr("payee");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal admin = makeAddr("streamAdmin");
    address internal stranger = makeAddr("stranger");

    bytes32 constant STREAM_ID = keccak256("stream-1");

    /// @dev 10 USDC/second × 3600 seconds = $36,000 max
    uint64 constant RATE = 10e6; // $10 USDC/second
    uint96 constant MAX_TOTAL = 36_000e6; // $36,000 USDC cap
    uint96 constant MINT_AMOUNT = 100_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        stream = new RemitStream(address(usdc), address(feeCalc), feeRecipient, admin, address(0));

        usdc.mint(payer, MINT_AMOUNT);
        vm.prank(payer);
        usdc.approve(address(stream), type(uint256).max);

        usdc.mint(payee, MINT_AMOUNT);
        vm.prank(payee);
        usdc.approve(address(stream), type(uint256).max);
    }

    // =========================================================================
    // openStream
    // =========================================================================

    function test_openStream_happyPath() public {
        vm.expectEmit(true, true, true, true);
        emit RemitEvents.StreamOpened(STREAM_ID, payer, payee, RATE, MAX_TOTAL);

        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        RemitTypes.Stream memory s = stream.getStream(STREAM_ID);
        assertEq(s.payer, payer);
        assertEq(s.payee, payee);
        assertEq(s.ratePerSecond, RATE);
        assertEq(s.maxTotal, MAX_TOTAL);
        assertEq(s.withdrawn, 0);
        assertEq(s.startedAt, block.timestamp);
        assertEq(s.closedAt, 0);
        assertEq(uint8(s.status), uint8(RemitTypes.StreamStatus.Active));

        // Contract holds maxTotal
        assertEq(usdc.balanceOf(address(stream)), MAX_TOTAL);
    }

    function test_openStream_revert_duplicate() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.EscrowAlreadyFunded.selector, STREAM_ID));
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);
    }

    function test_openStream_revert_zeroPayee() public {
        vm.prank(payer);
        vm.expectRevert(RemitErrors.ZeroAddress.selector);
        stream.openStream(STREAM_ID, address(0), RATE, MAX_TOTAL);
    }

    function test_openStream_revert_selfPayment() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.SelfPayment.selector, payer));
        stream.openStream(STREAM_ID, payer, RATE, MAX_TOTAL);
    }

    function test_openStream_revert_belowMinimum() public {
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(RemitErrors.BelowMinimum.selector, RemitTypes.MIN_AMOUNT - 1, RemitTypes.MIN_AMOUNT)
        );
        stream.openStream(STREAM_ID, payee, RATE, RemitTypes.MIN_AMOUNT - 1);
    }

    function test_openStream_revert_zeroRate() public {
        vm.prank(payer);
        vm.expectRevert(RemitErrors.ZeroAmount.selector);
        stream.openStream(STREAM_ID, payee, 0, MAX_TOTAL);
    }

    // =========================================================================
    // withdrawable (view)
    // =========================================================================

    function test_withdrawable_beforeAnyTime() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        // At t=0 (same block as open), nothing accrued
        assertEq(stream.withdrawable(STREAM_ID), 0);
    }

    function test_withdrawable_afterOneHour() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        vm.warp(block.timestamp + 1 hours);
        // RATE = 10e6 USDC/s × 3600s = 36_000e6 = MAX_TOTAL (at the cap)
        assertEq(stream.withdrawable(STREAM_ID), MAX_TOTAL);
    }

    function test_withdrawable_partialAccrual() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        vm.warp(block.timestamp + 100); // 100 seconds
        // 10e6 * 100 = 1_000e6 USDC
        assertEq(stream.withdrawable(STREAM_ID), 1_000e6);
    }

    function test_withdrawable_cappedAtMaxTotal() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        // Warp far past when maxTotal would be hit
        vm.warp(block.timestamp + 10 hours);
        assertEq(stream.withdrawable(STREAM_ID), MAX_TOTAL);
    }

    function test_withdrawable_zeroForNonexistent() public {
        assertEq(stream.withdrawable(keccak256("nonexistent")), 0);
    }

    function test_withdrawable_zeroAfterClose() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);
        vm.warp(block.timestamp + 100);
        vm.prank(payer);
        stream.closeStream(STREAM_ID);

        assertEq(stream.withdrawable(STREAM_ID), 0);
    }

    // =========================================================================
    // withdraw
    // =========================================================================

    function test_withdraw_happyPath() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        uint64 elapsed = 100; // 100 seconds
        vm.warp(block.timestamp + elapsed);
        uint96 expected = uint96(uint256(RATE) * elapsed); // 1_000e6

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.StreamWithdrawal(STREAM_ID, payee, expected);

        vm.prank(payee);
        stream.withdraw(STREAM_ID);

        assertEq(usdc.balanceOf(payee), MINT_AMOUNT + expected);
        assertEq(stream.getStream(STREAM_ID).withdrawn, expected);
    }

    function test_withdraw_multipleWithdrawals() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        // First withdrawal after 100s
        vm.warp(block.timestamp + 100);
        uint96 first = uint96(uint256(RATE) * 100); // 1_000e6
        vm.prank(payee);
        stream.withdraw(STREAM_ID);
        assertEq(stream.getStream(STREAM_ID).withdrawn, first);

        // Second withdrawal after another 50s
        vm.warp(block.timestamp + 50);
        uint96 second = uint96(uint256(RATE) * 50); // 500e6
        vm.prank(payee);
        stream.withdraw(STREAM_ID);
        assertEq(stream.getStream(STREAM_ID).withdrawn, first + second);
    }

    function test_withdraw_revert_notPayee() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        vm.warp(block.timestamp + 100);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        stream.withdraw(STREAM_ID);
    }

    function test_withdraw_revert_notFound() public {
        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.StreamNotFound.selector, STREAM_ID));
        stream.withdraw(STREAM_ID);
    }

    function test_withdraw_revert_alreadyClosed() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);
        vm.warp(block.timestamp + 100);
        vm.prank(payer);
        stream.closeStream(STREAM_ID);

        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.AlreadyClosed.selector, STREAM_ID));
        stream.withdraw(STREAM_ID);
    }

    function test_withdraw_revert_nothingAccrued() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);
        // No time elapsed — nothing accrued yet
        vm.prank(payee);
        vm.expectRevert(RemitErrors.ZeroAmount.selector);
        stream.withdraw(STREAM_ID);
    }

    // =========================================================================
    // closeStream
    // =========================================================================

    function test_closeStream_byPayerAfterSomeTime() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        uint64 elapsed = 100; // 100 seconds
        vm.warp(block.timestamp + elapsed);

        // totalStreamed = RATE * elapsed = 1_000e6
        uint96 totalStreamed = uint96(uint256(RATE) * elapsed);
        uint96 refund = MAX_TOTAL - totalStreamed;
        // fee is on "pending" (all of totalStreamed since no prior withdrawals)
        // MockFeeCalculator returns 1% (100 bps)
        uint96 fee = totalStreamed / 100;
        uint96 payeeGets = totalStreamed - fee;

        uint96 payerBefore = uint96(usdc.balanceOf(payer));
        uint96 payeeBefore = uint96(usdc.balanceOf(payee));
        uint96 feeBefore = uint96(usdc.balanceOf(feeRecipient));

        vm.expectEmit(true, false, false, true);
        emit RemitEvents.StreamClosed(STREAM_ID, totalStreamed, refund, fee);

        vm.prank(payer);
        stream.closeStream(STREAM_ID);

        assertEq(usdc.balanceOf(payer), payerBefore + refund);
        assertEq(usdc.balanceOf(payee), payeeBefore + payeeGets);
        assertEq(usdc.balanceOf(feeRecipient), feeBefore + fee);
        assertEq(usdc.balanceOf(address(stream)), 0);

        RemitTypes.Stream memory s = stream.getStream(STREAM_ID);
        assertEq(uint8(s.status), uint8(RemitTypes.StreamStatus.Closed));
        assertGt(s.closedAt, 0);
    }

    function test_closeStream_byPayee() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);
        vm.warp(block.timestamp + 200);

        vm.prank(payee);
        stream.closeStream(STREAM_ID);

        assertEq(uint8(stream.getStream(STREAM_ID).status), uint8(RemitTypes.StreamStatus.Closed));
    }

    function test_closeStream_immediately_fullRefund() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);
        // Close in same block (elapsed = 0)
        uint96 payerBefore = uint96(usdc.balanceOf(payer));

        vm.prank(payer);
        stream.closeStream(STREAM_ID);

        // totalStreamed = 0, refund = MAX_TOTAL, fee = 0
        assertEq(usdc.balanceOf(payer), payerBefore + MAX_TOTAL);
        assertEq(usdc.balanceOf(payee), MINT_AMOUNT); // no change
        assertEq(usdc.balanceOf(feeRecipient), 0);
    }

    function test_closeStream_atCap_payerGetsZeroRefund() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        // Warp to exactly when totalStreamed = maxTotal (3600 seconds at 10e6/s)
        vm.warp(block.timestamp + 3600);

        uint96 fee = MAX_TOTAL / 100; // 1%
        uint96 payeeGets = MAX_TOTAL - fee;

        vm.prank(payer);
        stream.closeStream(STREAM_ID);

        assertEq(usdc.balanceOf(payee), MINT_AMOUNT + payeeGets);
        assertEq(usdc.balanceOf(payer), MINT_AMOUNT - MAX_TOTAL); // no refund
        assertEq(usdc.balanceOf(feeRecipient), fee);
    }

    function test_closeStream_afterWithdrawal_feeOnlyOnPending() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        // Payee withdraws after 100s. Use absolute timestamps to avoid via_ir
        // TIMESTAMP opcode caching: setUp() has block.timestamp=1, startedAt=1.
        vm.warp(101); // T=101, elapsed=100s
        uint96 withdrawn = uint96(uint256(RATE) * 100); // 1_000e6
        vm.prank(payee);
        stream.withdraw(STREAM_ID);

        // Then another 100s pass and payer closes
        vm.warp(201); // T=201, elapsed=200s
        uint96 totalStreamed = uint96(uint256(RATE) * 200); // 2_000e6
        uint96 pending = totalStreamed - withdrawn; // 1_000e6
        uint96 refund = MAX_TOTAL - totalStreamed; // 34_000e6
        uint96 fee = pending / 100; // 1% of pending only
        uint96 payeeGets = pending - fee;

        uint96 payeeBefore = uint96(usdc.balanceOf(payee));

        vm.prank(payer);
        stream.closeStream(STREAM_ID);

        assertEq(usdc.balanceOf(payee), payeeBefore + payeeGets);
        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(usdc.balanceOf(address(stream)), 0);
    }

    function test_closeStream_revert_notFound() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.StreamNotFound.selector, STREAM_ID));
        stream.closeStream(STREAM_ID);
    }

    function test_closeStream_revert_alreadyClosed() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);
        vm.prank(payer);
        stream.closeStream(STREAM_ID);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.AlreadyClosed.selector, STREAM_ID));
        stream.closeStream(STREAM_ID);
    }

    function test_closeStream_revert_unauthorized() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        stream.closeStream(STREAM_ID);
    }

    // =========================================================================
    // Invariant: contract holds zero after close
    // =========================================================================

    function test_invariant_contractBalanceZeroAfterClose() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);
        vm.warp(block.timestamp + 500);

        // Partial withdraw
        vm.prank(payee);
        stream.withdraw(STREAM_ID);

        // Then close
        vm.warp(block.timestamp + 100);
        vm.prank(payer);
        stream.closeStream(STREAM_ID);

        assertEq(usdc.balanceOf(address(stream)), 0);
    }

    // =========================================================================
    // settle
    // =========================================================================

    function test_settle_exhausted_autoTerminatesAndPaysOut() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        // Warp to full exhaustion: elapsed = 3600s → totalStreamed = MAX_TOTAL, remaining = 0
        vm.warp(block.timestamp + 3600);

        // MockFeeCalculator: 1% on pending
        uint96 fee = MAX_TOTAL / 100;
        uint96 payeeGets = MAX_TOTAL - fee;

        uint96 payeeBefore = uint96(usdc.balanceOf(payee));

        vm.expectEmit(true, true, true, true);
        emit RemitEvents.StreamTerminatedInsufficientBalance(STREAM_ID, payer, payee, MAX_TOTAL, fee);

        stream.settle(STREAM_ID); // callable by anyone

        RemitTypes.Stream memory s = stream.getStream(STREAM_ID);
        assertEq(uint8(s.status), uint8(RemitTypes.StreamStatus.Terminated));
        assertGt(s.closedAt, 0);

        assertEq(usdc.balanceOf(payee), payeeBefore + payeeGets);
        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(usdc.balanceOf(address(stream)), 0);
        assertEq(usdc.balanceOf(payer), MINT_AMOUNT - MAX_TOTAL); // locked maxTotal, no refund
    }

    function test_settle_exhausted_feeOnlyOnPending() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        // Payee withdraws after 100s. Use absolute timestamps (Foundry startedAt = 1).
        vm.warp(101); // T=101, elapsed=100s
        uint96 withdrawn = uint96(uint256(RATE) * 100); // 1_000e6
        vm.prank(payee);
        stream.withdraw(STREAM_ID);

        // Warp to full exhaustion (elapsed = 3600s from startedAt = 1)
        vm.warp(3601); // T=3601

        uint96 pending = MAX_TOTAL - withdrawn; // 35_000e6
        uint96 fee = pending / 100; // 1% of pending only
        uint96 payeeGets = pending - fee;

        uint96 payeeBefore = uint96(usdc.balanceOf(payee));

        vm.expectEmit(true, true, true, true);
        emit RemitEvents.StreamTerminatedInsufficientBalance(STREAM_ID, payer, payee, MAX_TOTAL, fee);

        stream.settle(STREAM_ID);

        assertEq(usdc.balanceOf(payee), payeeBefore + payeeGets);
        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(usdc.balanceOf(address(stream)), 0);
    }

    function test_settle_callableByStranger() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);
        vm.warp(block.timestamp + 3600); // exhaust

        vm.prank(stranger); // not payer or payee
        stream.settle(STREAM_ID);

        assertEq(uint8(stream.getStream(STREAM_ID).status), uint8(RemitTypes.StreamStatus.Terminated));
    }

    function test_settle_nearlyExhausted_emitsWarning() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        // elapsed = 3596s → totalStreamed = 35_960e6, remaining = 40e6 < 5*RATE (50e6)
        // secondsRemaining = 40e6 / 10e6 = 4
        vm.warp(block.timestamp + 3596);
        uint96 remaining = MAX_TOTAL - uint96(uint256(RATE) * 3596); // 40e6
        uint64 secondsRemaining = uint64(remaining / RATE); // 4

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.StreamBalanceWarning(STREAM_ID, payer, remaining, RATE, secondsRemaining);

        stream.settle(STREAM_ID);

        // No state change
        RemitTypes.Stream memory s = stream.getStream(STREAM_ID);
        assertEq(uint8(s.status), uint8(RemitTypes.StreamStatus.Active));
        assertEq(s.closedAt, 0);
    }

    function test_settle_healthyStream_noOpNoStateChange() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);

        // After 100s: remaining = 35_000e6 >> 5*RATE (50e6) → no-op
        vm.warp(block.timestamp + 100);

        stream.settle(STREAM_ID);

        RemitTypes.Stream memory s = stream.getStream(STREAM_ID);
        assertEq(uint8(s.status), uint8(RemitTypes.StreamStatus.Active));
        assertEq(s.closedAt, 0);
        assertEq(s.withdrawn, 0);
        assertEq(usdc.balanceOf(address(stream)), MAX_TOTAL); // funds untouched
    }

    function test_settle_revert_notFound() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.StreamNotFound.selector, STREAM_ID));
        stream.settle(STREAM_ID);
    }

    function test_settle_revert_alreadyClosed() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);
        vm.warp(block.timestamp + 100);
        vm.prank(payer);
        stream.closeStream(STREAM_ID);

        vm.expectRevert(abi.encodeWithSelector(RemitErrors.AlreadyClosed.selector, STREAM_ID));
        stream.settle(STREAM_ID);
    }

    function test_settle_revert_alreadyTerminated() public {
        vm.prank(payer);
        stream.openStream(STREAM_ID, payee, RATE, MAX_TOTAL);
        vm.warp(block.timestamp + 3600); // exhaust
        stream.settle(STREAM_ID); // terminates

        vm.expectRevert(abi.encodeWithSelector(RemitErrors.StreamTerminated.selector, STREAM_ID));
        stream.settle(STREAM_ID);
    }

    // =========================================================================
    // Constructor validation
    // =========================================================================

    function test_constructor_revert_zeroUsdc() public {
        vm.expectRevert(RemitErrors.ZeroAddress.selector);
        new RemitStream(address(0), address(feeCalc), feeRecipient, admin, address(0));
    }

    function test_constructor_revert_zeroFeeCalc() public {
        vm.expectRevert(RemitErrors.ZeroAddress.selector);
        new RemitStream(address(usdc), address(0), feeRecipient, admin, address(0));
    }

    function test_constructor_revert_zeroFeeRecipient() public {
        vm.expectRevert(RemitErrors.ZeroAddress.selector);
        new RemitStream(address(usdc), address(feeCalc), address(0), admin, address(0));
    }

    // =========================================================================
    // For Variants (relayer-submitted)
    // =========================================================================

    address internal relayer = makeAddr("relayer");
    bytes32 constant STREAM_FOR = keccak256("stream-for-001");

    function _authorizeRelayer() internal {
        vm.prank(admin);
        stream.authorizeRelayer(relayer);
    }

    function test_authorizeRelayer_works() public {
        assertFalse(stream.isAuthorizedRelayer(relayer));
        _authorizeRelayer();
        assertTrue(stream.isAuthorizedRelayer(relayer));
    }

    function test_openStreamFor_happyPath() public {
        _authorizeRelayer();

        uint256 payerBefore = usdc.balanceOf(payer);

        vm.expectEmit(true, true, true, true);
        emit RemitEvents.StreamOpened(STREAM_FOR, payer, payee, RATE, MAX_TOTAL);

        vm.prank(relayer);
        stream.openStreamFor(payer, STREAM_FOR, payee, RATE, MAX_TOTAL);

        RemitTypes.Stream memory s = stream.getStream(STREAM_FOR);
        assertEq(s.payer, payer, "payer should be agent, not relayer");
        assertEq(s.payee, payee);
        assertEq(s.maxTotal, MAX_TOTAL);
        assertEq(payerBefore - usdc.balanceOf(payer), MAX_TOTAL, "payer debited");
    }

    function test_openStreamFor_revertsForUnauthorized() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        stream.openStreamFor(payer, STREAM_FOR, payee, RATE, MAX_TOTAL);
    }

    function test_withdrawFor_happyPath() public {
        _authorizeRelayer();
        vm.prank(relayer);
        stream.openStreamFor(payer, STREAM_FOR, payee, RATE, MAX_TOTAL);

        vm.warp(block.timestamp + 100); // 100 seconds → 100 * RATE accrued

        uint256 payeeBefore = usdc.balanceOf(payee);
        vm.prank(relayer);
        stream.withdrawFor(payee, STREAM_FOR);

        assertGt(usdc.balanceOf(payee) - payeeBefore, 0, "payee received funds");
    }

    function test_closeStreamFor_happyPath() public {
        _authorizeRelayer();
        vm.prank(relayer);
        stream.openStreamFor(payer, STREAM_FOR, payee, RATE, MAX_TOTAL);

        vm.warp(block.timestamp + 100);

        vm.prank(relayer);
        stream.closeStreamFor(payer, STREAM_FOR);

        RemitTypes.Stream memory s = stream.getStream(STREAM_FOR);
        assertEq(uint8(s.status), uint8(RemitTypes.StreamStatus.Closed));
    }
}
