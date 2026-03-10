// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./helpers/TestBase.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";
import {RemitErrors} from "../src/libraries/RemitErrors.sol";
import {RemitEvents} from "../src/libraries/RemitEvents.sol";

/// @title RemitEscrowDisputeBondTest
/// @notice Unit tests for Unit 1-F: dispute bond filing, counter-bond, default win, bond forfeiture
contract RemitEscrowDisputeBondTest is TestBase {
    bytes32 constant INV = keccak256("invoice-dispute-bond");

    bytes32 constant EVIDENCE = keccak256("evidence-hash");

    // Bond for AMOUNT = 100e6: max(5% of 100e6, 500_000) = 5_000_000
    uint96 constant BOND = 5_000_000;

    // =========================================================================
    // fileDispute
    // =========================================================================

    function test_fileDispute_byPayer_happyPath() public {
        _createAndActivate(INV);

        uint256 payerBefore = usdc.balanceOf(payer);

        vm.expectEmit(true, true, false, false);
        emit RemitEvents.EscrowDisputed(INV, payer, EVIDENCE);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.DisputeBondPosted(INV, payer, BOND);

        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE);

        // Status is Disputed
        RemitTypes.Escrow memory e = escrow.getEscrow(INV);
        assertEq(uint8(e.status), uint8(RemitTypes.EscrowStatus.Disputed));

        // Bond posted: 5% of AMOUNT, 1x multiplier (0 prior disputes / 1 participation)
        RemitTypes.DisputeBond memory b = escrow.getDisputeBond(INV);
        assertEq(b.filer, payer);
        assertEq(b.filerBond, BOND);
        assertEq(b.respondentBond, 0);
        assertFalse(b.respondentPosted);
        assertGt(b.counterBondDeadline, block.timestamp);

        // Bond transferred from payer
        assertEq(usdc.balanceOf(payer), payerBefore - BOND);
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT + BOND);
    }

    function test_fileDispute_byPayee_happyPath() public {
        _createAndActivate(INV);

        vm.expectEmit(true, true, false, false);
        emit RemitEvents.EscrowDisputed(INV, payee, EVIDENCE);

        vm.prank(payee);
        escrow.fileDispute(INV, EVIDENCE);

        RemitTypes.DisputeBond memory b = escrow.getDisputeBond(INV);
        assertEq(b.filer, payee);
    }

    function test_fileDispute_revert_stranger() public {
        _createAndActivate(INV);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        escrow.fileDispute(INV, EVIDENCE);
    }

    function test_fileDispute_revert_alreadyDisputed() public {
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE);

        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.DisputeAlreadyFiled.selector, INV));
        escrow.fileDispute(INV, EVIDENCE);
    }

    function test_fileDispute_revert_zeroEvidenceHash() public {
        _createAndActivate(INV);

        vm.prank(payer);
        vm.expectRevert(RemitErrors.ZeroAmount.selector);
        escrow.fileDispute(INV, bytes32(0));
    }

    function test_fileDispute_bondCalculation_baseCase() public {
        _createAndActivate(INV);
        // AMOUNT = 100e6. baseBond = 5% of 100e6 = 5_000_000. 0 prior disputes → 1x.
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE);

        assertEq(escrow.getDisputeBond(INV).filerBond, BOND);
    }

    function test_fileDispute_bondCalculation_minimumFloor() public {
        // Create an escrow with very small amount to trigger $0.50 minimum floor.
        // Payer already has 10_000e6 USDC with max approval from TestBase.setUp() — no extra approve needed.
        bytes32 inv2 = keccak256("tiny-escrow");
        uint96 tinyAmount = RemitTypes.MIN_AMOUNT; // $0.01 = 10_000

        // Use min timeout floor for this amount (TIMEOUT_FLOOR_UNDER_10 = 1800s for <$10)
        uint64 timeout = uint64(block.timestamp) + RemitTypes.TIMEOUT_FLOOR_UNDER_10 + 1;

        vm.prank(payer);
        escrow.createEscrow(inv2, payee, tinyAmount, timeout, new RemitTypes.Milestone[](0), new RemitTypes.Split[](0));
        vm.prank(payee);
        escrow.claimStart(inv2);

        // 5% of 10_000 = 500. But minimum is 500_000 → bond = 500_000 (minimum floor applies)
        vm.prank(payer);
        escrow.fileDispute(inv2, EVIDENCE);

        assertEq(escrow.getDisputeBond(inv2).filerBond, RemitTypes.DISPUTE_BOND_MIN);
    }

    // =========================================================================
    // postCounterBond
    // =========================================================================

    function test_postCounterBond_happyPath() public {
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE);

        uint256 payeeBefore = usdc.balanceOf(payee);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.CounterBondPosted(INV, payee, BOND);

        vm.prank(payee);
        escrow.postCounterBond(INV);

        RemitTypes.DisputeBond memory b = escrow.getDisputeBond(INV);
        assertEq(b.respondentBond, BOND);
        assertTrue(b.respondentPosted);

        // Counter-bond transferred from respondent (payee)
        assertEq(usdc.balanceOf(payee), payeeBefore - BOND);
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT + BOND + BOND);
    }

    function test_postCounterBond_revert_notRespondent() public {
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        escrow.postCounterBond(INV);
    }

    function test_postCounterBond_revert_afterDeadline() public {
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE);

        // Warp past 72-hour counter-bond window
        vm.warp(block.timestamp + RemitTypes.COUNTER_BOND_WINDOW + 1);

        vm.prank(payee);
        vm.expectRevert();
        escrow.postCounterBond(INV);
    }

    function test_postCounterBond_revert_alreadyPosted() public {
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE);
        vm.prank(payee);
        escrow.postCounterBond(INV);

        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.DisputeAlreadyFiled.selector, INV));
        escrow.postCounterBond(INV);
    }

    // =========================================================================
    // claimDefaultWin
    // =========================================================================

    function test_claimDefaultWin_payerFiled_happyPath() public {
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE);

        // Warp past counter-bond window without payee posting
        vm.warp(block.timestamp + RemitTypes.COUNTER_BOND_WINDOW + 1);

        uint256 payerBefore = usdc.balanceOf(payer);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.DisputeDefaultWin(INV, payer, BOND, AMOUNT);

        vm.prank(payer);
        escrow.claimDefaultWin(INV);

        // Payer gets: bond back + full AMOUNT refund (no fee on default win by payer)
        assertEq(usdc.balanceOf(payer), payerBefore + BOND + AMOUNT);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        RemitTypes.Escrow memory e = escrow.getEscrow(INV);
        assertEq(uint8(e.status), uint8(RemitTypes.EscrowStatus.Completed));
    }

    function test_claimDefaultWin_payeeFiled_happyPath() public {
        _createAndActivate(INV);
        vm.prank(payee);
        escrow.fileDispute(INV, EVIDENCE);

        vm.warp(block.timestamp + RemitTypes.COUNTER_BOND_WINDOW + 1);

        uint256 payeeBefore = usdc.balanceOf(payee);
        // MockFeeCalculator: 1% = 1_000_000 fee on 100e6
        uint96 fee = AMOUNT / 100; // 1_000_000

        vm.prank(payee);
        escrow.claimDefaultWin(INV);

        // Payee gets: bond back + (AMOUNT - fee)
        assertEq(usdc.balanceOf(payee), payeeBefore + BOND + (AMOUNT - fee));
        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_claimDefaultWin_revert_beforeDeadline() public {
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE);

        // Still within counter-bond window
        vm.prank(payer);
        vm.expectRevert();
        escrow.claimDefaultWin(INV);
    }

    function test_claimDefaultWin_revert_counterBondPosted() public {
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE);
        vm.prank(payee);
        escrow.postCounterBond(INV);

        vm.warp(block.timestamp + RemitTypes.COUNTER_BOND_WINDOW + 1);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.DisputeAlreadyFiled.selector, INV));
        escrow.claimDefaultWin(INV);
    }

    function test_claimDefaultWin_revert_notFiler() public {
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE);

        vm.warp(block.timestamp + RemitTypes.COUNTER_BOND_WINDOW + 1);

        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, payee));
        escrow.claimDefaultWin(INV);
    }

    // =========================================================================
    // increaseBond
    // =========================================================================

    function test_increaseBond_happyPath() public {
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE);

        uint96 extra = 1_000_000; // $1 USDC additional

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.BondIncreased(INV, payer, extra, BOND + extra);

        vm.prank(payer);
        escrow.increaseBond(INV, extra);

        assertEq(escrow.getDisputeBond(INV).filerBond, BOND + extra);
    }

    function test_increaseBond_revert_notFiler() public {
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE);

        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, payee));
        escrow.increaseBond(INV, 1_000_000);
    }

    function test_increaseBond_revert_afterDeadline() public {
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE);

        vm.warp(block.timestamp + RemitTypes.COUNTER_BOND_WINDOW + 1);

        vm.prank(payer);
        vm.expectRevert();
        escrow.increaseBond(INV, 1_000_000);
    }

    function test_increaseBond_revert_afterCounterBondPosted() public {
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE);
        vm.prank(payee);
        escrow.postCounterBond(INV);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.DisputeAlreadyFiled.selector, INV));
        escrow.increaseBond(INV, 1_000_000);
    }

    // =========================================================================
    // resolveDispute with bond forfeiture
    // =========================================================================

    function test_resolveDispute_payerWins_bondHandling() public {
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE); // payer files, pays BOND
        vm.prank(payee);
        escrow.postCounterBond(INV); // payee posts BOND

        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 payeeBefore = usdc.balanceOf(payee);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        // payeeWins=false → payer wins; payer(filer) gets bond back; payee(respondent) forfeits bond
        vm.prank(admin);
        escrow.resolveDispute(INV, AMOUNT, 0, false);

        // Payer gets: AMOUNT (escrow) + BOND (filer bond returned)
        assertEq(usdc.balanceOf(payer), payerBefore + AMOUNT + BOND);
        // Payee gets: 0 (escrow) + 0 (bond forfeited)
        assertEq(usdc.balanceOf(payee), payeeBefore);
        // FeeRecipient gets: respondent bond (payee's forfeited bond)
        assertEq(usdc.balanceOf(feeRecipient), feeBefore + BOND);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_resolveDispute_payeeWins_bondHandling() public {
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE); // payer files, pays BOND
        vm.prank(payee);
        escrow.postCounterBond(INV); // payee posts BOND

        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 payeeBefore = usdc.balanceOf(payee);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        // payeeWins=true → payee wins; payee(respondent) gets bond back; payer(filer) forfeits bond
        vm.prank(admin);
        escrow.resolveDispute(INV, 0, AMOUNT, true);

        // Payer gets: 0 (escrow) + 0 (bond forfeited)
        assertEq(usdc.balanceOf(payer), payerBefore);
        // Payee gets: AMOUNT (escrow) + BOND (respondent bond returned)
        assertEq(usdc.balanceOf(payee), payeeBefore + AMOUNT + BOND);
        // FeeRecipient gets: filer bond (payer's forfeited bond)
        assertEq(usdc.balanceOf(feeRecipient), feeBefore + BOND);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_resolveDispute_noBonds_noCounterBond() public {
        // Admin can resolve even if no counter-bond posted (bonds handled proportionally)
        _createAndActivate(INV);
        vm.prank(payer);
        escrow.fileDispute(INV, EVIDENCE); // payer files, pays BOND (no counter-bond)

        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        // payeeWins=false → payer wins; filer(payer) wins → bond returned; no respondent bond
        vm.prank(admin);
        escrow.resolveDispute(INV, AMOUNT, 0, false);

        assertEq(usdc.balanceOf(payer), payerBefore + AMOUNT + BOND); // gets AMOUNT + bond back
        assertEq(usdc.balanceOf(feeRecipient), feeBefore); // no bond forfeited (no counter-bond)
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    // =========================================================================
    // Fuzz: bond calculation
    // =========================================================================

    /// @dev Bond is always >= DISPUTE_BOND_MIN and >= 5% of amount; multiplier capped at 8x
    function testFuzz_bondCalculation(uint96 amount) public {
        amount = uint96(bound(amount, RemitTypes.MIN_AMOUNT, 1_000_000e6));

        uint96 expectedBase = uint96((uint256(amount) * RemitTypes.DISPUTE_BOND_BPS) / 10_000);
        if (expectedBase < RemitTypes.DISPUTE_BOND_MIN) expectedBase = RemitTypes.DISPUTE_BOND_MIN;

        // Fund payer for this specific amount
        usdc.mint(payer, amount + expectedBase * 8); // enough for max bond
        vm.prank(payer);
        usdc.approve(address(escrow), type(uint256).max);

        bytes32 inv = keccak256(abi.encodePacked("fuzz-bond", amount));
        uint64 timeout = uint64(block.timestamp + 365 days); // generous timeout for all tiers

        vm.prank(payer);
        escrow.createEscrow(inv, payee, amount, timeout, new RemitTypes.Milestone[](0), new RemitTypes.Split[](0));
        vm.prank(payee);
        escrow.claimStart(inv);

        vm.prank(payer);
        escrow.fileDispute(inv, EVIDENCE);

        uint96 actualBond = escrow.getDisputeBond(inv).filerBond;

        // Bond must be at least the base (1x multiplier for first-time disputer)
        assertEq(actualBond, expectedBase, "bond mismatch");
        assertGe(actualBond, RemitTypes.DISPUTE_BOND_MIN, "bond below minimum");
    }

    /// @dev Multiplier escalates correctly with dispute rate tiers
    function testFuzz_disputeRateMultiplier(uint8 disputeCount, uint8 participationCount) public {
        // Bound to realistic values
        participationCount = uint8(bound(participationCount, 1, 100));
        disputeCount = uint8(bound(disputeCount, 0, participationCount));

        // Actual total participations when the target dispute is filed:
        //   participationCount (ghost escrow loop) + disputeCount (dispute loop createEscrow calls) + 1 (target escrow)
        uint64 totalParticipations = uint64(participationCount) + uint64(disputeCount) + 1;
        uint64 rate100 = (uint64(disputeCount) * 100) / totalParticipations;
        uint96 expectedMultiplier;
        if (rate100 < 5) expectedMultiplier = 1;
        else if (rate100 < 10) expectedMultiplier = 2;
        else if (rate100 < 20) expectedMultiplier = 4;
        else expectedMultiplier = 8;

        // Set up a fresh address with the given history via ghost escrows
        address disputeFiler = makeAddr("fuzz-filer");
        usdc.mint(disputeFiler, 100_000_000e6);
        vm.prank(disputeFiler);
        usdc.approve(address(escrow), type(uint256).max);

        // Simulate participationCount escrow participations by creating+starting escrows
        for (uint8 i = 0; i < participationCount; i++) {
            bytes32 ghostInv = keccak256(abi.encodePacked("ghost", disputeFiler, i));
            uint64 timeout = uint64(block.timestamp + 365 days);

            vm.prank(disputeFiler);
            escrow.createEscrow(
                ghostInv,
                payee,
                RemitTypes.MIN_AMOUNT,
                timeout,
                new RemitTypes.Milestone[](0),
                new RemitTypes.Split[](0)
            );
        }

        // Simulate disputeCount prior disputes (increment dispute counter)
        for (uint8 i = 0; i < disputeCount; i++) {
            bytes32 disputeInv = keccak256(abi.encodePacked("ghost-dispute", disputeFiler, i));
            uint64 timeout = uint64(block.timestamp + 365 days);

            vm.prank(disputeFiler);
            escrow.createEscrow(
                disputeInv, payee, AMOUNT, timeout, new RemitTypes.Milestone[](0), new RemitTypes.Split[](0)
            );
            vm.prank(payee);
            escrow.claimStart(disputeInv);
            vm.prank(disputeFiler);
            escrow.fileDispute(disputeInv, EVIDENCE);

            // Resolve quickly so filer can dispute next one
            vm.prank(admin);
            escrow.resolveDispute(disputeInv, AMOUNT, 0, false);
        }

        // Now file a fresh dispute and check bond multiplier
        bytes32 targetInv = keccak256(abi.encodePacked("target", disputeFiler));
        uint64 targetTimeout = uint64(block.timestamp + 365 days);

        vm.prank(disputeFiler);
        escrow.createEscrow(
            targetInv, payee, AMOUNT, targetTimeout, new RemitTypes.Milestone[](0), new RemitTypes.Split[](0)
        );
        vm.prank(payee);
        escrow.claimStart(targetInv);

        vm.prank(disputeFiler);
        escrow.fileDispute(targetInv, EVIDENCE);

        uint96 actualBond = escrow.getDisputeBond(targetInv).filerBond;
        uint96 baseBond = uint96((uint256(AMOUNT) * RemitTypes.DISPUTE_BOND_BPS) / 10_000); // 5_000_000

        assertEq(actualBond, baseBond * expectedMultiplier, "multiplier mismatch");
    }
}
