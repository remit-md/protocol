// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {TestBase} from "./helpers/TestBase.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";
import {RemitErrors} from "../src/libraries/RemitErrors.sol";
import {RemitEvents} from "../src/libraries/RemitEvents.sol";

/// @title RemitEscrowTest
/// @notice Unit tests for RemitEscrow.sol
contract RemitEscrowTest is TestBase {
    bytes32 constant INV = keccak256("invoice-001");

    // =========================================================================
    // createEscrow
    // =========================================================================

    function test_createEscrow_happyPath() public {
        uint64 timeout = uint64(block.timestamp + TIMEOUT_DELTA);

        vm.expectEmit(true, true, true, true);
        emit RemitEvents.EscrowFunded(INV, payer, payee, AMOUNT, timeout);

        vm.prank(payer);
        escrow.createEscrow(INV, payee, AMOUNT, timeout, new RemitTypes.Milestone[](0), new RemitTypes.Split[](0));

        RemitTypes.Escrow memory e = escrow.getEscrow(INV);
        assertEq(e.payer, payer);
        assertEq(e.payee, payee);
        assertEq(e.amount, AMOUNT);
        assertEq(uint8(e.status), uint8(RemitTypes.EscrowStatus.Funded));
        assertFalse(e.claimStarted);
        assertFalse(e.evidenceSubmitted);
    }

    function test_createEscrow_transfersUSDC() public {
        uint256 balanceBefore = usdc.balanceOf(address(escrow));

        _createEscrow(INV);

        assertEq(usdc.balanceOf(address(escrow)), balanceBefore + AMOUNT);
        assertEq(usdc.balanceOf(payer), 10_000e6 - AMOUNT);
    }

    function test_createEscrow_revertsIfAlreadyFunded() public {
        _createEscrow(INV);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.EscrowAlreadyFunded.selector, INV));
        escrow.createEscrow(
            INV,
            payee,
            AMOUNT,
            uint64(block.timestamp + TIMEOUT_DELTA),
            new RemitTypes.Milestone[](0),
            new RemitTypes.Split[](0)
        );
    }

    function test_createEscrow_revertsOnZeroPayee() public {
        vm.prank(payer);
        vm.expectRevert(RemitErrors.ZeroAddress.selector);
        escrow.createEscrow(
            INV,
            address(0),
            AMOUNT,
            uint64(block.timestamp + TIMEOUT_DELTA),
            new RemitTypes.Milestone[](0),
            new RemitTypes.Split[](0)
        );
    }

    function test_createEscrow_revertsOnSelfPayment() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.SelfPayment.selector, payer));
        escrow.createEscrow(
            INV,
            payer,
            AMOUNT,
            uint64(block.timestamp + TIMEOUT_DELTA),
            new RemitTypes.Milestone[](0),
            new RemitTypes.Split[](0)
        );
    }

    function test_createEscrow_revertsOnBelowMinimum() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.BelowMinimum.selector, 1, RemitTypes.MIN_AMOUNT));
        escrow.createEscrow(
            INV,
            payee,
            1,
            uint64(block.timestamp + TIMEOUT_DELTA),
            new RemitTypes.Milestone[](0),
            new RemitTypes.Split[](0)
        );
    }

    function test_createEscrow_revertsOnPastTimeout() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.InvalidTimeout.selector, uint64(block.timestamp)));
        escrow.createEscrow(
            INV, payee, AMOUNT, uint64(block.timestamp), new RemitTypes.Milestone[](0), new RemitTypes.Split[](0)
        );
    }

    function test_createEscrow_withMilestones() public {
        uint96[] memory amounts = new uint96[](3);
        amounts[0] = 30e6;
        amounts[1] = 40e6;
        amounts[2] = 30e6;

        _createEscrowWithMilestones(INV, amounts);

        RemitTypes.Escrow memory e = escrow.getEscrow(INV);
        assertEq(e.milestoneCount, 3);
        assertEq(e.amount, 100e6);

        RemitTypes.Milestone[] memory ms = escrow.getMilestones(INV);
        assertEq(ms.length, 3);
        assertEq(ms[0].amount, 30e6);
        assertEq(ms[1].amount, 40e6);
        assertEq(ms[2].amount, 30e6);
    }

    function test_createEscrow_revertsIfMilestoneSumMismatch() public {
        RemitTypes.Milestone[] memory milestones = new RemitTypes.Milestone[](2);
        milestones[0] = RemitTypes.Milestone({
            amount: 40e6,
            timeout: uint64(block.timestamp + TIMEOUT_DELTA),
            status: RemitTypes.MilestoneStatus.Pending,
            evidenceHash: bytes32(0)
        });
        milestones[1] = RemitTypes.Milestone({
            amount: 40e6,
            timeout: uint64(block.timestamp + TIMEOUT_DELTA),
            status: RemitTypes.MilestoneStatus.Pending,
            evidenceHash: bytes32(0)
        });

        vm.prank(payer);
        vm.expectRevert(); // BelowMinimum with sum != amount
        escrow.createEscrow(
            INV, payee, AMOUNT, uint64(block.timestamp + TIMEOUT_DELTA), milestones, new RemitTypes.Split[](0)
        );
    }

    function test_createEscrow_withSplits() public {
        address split1 = makeAddr("split1");
        address split2 = makeAddr("split2");

        RemitTypes.Split[] memory splits = new RemitTypes.Split[](2);
        splits[0] = RemitTypes.Split({payee: split1, amount: 60e6});
        splits[1] = RemitTypes.Split({payee: split2, amount: 40e6});

        vm.prank(payer);
        escrow.createEscrow(
            INV, payee, AMOUNT, uint64(block.timestamp + TIMEOUT_DELTA), new RemitTypes.Milestone[](0), splits
        );

        RemitTypes.Escrow memory e = escrow.getEscrow(INV);
        assertEq(e.splitCount, 2);
    }

    // =========================================================================
    // claimStart
    // =========================================================================

    function test_claimStart_happyPath() public {
        _createEscrow(INV);

        vm.expectEmit(true, true, false, false);
        emit RemitEvents.ClaimStartConfirmed(INV, payee, uint64(block.timestamp));

        vm.prank(payee);
        escrow.claimStart(INV);

        RemitTypes.Escrow memory e = escrow.getEscrow(INV);
        assertTrue(e.claimStarted);
        assertEq(uint8(e.status), uint8(RemitTypes.EscrowStatus.Active));
    }

    function test_claimStart_revertsIfNotPayee() public {
        _createEscrow(INV);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        escrow.claimStart(INV);
    }

    function test_claimStart_revertsIfAlreadyActive() public {
        _createAndActivate(INV);

        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.EscrowFrozen.selector, INV));
        escrow.claimStart(INV);
    }

    function test_claimStart_revertsIfEscrowNotFound() public {
        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.EscrowNotFound.selector, INV));
        escrow.claimStart(INV);
    }

    // =========================================================================
    // submitEvidence
    // =========================================================================

    function test_submitEvidence_happyPath() public {
        _createAndActivate(INV);
        bytes32 evHash = keccak256("evidence");

        vm.expectEmit(true, false, false, true);
        emit RemitEvents.EvidenceSubmitted(INV, 0, evHash);

        vm.prank(payee);
        escrow.submitEvidence(INV, 0, evHash);

        RemitTypes.Escrow memory e = escrow.getEscrow(INV);
        assertTrue(e.evidenceSubmitted);
        assertEq(e.evidenceHash, evHash);
    }

    function test_submitEvidence_revertsIfNotPayee() public {
        _createAndActivate(INV);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        escrow.submitEvidence(INV, 0, keccak256("evidence"));
    }

    // =========================================================================
    // releaseEscrow
    // =========================================================================

    function test_releaseEscrow_happyPath() public {
        _createAndActivate(INV);

        uint96 fee = uint96((uint256(AMOUNT) * 100) / 10_000); // 1%
        uint96 net = AMOUNT - fee;

        uint256 payeeBefore = usdc.balanceOf(payee);
        uint256 feeRecipBefore = usdc.balanceOf(feeRecipient);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.EscrowReleased(INV, payee, net, fee);

        vm.prank(payer);
        escrow.releaseEscrow(INV);

        assertEq(usdc.balanceOf(payee), payeeBefore + net);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipBefore + fee);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        RemitTypes.Escrow memory e = escrow.getEscrow(INV);
        assertEq(uint8(e.status), uint8(RemitTypes.EscrowStatus.Completed));
    }

    function test_releaseEscrow_revertsIfNotPayer() public {
        _createAndActivate(INV);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        escrow.releaseEscrow(INV);
    }

    function test_releaseEscrow_revertsIfNotActive() public {
        _createEscrow(INV); // status = Funded, not Active

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.EscrowFrozen.selector, INV));
        escrow.releaseEscrow(INV);
    }

    function test_releaseEscrow_withSplits() public {
        address split1 = makeAddr("split1");
        address split2 = makeAddr("split2");

        RemitTypes.Split[] memory splits = new RemitTypes.Split[](2);
        splits[0] = RemitTypes.Split({payee: split1, amount: 60e6});
        splits[1] = RemitTypes.Split({payee: split2, amount: 40e6});

        vm.prank(payer);
        escrow.createEscrow(
            INV, payee, AMOUNT, uint64(block.timestamp + TIMEOUT_DELTA), new RemitTypes.Milestone[](0), splits
        );

        vm.prank(payee);
        escrow.claimStart(INV);

        vm.prank(payer);
        escrow.releaseEscrow(INV);

        // Each split receives their amount minus proportional fee (1%)
        uint256 split1Balance = usdc.balanceOf(split1);
        uint256 split2Balance = usdc.balanceOf(split2);

        assertGt(split1Balance, 0);
        assertGt(split2Balance, 0);
        // split1 gets 60e6 minus ~1% = ~59.4e6
        assertApproxEqAbs(split1Balance, 59.4e6, 1e4);
        // split2 gets 40e6 minus ~1% = ~39.6e6
        assertApproxEqAbs(split2Balance, 39.6e6, 1e4);
    }

    function test_releaseEscrow_splitFeeRounding_noOverflow() public {
        // Use 3 splits with amounts that cause rounding dust in fee calculation.
        // Fee = 1% of 100e6 = 1e6. Split amounts: 33e6, 33e6, 34e6.
        // Without fix: splitFee(33e6) = 1e6*33e6/100e6 = 330000 (x2) = 660000
        //              splitFee(34e6) = 1e6*34e6/100e6 = 340000
        //              sum(splitFees) = 660000 + 340000 = 1000000 = fee (no dust here)
        // Try harder: 33333333, 33333333, 33333334 (sums to 100e6)
        // splitFee(33333333) = 1e6*33333333/100e6 = 333333 (truncated from 333333.33)
        // sum(first two) = 666666, but fee = 1000000 → last splitFee = 333334
        // Without fix: last splitFee = 1e6*33333334/100e6 = 333333 (truncated)
        // sum = 999999 < 1000000 → feeRecipient gets 1000000, total outflow = 100000001 > 100e6
        address split1 = makeAddr("rsplit1");
        address split2 = makeAddr("rsplit2");
        address split3 = makeAddr("rsplit3");

        uint96 s1 = 33_333_333; // 33.333333 USDC
        uint96 s2 = 33_333_333;
        uint96 s3 = 33_333_334;
        uint96 total = s1 + s2 + s3; // exactly 100e6

        RemitTypes.Split[] memory splits = new RemitTypes.Split[](3);
        splits[0] = RemitTypes.Split({payee: split1, amount: s1});
        splits[1] = RemitTypes.Split({payee: split2, amount: s2});
        splits[2] = RemitTypes.Split({payee: split3, amount: s3});

        vm.prank(payer);
        escrow.createEscrow(
            INV, payee, total, uint64(block.timestamp + TIMEOUT_DELTA), new RemitTypes.Milestone[](0), splits
        );

        vm.prank(payee);
        escrow.claimStart(INV);

        uint256 escrowBalBefore = usdc.balanceOf(address(escrow));

        vm.prank(payer);
        escrow.releaseEscrow(INV);

        // Total outflow must exactly equal escrowed amount — no wei stolen from other escrows
        uint256 totalOut =
            usdc.balanceOf(split1) + usdc.balanceOf(split2) + usdc.balanceOf(split3) + usdc.balanceOf(feeRecipient);
        assertEq(totalOut, escrowBalBefore, "total outflow must equal escrowed amount");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow must be drained to zero");
    }

    function test_releaseEscrow_revertsOnMilestoneEscrow() public {
        // A milestone-based escrow should NOT be releasable via releaseEscrow().
        // After partial milestone releases, calling releaseEscrow() would double-pay.
        uint96[] memory amounts = new uint96[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;

        _createEscrowWithMilestones(INV, amounts);

        vm.prank(payee);
        escrow.claimStart(INV);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.MilestoneEscrowBlocked.selector, INV));
        escrow.releaseEscrow(INV);
    }

    // =========================================================================
    // releaseMilestone
    // =========================================================================

    function test_releaseMilestone_happyPath() public {
        uint96[] memory amounts = new uint96[](3);
        amounts[0] = 30e6;
        amounts[1] = 40e6;
        amounts[2] = 30e6;

        _createEscrowWithMilestones(INV, amounts);

        vm.prank(payee);
        escrow.claimStart(INV);

        // Submit evidence for milestone 0
        vm.prank(payee);
        escrow.submitEvidence(INV, 0, keccak256("m0-evidence"));

        uint256 payeeBefore = usdc.balanceOf(payee);

        vm.expectEmit(true, false, false, true);
        emit RemitEvents.MilestoneReleased(INV, 0, 30e6);

        vm.prank(payer);
        escrow.releaseMilestone(INV, 0);

        assertGt(usdc.balanceOf(payee), payeeBefore); // received payment

        // Escrow still Active (only 1 of 3 milestones released)
        RemitTypes.Escrow memory e = escrow.getEscrow(INV);
        assertEq(uint8(e.status), uint8(RemitTypes.EscrowStatus.Active));
    }

    function test_releaseMilestone_allReleased_completesEscrow() public {
        uint96[] memory amounts = new uint96[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;

        _createEscrowWithMilestones(INV, amounts);

        vm.prank(payee);
        escrow.claimStart(INV);

        vm.prank(payee);
        escrow.submitEvidence(INV, 0, keccak256("m0"));
        vm.prank(payer);
        escrow.releaseMilestone(INV, 0);

        vm.prank(payee);
        escrow.submitEvidence(INV, 1, keccak256("m1"));
        vm.prank(payer);
        escrow.releaseMilestone(INV, 1);

        RemitTypes.Escrow memory e = escrow.getEscrow(INV);
        assertEq(uint8(e.status), uint8(RemitTypes.EscrowStatus.Completed));
    }

    function test_releaseMilestone_revertsIfNotSubmitted() public {
        uint96[] memory amounts = new uint96[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;

        _createEscrowWithMilestones(INV, amounts);

        vm.prank(payee);
        escrow.claimStart(INV);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.EscrowFrozen.selector, INV));
        escrow.releaseMilestone(INV, 0); // not in Submitted status
    }

    // =========================================================================
    // cancelEscrow
    // =========================================================================

    function test_cancelEscrow_happyPath() public {
        _createEscrow(INV);

        uint96 cancelFee = uint96((uint256(AMOUNT) * RemitTypes.CANCEL_FEE_BPS) / 10_000); // 0.1%
        uint96 refund = AMOUNT - cancelFee;

        uint256 payerBefore = usdc.balanceOf(payer);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.EscrowCancelled(INV, payer, false, cancelFee);

        vm.prank(payer);
        escrow.cancelEscrow(INV);

        assertEq(usdc.balanceOf(payer), payerBefore + refund);
        assertEq(usdc.balanceOf(feeRecipient), cancelFee);

        RemitTypes.Escrow memory e = escrow.getEscrow(INV);
        assertEq(uint8(e.status), uint8(RemitTypes.EscrowStatus.Cancelled));
    }

    function test_cancelEscrow_revertsIfNotPayer() public {
        _createEscrow(INV);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        escrow.cancelEscrow(INV);
    }

    function test_cancelEscrow_revertsIfActive() public {
        _createAndActivate(INV); // status = Active after claimStart

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.EscrowFrozen.selector, INV));
        escrow.cancelEscrow(INV);
    }

    function test_cancelEscrow_revertsIfClaimStarted() public {
        // claimStart sets status to Active, but let's verify the claimStarted flag check also works
        _createEscrow(INV);
        vm.prank(payee);
        escrow.claimStart(INV); // sets claimStarted = true AND status = Active

        vm.prank(payer);
        vm.expectRevert(); // EscrowFrozen (status is Active, not Funded)
        escrow.cancelEscrow(INV);
    }

    // =========================================================================
    // mutualCancel
    // =========================================================================

    function test_mutualCancel_happyPath() public {
        _createAndActivate(INV);

        bytes memory payerSig = _signMutualCancel(INV, payerKey);
        bytes memory payeeSig = _signMutualCancel(INV, payeeKey);

        uint256 payerBefore = usdc.balanceOf(payer);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.EscrowCancelled(INV, payer, true, 0);

        escrow.mutualCancel(INV, payerSig, payeeSig);

        assertEq(usdc.balanceOf(payer), payerBefore + AMOUNT); // full refund
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_mutualCancel_revertsOnInvalidPayerSig() public {
        _createAndActivate(INV);

        bytes memory badSig = _signMutualCancel(INV, payeeKey); // wrong key
        bytes memory payeeSig = _signMutualCancel(INV, payeeKey);

        vm.expectRevert(RemitErrors.InvalidSignature.selector);
        escrow.mutualCancel(INV, badSig, payeeSig);
    }

    function test_mutualCancel_revertsIfEvidenceSubmitted() public {
        _createAndActivate(INV);

        vm.prank(payee);
        escrow.submitEvidence(INV, 0, keccak256("evidence"));

        bytes memory payerSig = _signMutualCancel(INV, payerKey);
        bytes memory payeeSig = _signMutualCancel(INV, payeeKey);

        vm.expectRevert(abi.encodeWithSelector(RemitErrors.CancelBlockedEvidence.selector, INV));
        escrow.mutualCancel(INV, payerSig, payeeSig);
    }

    // =========================================================================
    // claimTimeout (payer)
    // =========================================================================

    function test_claimTimeout_happyPath() public {
        _createAndActivate(INV);

        vm.warp(block.timestamp + TIMEOUT_DELTA + 1);

        uint256 payerBefore = usdc.balanceOf(payer);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.EscrowTimeout(INV, payer, AMOUNT);

        vm.prank(payer);
        escrow.claimTimeout(INV);

        assertEq(usdc.balanceOf(payer), payerBefore + AMOUNT);

        RemitTypes.Escrow memory e = escrow.getEscrow(INV);
        assertEq(uint8(e.status), uint8(RemitTypes.EscrowStatus.TimedOut));
    }

    function test_claimTimeout_revertsBeforeTimeout() public {
        _createAndActivate(INV);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(RemitErrors.InvalidTimeout.selector, uint64(block.timestamp + TIMEOUT_DELTA))
        );
        escrow.claimTimeout(INV);
    }

    function test_claimTimeout_revertsIfEvidenceSubmitted() public {
        _createAndActivate(INV);

        vm.prank(payee);
        escrow.submitEvidence(INV, 0, keccak256("evidence"));

        vm.warp(block.timestamp + TIMEOUT_DELTA + 1);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.CancelBlockedEvidence.selector, INV));
        escrow.claimTimeout(INV);
    }

    // =========================================================================
    // claimTimeoutPayee
    // =========================================================================

    function test_claimTimeoutPayee_happyPath() public {
        _createAndActivate(INV);

        vm.prank(payee);
        escrow.submitEvidence(INV, 0, keccak256("evidence"));

        vm.warp(block.timestamp + TIMEOUT_DELTA + 1);

        uint96 fee = uint96((uint256(AMOUNT) * 100) / 10_000);
        uint256 payeeBefore = usdc.balanceOf(payee);

        vm.prank(payee);
        escrow.claimTimeoutPayee(INV);

        assertEq(usdc.balanceOf(payee), payeeBefore + (AMOUNT - fee));

        RemitTypes.Escrow memory e = escrow.getEscrow(INV);
        assertEq(uint8(e.status), uint8(RemitTypes.EscrowStatus.Completed));
    }

    function test_claimTimeoutPayee_revertsIfNoEvidence() public {
        _createAndActivate(INV);

        vm.warp(block.timestamp + TIMEOUT_DELTA + 1);

        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.CancelBlockedEvidence.selector, INV));
        escrow.claimTimeoutPayee(INV);
    }

    // =========================================================================
    // fileDispute / postCounterBond / resolveDispute
    // =========================================================================

    function test_fileDispute_happyPath() public {
        _createAndActivate(INV);
        bytes32 evidenceHash = keccak256("evidence");

        vm.expectEmit(true, true, false, false);
        emit RemitEvents.EscrowDisputed(INV, payer, evidenceHash);

        vm.prank(payer);
        escrow.fileDispute(INV, evidenceHash);

        RemitTypes.Escrow memory e = escrow.getEscrow(INV);
        assertEq(uint8(e.status), uint8(RemitTypes.EscrowStatus.Disputed));

        // Bond posted: 5% of AMOUNT = 5_000_000
        RemitTypes.DisputeBond memory b = escrow.getDisputeBond(INV);
        assertEq(b.filer, payer);
        assertEq(b.filerBond, 5_000_000);
    }

    function test_fileDispute_revert_stranger() public {
        _createAndActivate(INV);
        bytes32 evidenceHash = keccak256("evidence");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        escrow.fileDispute(INV, evidenceHash);
    }

    function test_resolveDispute_happyPath() public {
        _createAndActivate(INV);
        bytes32 evidenceHash = keccak256("evidence");

        // Payer files dispute (bond = 5% of AMOUNT = 5_000_000)
        vm.prank(payer);
        escrow.fileDispute(INV, evidenceHash);

        // Payee posts counter-bond (same amount = 5_000_000)
        vm.prank(payee);
        escrow.postCounterBond(INV);

        uint96 payerAmt = 40e6;
        uint96 payeeAmt = 60e6;
        uint96 bond = 5_000_000; // 5% of AMOUNT

        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 payeeBefore = usdc.balanceOf(payee);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        vm.expectEmit(true, false, false, true);
        emit RemitEvents.DisputeResolved(INV, payerAmt, payeeAmt);

        // payeeWins=true: payee wins, payer(filer) forfeits bond, payee(respondent) gets bond back
        vm.prank(admin);
        escrow.resolveDispute(INV, payerAmt, payeeAmt, true);

        assertEq(usdc.balanceOf(payer), payerBefore + payerAmt); // payer gets escrow share only (bond forfeited)
        assertEq(usdc.balanceOf(payee), payeeBefore + payeeAmt + bond); // payee gets escrow share + bond back
        assertEq(usdc.balanceOf(feeRecipient), feeBefore + bond); // feeRecipient receives forfeited bond
        assertEq(usdc.balanceOf(address(escrow)), 0);

        RemitTypes.Escrow memory e = escrow.getEscrow(INV);
        assertEq(uint8(e.status), uint8(RemitTypes.EscrowStatus.Completed));
    }

    function test_resolveDispute_revertsIfAmountMismatch() public {
        _createAndActivate(INV);
        bytes32 evidenceHash = keccak256("evidence");

        vm.prank(payer);
        escrow.fileDispute(INV, evidenceHash);

        vm.prank(admin);
        vm.expectRevert(); // InsufficientBalance
        escrow.resolveDispute(INV, 40e6, 40e6, true); // sum != AMOUNT
    }

    function test_resolveDispute_revertsIfNotDisputed() public {
        _createAndActivate(INV);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.EscrowFrozen.selector, INV));
        escrow.resolveDispute(INV, 50e6, 50e6, true);
    }

    // =========================================================================
    // Double-fund & edge cases
    // =========================================================================

    function test_cannotDoubleFund() public {
        _createEscrow(INV);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.EscrowAlreadyFunded.selector, INV));
        escrow.createEscrow(
            INV,
            payee,
            AMOUNT,
            uint64(block.timestamp + TIMEOUT_DELTA),
            new RemitTypes.Milestone[](0),
            new RemitTypes.Split[](0)
        );
    }

    function test_feeAndPayoutSumEqualsAmount() public {
        _createAndActivate(INV);

        uint256 escrowBefore = usdc.balanceOf(address(escrow));
        uint256 payeeBefore = usdc.balanceOf(payee);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        vm.prank(payer);
        escrow.releaseEscrow(INV);

        uint256 payeeGain = usdc.balanceOf(payee) - payeeBefore;
        uint256 feeGain = usdc.balanceOf(feeRecipient) - feeBefore;

        assertEq(payeeGain + feeGain, escrowBefore);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_nonexistentEscrow_reverts() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.EscrowNotFound.selector, INV));
        escrow.releaseEscrow(INV);
    }
}
