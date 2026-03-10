// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {TestBase} from "./helpers/TestBase.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";
import {RemitErrors} from "../src/libraries/RemitErrors.sol";

/// @title RemitEscrowFuzzTest
/// @notice Fuzz tests for RemitEscrow.sol invariants
contract RemitEscrowFuzzTest is TestBase {
    // =========================================================================
    // Fuzz: createEscrow — amount bounds
    // =========================================================================

    /// @dev Fee is never greater than the amount; fee + payout == amount
    function testFuzz_createAndRelease_feeInvariant(uint96 amount) public {
        amount = uint96(bound(amount, RemitTypes.MIN_AMOUNT, type(uint96).max));

        // Fund payer with enough
        usdc.mint(payer, amount);
        vm.prank(payer);
        usdc.approve(address(escrow), amount);

        bytes32 inv = keccak256(abi.encodePacked("fuzz", amount));

        vm.prank(payer);
        escrow.createEscrow(
            inv,
            payee,
            amount,
            uint64(block.timestamp + TIMEOUT_DELTA),
            new RemitTypes.Milestone[](0),
            new RemitTypes.Split[](0)
        );

        vm.prank(payee);
        escrow.claimStart(inv);

        uint256 payeeBefore = usdc.balanceOf(payee);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 contractBefore = usdc.balanceOf(address(escrow));

        vm.prank(payer);
        escrow.releaseEscrow(inv);

        uint256 payeeGain = usdc.balanceOf(payee) - payeeBefore;
        uint256 feeGain = usdc.balanceOf(feeRecipient) - feeBefore;

        // Invariant: all funds accounted for — no dust lost
        assertEq(payeeGain + feeGain, contractBefore, "funds not conserved");
        // Invariant: fee never exceeds amount
        assertLe(feeGain, amount, "fee exceeds amount");
        // Invariant: payee always gets something (unless amount is tiny and fee rounds up)
        if (amount >= 100) {
            assertGt(payeeGain, 0, "payee receives nothing");
        }
    }

    /// @dev Timeout must be strictly in the future to create escrow
    function testFuzz_createEscrow_timeoutBound(uint64 timeout) public {
        timeout = uint64(bound(timeout, 0, block.timestamp));

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.InvalidTimeout.selector, timeout));
        escrow.createEscrow(
            keccak256("inv"), payee, AMOUNT, timeout, new RemitTypes.Milestone[](0), new RemitTypes.Split[](0)
        );
    }

    // =========================================================================
    // Fuzz: milestone sum invariant
    // =========================================================================

    /// @dev Sum of milestone amounts must equal escrow total; release conserves funds
    function testFuzz_milestoneSumEqualsTotal(uint8 count, uint64 seed) public {
        count = uint8(bound(count, 1, 10));

        // Generate milestone amounts that sum to AMOUNT
        uint96[] memory amounts = new uint96[](count);
        uint96 remaining = AMOUNT;
        for (uint256 i; i < count - 1; ++i) {
            uint96 chunk = uint96(
                bound(
                    uint256(keccak256(abi.encodePacked(seed, i))) % remaining,
                    RemitTypes.MIN_AMOUNT,
                    remaining - (count - 1 - i) * RemitTypes.MIN_AMOUNT
                )
            );
            amounts[i] = chunk;
            remaining -= chunk;
        }
        amounts[count - 1] = remaining;

        bytes32 inv = keccak256(abi.encodePacked("milestone-fuzz", seed, count));
        _createEscrowWithMilestones(inv, amounts);

        RemitTypes.Escrow memory e = escrow.getEscrow(inv);
        RemitTypes.Milestone[] memory ms = escrow.getMilestones(inv);

        uint96 sum;
        for (uint256 i; i < ms.length; ++i) {
            sum += ms[i].amount;
        }

        // Invariant: milestone sum == escrow amount
        assertEq(sum, e.amount, "milestone sum mismatch");
        assertEq(ms.length, count, "wrong milestone count");
    }

    // =========================================================================
    // Fuzz: cancel fee invariant
    // =========================================================================

    /// @dev Cancel fee (0.1%) + refund == amount
    function testFuzz_cancelFee_invariant(uint96 amount) public {
        amount = uint96(bound(amount, RemitTypes.MIN_AMOUNT, type(uint96).max));

        usdc.mint(payer, amount);
        vm.prank(payer);
        usdc.approve(address(escrow), amount);

        bytes32 inv = keccak256(abi.encodePacked("cancel-fuzz", amount));

        vm.prank(payer);
        escrow.createEscrow(
            inv,
            payee,
            amount,
            uint64(block.timestamp + TIMEOUT_DELTA),
            new RemitTypes.Milestone[](0),
            new RemitTypes.Split[](0)
        );

        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        vm.prank(payer);
        escrow.cancelEscrow(inv);

        uint256 payerGain = usdc.balanceOf(payer) - payerBefore;
        uint256 feeGain = usdc.balanceOf(feeRecipient) - feeBefore;

        // Invariant: refund + fee == original amount
        assertEq(payerGain + feeGain, amount, "cancel: funds not conserved");
        // Invariant: fee is 0.1%
        uint96 expectedFee = uint96((uint256(amount) * RemitTypes.CANCEL_FEE_BPS) / 10_000);
        assertEq(feeGain, expectedFee, "cancel fee incorrect");
    }

    // =========================================================================
    // Fuzz: timeout behavior
    // =========================================================================

    /// @dev After timeout, payer always gets full amount back (no evidence case)
    function testFuzz_timeoutPayer_getsFullAmount(uint64 warpDelta) public {
        warpDelta = uint64(bound(warpDelta, 1, 365 days));

        bytes32 inv = keccak256(abi.encodePacked("timeout-fuzz", warpDelta));
        _createEscrow(inv);

        vm.prank(payee);
        escrow.claimStart(inv);

        vm.warp(block.timestamp + TIMEOUT_DELTA + warpDelta);

        uint256 payerBefore = usdc.balanceOf(payer);

        vm.prank(payer);
        escrow.claimTimeout(inv);

        assertEq(usdc.balanceOf(payer) - payerBefore, AMOUNT, "payer did not receive full amount");
        assertEq(usdc.balanceOf(address(escrow)), 0, "contract still holds funds");
    }

    // =========================================================================
    // Fuzz: dispute resolution invariant
    // =========================================================================

    /// @dev Dispute resolution: payerAmount + payeeAmount == amount (enforced by contract).
    ///      Payer files dispute, payer wins (bond returned to payer) so net payer gain = payerAmt.
    function testFuzz_disputeResolution_sumsMatch(uint96 payerAmt) public {
        payerAmt = uint96(bound(payerAmt, 0, AMOUNT));
        uint96 payeeAmt = AMOUNT - payerAmt;

        bytes32 inv = keccak256(abi.encodePacked("dispute-fuzz", payerAmt));
        _createAndActivate(inv);

        // Capture balances before filing (so net includes bond round-trip)
        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 payeeBefore = usdc.balanceOf(payee);

        // Payer files dispute; payer already has 1 participation (createEscrow), 0 prior disputes → 1x bond
        vm.prank(payer);
        escrow.fileDispute(inv, keccak256("evidence"));

        // payerWins=false (payeeWins=false means payer wins): payer's bond returned, payee has no bond
        vm.prank(admin);
        escrow.resolveDispute(inv, payerAmt, payeeAmt, false);

        // payerGain = payerAmt (escrow share) - bond (paid) + bond (returned) = payerAmt
        uint256 payerGain = usdc.balanceOf(payer) - payerBefore;
        uint256 payeeGain = usdc.balanceOf(payee) - payeeBefore;

        // Invariant: net gains (excluding bond round-trip) == escrowed amount
        assertEq(payerGain + payeeGain, AMOUNT, "dispute: funds not conserved");
        assertEq(payerGain, payerAmt, "payer received wrong amount");
        assertEq(payeeGain, payeeAmt, "payee received wrong amount");
    }

    /// @dev Dispute resolution fails if amounts don't add up
    function testFuzz_disputeResolution_revertsOnMismatch(uint96 payerAmt, uint96 payeeAmt) public {
        // Ensure sum != AMOUNT
        vm.assume(uint256(payerAmt) + uint256(payeeAmt) != uint256(AMOUNT));

        bytes32 inv = keccak256(abi.encodePacked("dispute-mismatch-fuzz", payerAmt, payeeAmt));
        _createAndActivate(inv);

        vm.prank(payer);
        escrow.fileDispute(inv, keccak256("evidence"));

        vm.prank(admin);
        vm.expectRevert();
        escrow.resolveDispute(inv, payerAmt, payeeAmt, true);
    }

    // =========================================================================
    // Fuzz: state machine — no invalid transitions
    // =========================================================================

    /// @dev Completed escrows cannot be re-released or cancelled
    function testFuzz_noDoubleRelease(uint96 amount) public {
        amount = uint96(bound(amount, RemitTypes.MIN_AMOUNT, 1_000_000e6));

        usdc.mint(payer, amount);
        vm.prank(payer);
        usdc.approve(address(escrow), amount);

        bytes32 inv = keccak256(abi.encodePacked("double-release-fuzz", amount));

        vm.prank(payer);
        escrow.createEscrow(
            inv,
            payee,
            amount,
            uint64(block.timestamp + TIMEOUT_DELTA),
            new RemitTypes.Milestone[](0),
            new RemitTypes.Split[](0)
        );

        vm.prank(payee);
        escrow.claimStart(inv);

        vm.prank(payer);
        escrow.releaseEscrow(inv);

        // Cannot release again
        vm.prank(payer);
        vm.expectRevert();
        escrow.releaseEscrow(inv);

        // Cannot cancel after completion
        vm.prank(payer);
        vm.expectRevert();
        escrow.cancelEscrow(inv);
    }
}
