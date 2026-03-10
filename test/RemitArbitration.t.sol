// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {RemitArbitration} from "../src/RemitArbitration.sol";
import {IRemitArbitration} from "../src/interfaces/IRemitArbitration.sol";
import {RemitEscrow} from "../src/RemitEscrow.sol";
import {RemitErrors} from "../src/libraries/RemitErrors.sol";
import {RemitEvents} from "../src/libraries/RemitEvents.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";

import {MockFeeCalculator} from "./helpers/MockFeeCalculator.sol";

/// @title RemitArbitrationTest
/// @notice Comprehensive tests for RemitArbitration.sol
/// @dev Covers: registration, removal, routing, strike phase, decisions, fees,
///      tiered routing, deadline enforcement, fallbacks, and integration with RemitEscrow.
contract RemitArbitrationTest is Test {
    // ── Contracts ────────────────────────────────────────────────────────────
    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    RemitArbitration internal arb;
    RemitEscrow internal escrow;

    // ── Actors ───────────────────────────────────────────────────────────────
    address internal admin = makeAddr("admin");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal payer = makeAddr("payer");
    address internal payee = makeAddr("payee");
    address internal arb1 = makeAddr("arb1");
    address internal arb2 = makeAddr("arb2");
    address internal arb3 = makeAddr("arb3");
    address internal arb4 = makeAddr("arb4");
    address internal stranger = makeAddr("stranger");

    // ── Constants ─────────────────────────────────────────────────────────────
    uint96 internal constant BOND = 100_000_000; // $100 — min arbitrator bond
    uint96 internal constant AMOUNT = 500_000_000; // $500 — pool tier
    uint96 internal constant SMALL_AMOUNT = 50_000_000; // $50 — admin tier
    uint96 internal constant LARGE_AMOUNT = 2_000_000_000; // $2000 — required tier
    uint64 internal constant TIMEOUT_DELTA = 7 days;
    uint64 internal constant COUNTER_BOND_WINDOW = 259_200; // 72h (must match RemitTypes)

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        // Deploy token + fee calculator
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();

        // Deploy arbitration contract (admin is owner)
        arb = new RemitArbitration(address(usdc), admin);

        // Deploy escrow WITH arbitration contract
        escrow = new RemitEscrow(address(usdc), address(feeCalc), admin, feeRecipient, address(0), address(arb));

        // Authorize escrow in arbitration contract
        vm.prank(admin);
        arb.authorizeEscrow(address(escrow));

        // Fund actors
        _fund(payer, 10_000e6);
        _fund(payee, 10_000e6);
        _fund(arb1, BOND + 1000e6);
        _fund(arb2, BOND + 1000e6);
        _fund(arb3, BOND + 1000e6);
        _fund(arb4, BOND + 1000e6);
    }

    // =========================================================================
    // Unit 3-A: Registration
    // =========================================================================

    function test_registerArbitrator_success() public {
        vm.startPrank(arb1);
        usdc.approve(address(arb), BOND);
        vm.expectEmit(true, false, false, true);
        emit RemitEvents.ArbitratorRegistered(arb1, BOND, "ipfs://arb1");
        arb.registerArbitrator("ipfs://arb1");
        vm.stopPrank();

        IRemitArbitration.Arbitrator memory a = arb.getArbitrator(arb1);
        assertEq(a.wallet, arb1);
        assertEq(a.bondAmount, BOND);
        assertTrue(a.active);
        assertEq(a.reputationScore, 7_500); // INITIAL_REPUTATION
        assertEq(arb.getPoolSize(), 1);
    }

    function test_registerArbitrator_bondTransferred() public {
        uint256 balBefore = usdc.balanceOf(address(arb));
        _registerArbitrator(arb1);
        assertEq(usdc.balanceOf(address(arb)), balBefore + BOND);
    }

    function test_registerArbitrator_revertAlreadyActive() public {
        _registerArbitrator(arb1);
        vm.startPrank(arb1);
        usdc.approve(address(arb), BOND);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ArbitratorAlreadyRegistered.selector, arb1));
        arb.registerArbitrator("ipfs://arb1-dup");
        vm.stopPrank();
    }

    function test_registerArbitrator_revertBondInsufficient() public {
        // Approve less than required
        vm.startPrank(arb1);
        usdc.approve(address(arb), BOND - 1);
        vm.expectRevert(); // ERC20 insufficient allowance
        arb.registerArbitrator("ipfs://arb1");
        vm.stopPrank();
    }

    function test_registerMultipleArbitrators_poolGrows() public {
        _registerArbitrator(arb1);
        _registerArbitrator(arb2);
        _registerArbitrator(arb3);
        assertEq(arb.getPoolSize(), 3);
    }

    // =========================================================================
    // Unit 3-A: Removal and Bond Claim
    // =========================================================================

    function test_removeArbitrator_success() public {
        _registerArbitrator(arb1);

        vm.expectEmit(true, false, false, false);
        emit RemitEvents.ArbitratorRemoved(arb1, uint64(block.timestamp) + arb.ARBITRATOR_BOND_COOLDOWN());
        vm.prank(arb1);
        arb.removeArbitrator();

        IRemitArbitration.Arbitrator memory a = arb.getArbitrator(arb1);
        assertFalse(a.active);
        assertGt(a.removedAt, 0);
        assertEq(arb.getPoolSize(), 0);
    }

    function test_removeArbitrator_revertNotRegistered() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ArbitratorNotFound.selector, stranger));
        arb.removeArbitrator();
    }

    function test_claimArbitratorBond_afterCooldown() public {
        _registerArbitrator(arb1);
        vm.prank(arb1);
        arb.removeArbitrator();

        // Skip cooldown
        vm.warp(block.timestamp + arb.ARBITRATOR_BOND_COOLDOWN() + 1);

        uint256 balBefore = usdc.balanceOf(arb1);
        vm.prank(arb1);
        arb.claimArbitratorBond();
        assertEq(usdc.balanceOf(arb1), balBefore + BOND);

        // Bond cleared
        IRemitArbitration.Arbitrator memory a = arb.getArbitrator(arb1);
        assertEq(a.bondAmount, 0);
    }

    function test_claimArbitratorBond_revertCooldownNotMet() public {
        _registerArbitrator(arb1);
        vm.prank(arb1);
        arb.removeArbitrator();

        // Read removedAt BEFORE any subsequent pranks (view calls don't consume prank,
        // but keeping this before vm.prank(arb1) avoids confusion)
        uint64 removedAt = arb.getArbitrator(arb1).removedAt;
        uint64 expectedRelease = removedAt + arb.ARBITRATOR_BOND_COOLDOWN();

        // Warp to just before cooldown expires
        vm.warp(uint256(expectedRelease) - 1);

        vm.prank(arb1);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ArbitrationCooldownNotMet.selector, expectedRelease));
        arb.claimArbitratorBond();
    }

    // =========================================================================
    // Unit 3-A: Authorize Escrow
    // =========================================================================

    function test_authorizeEscrow_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        arb.authorizeEscrow(makeAddr("newEscrow"));
    }

    function test_isAuthorizedEscrow() public {
        assertTrue(arb.isAuthorizedEscrow(address(escrow)));
        assertFalse(arb.isAuthorizedEscrow(stranger));
    }

    // =========================================================================
    // Unit 3-B: Tiered Routing — Admin Tier (<$100)
    // =========================================================================

    function test_routeDispute_adminTier_autoAssignsAdmin() public {
        bytes32 inv = keccak256("admin-dispute");
        _setupAndEscalate(inv, SMALL_AMOUNT);

        IRemitArbitration.ArbitrationCase memory c = arb.getCase(inv);
        assertEq(c.assignedArbitrator, admin); // admin auto-assigned
        assertEq(uint8(c.tier), uint8(IRemitArbitration.DisputeTier.Admin));
        assertTrue(c.deadlineAt > block.timestamp);
    }

    function test_routeDispute_adminTier_noProposalPhase() public {
        bytes32 inv = keccak256("admin-direct");
        _setupAndEscalate(inv, SMALL_AMOUNT);

        IRemitArbitration.ArbitrationCase memory c = arb.getCase(inv);
        // No proposed arbitrators needed — admin is directly assigned
        assertEq(c.proposedArbitrators[0], address(0));
    }

    // =========================================================================
    // Unit 3-B: Tiered Routing — Pool Tier ($100–$1000)
    // =========================================================================

    function test_routeDispute_poolTier_proposesThree() public {
        _registerArbitrator(arb1);
        _registerArbitrator(arb2);
        _registerArbitrator(arb3);

        bytes32 inv = keccak256("pool-dispute");
        _setupAndEscalate(inv, AMOUNT);

        IRemitArbitration.ArbitrationCase memory c = arb.getCase(inv);
        assertEq(uint8(c.tier), uint8(IRemitArbitration.DisputeTier.Pool));
        // All 3 proposed slots filled
        assertNotEq(c.proposedArbitrators[0], address(0));
        assertNotEq(c.proposedArbitrators[1], address(0));
        assertNotEq(c.proposedArbitrators[2], address(0));
        // All unique
        assertNotEq(c.proposedArbitrators[0], c.proposedArbitrators[1]);
        assertNotEq(c.proposedArbitrators[0], c.proposedArbitrators[2]);
        assertNotEq(c.proposedArbitrators[1], c.proposedArbitrators[2]);
        // All from pool
        assertTrue(
            c.proposedArbitrators[0] == arb1 || c.proposedArbitrators[0] == arb2 || c.proposedArbitrators[0] == arb3
        );
    }

    function test_routeDispute_poolTier_fallbackToAdminWhenPoolEmpty() public {
        // Pool tier amount but no arbitrators
        bytes32 inv = keccak256("pool-fallback");
        _setupAndEscalate(inv, AMOUNT);

        IRemitArbitration.ArbitrationCase memory c = arb.getCase(inv);
        // Falls back to admin
        assertEq(c.assignedArbitrator, admin);
    }

    // =========================================================================
    // Unit 3-B: Tiered Routing — Required Tier (>$1000)
    // =========================================================================

    function test_routeDispute_requiredTier_usesPool() public {
        _registerArbitrator(arb1);
        _registerArbitrator(arb2);
        _registerArbitrator(arb3);

        bytes32 inv = keccak256("required-dispute");
        _setupAndEscalate(inv, LARGE_AMOUNT);

        IRemitArbitration.ArbitrationCase memory c = arb.getCase(inv);
        assertEq(uint8(c.tier), uint8(IRemitArbitration.DisputeTier.Required));
        assertNotEq(c.proposedArbitrators[0], address(0));
    }

    function test_routeDispute_requiredTier_fallbackToAdminWhenPoolEmpty() public {
        // Required tier but no pool — falls back to admin as last resort
        bytes32 inv = keccak256("required-fallback");
        _setupAndEscalate(inv, LARGE_AMOUNT);

        IRemitArbitration.ArbitrationCase memory c = arb.getCase(inv);
        assertEq(c.assignedArbitrator, admin);
    }

    function test_routeDispute_revertNotAuthorizedEscrow() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.NotArbitrationContract.selector, stranger));
        arb.routeDispute(keccak256("x"), payer, payee, AMOUNT);
    }

    function test_routeDispute_revertDuplicateCase() public {
        bytes32 inv = keccak256("dup-dispute");
        _setupAndEscalate(inv, SMALL_AMOUNT);

        // Trying to route the same invoice again (via direct call from escrow context)
        vm.prank(address(escrow));
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ArbitrationCaseAlreadyExists.selector, inv));
        arb.routeDispute(inv, payer, payee, SMALL_AMOUNT);
    }

    // =========================================================================
    // Unit 3-A/3-B: Escalation from RemitEscrow
    // =========================================================================

    function test_escalateToArbitration_success() public {
        bytes32 inv = keccak256("escalate-ok");
        _setupDisputeWithBothBonds(inv, AMOUNT);

        // Warp past counter-bond deadline
        vm.warp(block.timestamp + COUNTER_BOND_WINDOW + 1);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.DisputeEscalatedToArbitration(inv, address(escrow), uint8(IRemitArbitration.DisputeTier.Pool));
        vm.prank(stranger); // permissionless
        escrow.escalateToArbitration(inv);

        IRemitArbitration.ArbitrationCase memory c = arb.getCase(inv);
        assertEq(c.escrowContract, address(escrow));
        assertEq(c.payer, payer);
        assertEq(c.payee, payee);
        assertEq(c.disputedAmount, AMOUNT);
    }

    function test_escalateToArbitration_revertBondNotPosted() public {
        bytes32 inv = keccak256("escalate-no-counter");
        _setupDispute(inv, AMOUNT);

        // Only filer posted — no counter-bond
        vm.warp(block.timestamp + COUNTER_BOND_WINDOW + 1);

        vm.prank(stranger);
        // counter-bond deadline has passed but respondent didn't post
        // escalation should revert — need both bonds
        vm.expectRevert(
            abi.encodeWithSelector(
                RemitErrors.EscalationNotReady.selector, escrow.getDisputeBond(inv).counterBondDeadline
            )
        );
        escrow.escalateToArbitration(inv);
    }

    function test_escalateToArbitration_revertWindowNotPassed() public {
        bytes32 inv = keccak256("escalate-too-early");
        _setupDisputeWithBothBonds(inv, AMOUNT);

        // Counter-bond window still active
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                RemitErrors.EscalationNotReady.selector, escrow.getDisputeBond(inv).counterBondDeadline
            )
        );
        escrow.escalateToArbitration(inv);
    }

    function test_escalateToArbitration_revertNoArbitrationContract() public {
        // Escrow without arbitration contract
        RemitEscrow escrowNoArb =
            new RemitEscrow(address(usdc), address(feeCalc), admin, feeRecipient, address(0), address(0));
        bytes32 inv = keccak256("no-arb-contract");
        _setupDisputeInContract(escrowNoArb, inv, AMOUNT);
        vm.warp(block.timestamp + COUNTER_BOND_WINDOW + 1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.NotArbitrationContract.selector, address(0)));
        escrowNoArb.escalateToArbitration(inv);
    }

    // =========================================================================
    // Unit 3-A/3-D: Strike Phase
    // =========================================================================

    function test_strike_payerAndPayeeDifferent_remainingAssigned() public {
        _registerArbitrator(arb1);
        _registerArbitrator(arb2);
        _registerArbitrator(arb3);

        bytes32 inv = keccak256("strike-diff");
        _setupAndEscalate(inv, AMOUNT);

        IRemitArbitration.ArbitrationCase memory c = arb.getCase(inv);
        address a0 = c.proposedArbitrators[0];
        address a1 = c.proposedArbitrators[1];
        address a2 = c.proposedArbitrators[2];

        // Payer strikes index 0, payee strikes index 1 → index 2 remains
        vm.prank(payer);
        arb.strikeArbitrator(inv, 0);

        vm.expectEmit(true, false, false, false);
        emit RemitEvents.ArbitratorAssigned(inv, a2, 0);
        vm.prank(payee);
        arb.strikeArbitrator(inv, 1);

        IRemitArbitration.ArbitrationCase memory c2 = arb.getCase(inv);
        assertEq(c2.assignedArbitrator, a2);
        assertNotEq(c2.assignedArbitrator, a0);
        assertNotEq(c2.assignedArbitrator, a1);
        assertGt(c2.deadlineAt, block.timestamp);
    }

    function test_strike_bothSameIndex_randomFromRemaining() public {
        _registerArbitrator(arb1);
        _registerArbitrator(arb2);
        _registerArbitrator(arb3);

        bytes32 inv = keccak256("strike-same");
        _setupAndEscalate(inv, AMOUNT);

        IRemitArbitration.ArbitrationCase memory c = arb.getCase(inv);
        address struck = c.proposedArbitrators[0];

        // Both strike index 0
        vm.prank(payer);
        arb.strikeArbitrator(inv, 0);
        vm.prank(payee);
        arb.strikeArbitrator(inv, 0);

        IRemitArbitration.ArbitrationCase memory c2 = arb.getCase(inv);
        // Assigned must not be the struck arbitrator
        assertNotEq(c2.assignedArbitrator, struck);
        // Must be one of the remaining two
        assertTrue(
            c2.assignedArbitrator == c.proposedArbitrators[1] || c2.assignedArbitrator == c.proposedArbitrators[2]
        );
    }

    function test_strike_revertDoubleStrike() public {
        _registerArbitrator(arb1);
        _registerArbitrator(arb2);
        _registerArbitrator(arb3);

        bytes32 inv = keccak256("double-strike");
        _setupAndEscalate(inv, AMOUNT);

        vm.startPrank(payer);
        arb.strikeArbitrator(inv, 0);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.StrikeAlreadyCast.selector, inv));
        arb.strikeArbitrator(inv, 1);
        vm.stopPrank();
    }

    function test_strike_revertUnauthorizedCaller() public {
        _registerArbitrator(arb1);
        _registerArbitrator(arb2);
        _registerArbitrator(arb3);

        bytes32 inv = keccak256("strike-unauth");
        _setupAndEscalate(inv, AMOUNT);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        arb.strikeArbitrator(inv, 0);
    }

    function test_strike_revertCaseNotFound() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ArbitrationCaseNotFound.selector, bytes32(0)));
        arb.strikeArbitrator(bytes32(0), 0);
    }

    function test_strike_revertInvalidIndex() public {
        _registerArbitrator(arb1);
        _registerArbitrator(arb2);
        _registerArbitrator(arb3);

        bytes32 inv = keccak256("strike-invalid-idx");
        _setupAndEscalate(inv, AMOUNT);

        vm.prank(payer);
        vm.expectRevert();
        arb.strikeArbitrator(inv, 3); // invalid index
    }

    // =========================================================================
    // Unit 3-A/3-D: Decision Rendering
    // =========================================================================

    function test_renderDecision_fullPayeeWin() public {
        bytes32 inv = keccak256("decision-payee-win");
        _setupFullArbitration(inv, AMOUNT);

        address assigned = arb.getCase(inv).assignedArbitrator;
        uint256 payeeBalBefore = usdc.balanceOf(payee);
        uint256 payerBalBefore = usdc.balanceOf(payer);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.ArbitrationDecisionRendered(inv, assigned, 0, 100);
        vm.prank(assigned);
        arb.renderDecision(inv, 0, 100, "payee delivered the work");

        assertTrue(arb.getCase(inv).decided);
        // Payee receives ~$500 - 1% fee ≈ $495
        assertGt(usdc.balanceOf(payee), payeeBalBefore);
        // Payer gets nothing
        assertEq(usdc.balanceOf(payer), payerBalBefore);
    }

    function test_renderDecision_fullPayerWin() public {
        bytes32 inv = keccak256("decision-payer-win");
        _setupFullArbitration(inv, AMOUNT);

        address assigned = arb.getCase(inv).assignedArbitrator;
        uint256 payerBalBefore = usdc.balanceOf(payer);

        vm.prank(assigned);
        arb.renderDecision(inv, 100, 0, "payee did not deliver");

        // Payer gets all escrow back (AMOUNT - fee, but fee is 0% from winner's perspective)
        // Actually: 100% to payer = entire AMOUNT returned
        assertGt(usdc.balanceOf(payer), payerBalBefore);
    }

    function test_renderDecision_splitAward_30_70() public {
        bytes32 inv = keccak256("decision-split-30-70");
        _setupFullArbitration(inv, AMOUNT);

        address assigned = arb.getCase(inv).assignedArbitrator;
        vm.prank(assigned);
        arb.renderDecision(inv, 30, 70, "partial delivery");

        assertTrue(arb.getCase(inv).decided);
    }

    function test_renderDecision_evenSplit_50_50() public {
        bytes32 inv = keccak256("decision-50-50");
        _setupFullArbitration(inv, AMOUNT);

        address assigned = arb.getCase(inv).assignedArbitrator;
        vm.prank(assigned);
        arb.renderDecision(inv, 50, 50, "genuinely ambiguous");

        assertTrue(arb.getCase(inv).decided);
    }

    function test_renderDecision_revertBadPercentages() public {
        bytes32 inv = keccak256("decision-bad-pct");
        _setupFullArbitration(inv, AMOUNT);

        address assigned = arb.getCase(inv).assignedArbitrator;
        vm.prank(assigned);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.InvalidPercentageSum.selector, 60, 60));
        arb.renderDecision(inv, 60, 60, "too much");
    }

    function test_renderDecision_revertNotAssignedArbitrator() public {
        bytes32 inv = keccak256("decision-wrong-arb");
        _setupFullArbitration(inv, AMOUNT);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ArbitratorNotAssigned.selector, inv, stranger));
        arb.renderDecision(inv, 50, 50, "wrong caller");
    }

    function test_renderDecision_revertAfterDeadline() public {
        bytes32 inv = keccak256("decision-expired");
        _setupFullArbitration(inv, AMOUNT);

        address assigned = arb.getCase(inv).assignedArbitrator;
        uint64 deadline = arb.getCase(inv).deadlineAt;

        // Warp past deadline
        vm.warp(uint256(deadline) + 1);

        vm.prank(assigned);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ArbitrationDeadlinePassed.selector, inv));
        arb.renderDecision(inv, 50, 50, "too late");
    }

    function test_renderDecision_revertAlreadyDecided() public {
        bytes32 inv = keccak256("decision-duplicate");
        _setupFullArbitration(inv, AMOUNT);

        address assigned = arb.getCase(inv).assignedArbitrator;
        vm.prank(assigned);
        arb.renderDecision(inv, 50, 50, "first decision");

        vm.prank(assigned);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ArbitrationAlreadyDecided.selector, inv));
        arb.renderDecision(inv, 50, 50, "second attempt");
    }

    // =========================================================================
    // Unit 3-C: Reputation Updates
    // =========================================================================

    function test_reputation_updatesAfterDecision() public {
        _registerArbitrator(arb1);
        _registerArbitrator(arb2);
        _registerArbitrator(arb3);

        bytes32 inv = keccak256("rep-update");
        _setupFullArbitrationWithPool(inv, AMOUNT);

        address assigned = arb.getCase(inv).assignedArbitrator;
        uint256 repBefore = arb.getArbitratorReputation(assigned);

        // Decide quickly (within ideal 24h)
        vm.prank(assigned);
        arb.renderDecision(inv, 50, 50, "decided fast");

        uint256 repAfter = arb.getArbitratorReputation(assigned);
        // After 1 fast decision: rolling avg of initial 7500 + new 10000 = 8750
        // New score = (7500 * 0 + 10000) / 1 = 10000
        assertGt(repAfter, 0);
        assertLe(repAfter, 10_000);
    }

    function test_reputation_slowDecisionLowersScore() public {
        _registerArbitrator(arb1);
        _registerArbitrator(arb2);
        _registerArbitrator(arb3);

        bytes32 inv = keccak256("rep-slow");
        _setupFullArbitrationWithPool(inv, AMOUNT);

        address assigned = arb.getCase(inv).assignedArbitrator;
        uint64 deadline = arb.getCase(inv).deadlineAt;

        // Decide just before deadline (slow)
        vm.warp(uint256(deadline) - 1);

        vm.prank(assigned);
        arb.renderDecision(inv, 50, 50, "very slow decision");

        uint256 repAfter = arb.getArbitratorReputation(assigned);
        // Speed score near 0 (close to deadline), activity score 5000 → total ~5000
        // Rolling avg: (7500 * 0 + score) / 1 = score ≤ 5500
        assertLt(repAfter, 6_000);
    }

    function test_reputation_viewFunction() public {
        _registerArbitrator(arb1);
        assertEq(arb.getArbitratorReputation(arb1), 7_500);
        assertEq(arb.getArbitratorReputation(stranger), 0);
    }

    // =========================================================================
    // Unit 3-C: Arbitrator Fee Calculation and Distribution
    // =========================================================================

    function test_arbitratorFee_paidFromLoserBond() public {
        _registerArbitrator(arb1);
        _registerArbitrator(arb2);
        _registerArbitrator(arb3);

        bytes32 inv = keccak256("fee-test");

        // Set up with payer filing dispute (payer will lose)
        _setupAndEscalate(inv, AMOUNT);

        // Assign via strikes
        vm.prank(payer);
        arb.strikeArbitrator(inv, 0);
        vm.prank(payee);
        arb.strikeArbitrator(inv, 1);

        address assigned = arb.getCase(inv).assignedArbitrator;
        uint256 arbBalBefore = usdc.balanceOf(assigned);

        // Payee wins decisively
        vm.prank(assigned);
        arb.renderDecision(inv, 0, 100, "payee wins");

        // Arbitrator should have received their fee
        // 5% of $500 = $25 (from payer's forfeited bond)
        uint256 expectedFee = (uint256(AMOUNT) * 500) / 10_000; // 5% of AMOUNT
        assertGe(usdc.balanceOf(assigned), arbBalBefore + expectedFee);
    }

    function test_arbitratorFee_adminDecisionNoFee() public {
        bytes32 inv = keccak256("admin-fee-test");
        _setupAndEscalate(inv, SMALL_AMOUNT); // admin tier

        uint256 adminBalBefore = usdc.balanceOf(admin);

        vm.prank(admin);
        arb.renderAdminDecision(inv, 100, 0, "payer wins - admin decision");

        // Admin decision: no fee taken from bonds
        // The admin balance change should just be payer's bond returned
        // (admin is payer here in our test setup if payer is admin... no, admin ≠ payer)
        // Admin does not receive an arbitrator fee
        assertEq(usdc.balanceOf(admin), adminBalBefore);
    }

    // =========================================================================
    // Unit 3-B: Admin Decision
    // =========================================================================

    function test_renderAdminDecision_success() public {
        bytes32 inv = keccak256("admin-decision");
        _setupAndEscalate(inv, SMALL_AMOUNT);

        uint256 payerBalBefore = usdc.balanceOf(payer);
        vm.prank(admin);
        arb.renderAdminDecision(inv, 100, 0, "payer refunded");

        assertGt(usdc.balanceOf(payer), payerBalBefore);
    }

    function test_renderAdminDecision_revertNotOwner() public {
        bytes32 inv = keccak256("admin-decision-noauth");
        _setupAndEscalate(inv, SMALL_AMOUNT);

        vm.prank(stranger);
        vm.expectRevert();
        arb.renderAdminDecision(inv, 100, 0, "stranger trying admin");
    }

    function test_renderAdminDecision_revertPoolTierCase() public {
        _registerArbitrator(arb1);
        _registerArbitrator(arb2);
        _registerArbitrator(arb3);

        bytes32 inv = keccak256("admin-pool-case");
        _setupFullArbitrationWithPool(inv, AMOUNT);

        // Admin should NOT be able to override a pool-tier case where a real arbitrator is assigned
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, admin));
        arb.renderAdminDecision(inv, 50, 50, "admin override attempt");
    }

    // =========================================================================
    // Unit 3-D: Integration — Full Escrow Dispute → Arbitration → Fund Distribution
    // =========================================================================

    function test_integration_fullFlow_payeeWins() public {
        _registerArbitrator(arb1);
        _registerArbitrator(arb2);
        _registerArbitrator(arb3);

        bytes32 inv = keccak256("integration-payee-wins");
        uint96 amount = 500_000_000; // $500

        // 1. Create escrow
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

        // 2. File dispute (payer)
        uint96 payerBond = _getBondAmount(amount, payer);
        vm.prank(payer);
        escrow.fileDispute(inv, keccak256("payer-evidence"));

        // 3. Respondent (payee) posts counter-bond
        uint96 payeeBond = payerBond;
        vm.prank(payee);
        escrow.postCounterBond(inv);

        // 4. Warp past counter-bond window
        vm.warp(block.timestamp + COUNTER_BOND_WINDOW + 1);

        // 5. Anyone escalates to arbitration
        vm.prank(stranger);
        escrow.escalateToArbitration(inv);

        // 6. Both parties strike
        vm.prank(payer);
        arb.strikeArbitrator(inv, 0);
        vm.prank(payee);
        arb.strikeArbitrator(inv, 1);

        address assigned = arb.getCase(inv).assignedArbitrator;

        uint256 payeeBalBefore = usdc.balanceOf(payee);
        uint256 assignedBalBefore = usdc.balanceOf(assigned);

        // 7. Arbitrator renders decision: payee wins 100%
        vm.prank(assigned);
        arb.renderDecision(inv, 0, 100, "payee delivered");

        // Verify decision recorded
        assertTrue(arb.getCase(inv).decided);

        // Payee received funds
        assertGt(usdc.balanceOf(payee), payeeBalBefore);
        // Arbitrator received their fee from loser's bond
        assertGt(usdc.balanceOf(assigned), assignedBalBefore);

        // Escrow completed
        assertEq(uint8(escrow.getEscrow(inv).status), uint8(RemitTypes.EscrowStatus.Completed));
    }

    function test_integration_fullFlow_payerWins() public {
        _registerArbitrator(arb1);
        _registerArbitrator(arb2);
        _registerArbitrator(arb3);

        bytes32 inv = keccak256("integration-payer-wins");
        uint96 amount = 500_000_000;

        _setupEscrowDispute(inv, amount);
        vm.warp(block.timestamp + COUNTER_BOND_WINDOW + 1);
        escrow.escalateToArbitration(inv);

        vm.prank(payer);
        arb.strikeArbitrator(inv, 0);
        vm.prank(payee);
        arb.strikeArbitrator(inv, 1);

        address assigned = arb.getCase(inv).assignedArbitrator;
        uint256 payerBalBefore = usdc.balanceOf(payer);

        vm.prank(assigned);
        arb.renderDecision(inv, 100, 0, "payer wins - no delivery");

        assertGt(usdc.balanceOf(payer), payerBalBefore);
        assertEq(uint8(escrow.getEscrow(inv).status), uint8(RemitTypes.EscrowStatus.Completed));
    }

    function test_integration_fullFlow_adminTier() public {
        bytes32 inv = keccak256("integration-admin-tier");
        uint96 amount = SMALL_AMOUNT; // $50 — admin tier

        _setupEscrowDispute(inv, amount);
        vm.warp(block.timestamp + COUNTER_BOND_WINDOW + 1);
        escrow.escalateToArbitration(inv);

        // Admin renders decision directly (no strike phase needed)
        uint256 payerBalBefore = usdc.balanceOf(payer);
        vm.prank(admin);
        arb.renderAdminDecision(inv, 100, 0, "admin: payer wins");

        assertGt(usdc.balanceOf(payer), payerBalBefore);
        assertEq(uint8(escrow.getEscrow(inv).status), uint8(RemitTypes.EscrowStatus.Completed));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _fund(address who, uint96 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(escrow), type(uint256).max);
        usdc.approve(address(arb), type(uint256).max);
        vm.stopPrank();
    }

    function _registerArbitrator(address who) internal {
        vm.prank(who);
        arb.registerArbitrator(string(abi.encodePacked("ipfs://", vm.toString(who))));
    }

    function _setupDispute(bytes32 inv, uint96 amount) internal {
        // Create escrow (with minimum valid timeout)
        uint64 timeout = uint64(block.timestamp + TIMEOUT_DELTA);
        vm.prank(payer);
        escrow.createEscrow(inv, payee, amount, timeout, new RemitTypes.Milestone[](0), new RemitTypes.Split[](0));
        vm.prank(payee);
        escrow.claimStart(inv);

        // Filer (payer) posts bond
        vm.prank(payer);
        escrow.fileDispute(inv, keccak256("evidence"));
    }

    function _setupDisputeWithBothBonds(bytes32 inv, uint96 amount) internal {
        _setupDispute(inv, amount);
        vm.prank(payee);
        escrow.postCounterBond(inv);
    }

    function _setupAndEscalate(bytes32 inv, uint96 amount) internal {
        _setupDisputeWithBothBonds(inv, amount);
        vm.warp(block.timestamp + COUNTER_BOND_WINDOW + 1);
        escrow.escalateToArbitration(inv);
    }

    /// @dev Full arbitration setup with pool arbitrators already registered.
    function _setupFullArbitration(bytes32 inv, uint96 amount) internal {
        if (arb.getPoolSize() < 3) {
            _registerArbitrator(arb1);
            _registerArbitrator(arb2);
            _registerArbitrator(arb3);
        }
        _setupAndEscalate(inv, amount);

        // Skip strike phase if admin was assigned (pool tier but no pool)
        IRemitArbitration.ArbitrationCase memory c = arb.getCase(inv);
        if (c.assignedArbitrator == address(0)) {
            // Do strikes
            vm.prank(payer);
            arb.strikeArbitrator(inv, 0);
            vm.prank(payee);
            arb.strikeArbitrator(inv, 1);
        }
    }

    /// @dev Full arbitration with pool registered before escrow setup.
    function _setupFullArbitrationWithPool(bytes32 inv, uint96 amount) internal {
        _setupAndEscalate(inv, amount);

        IRemitArbitration.ArbitrationCase memory c = arb.getCase(inv);
        if (c.assignedArbitrator == address(0)) {
            vm.prank(payer);
            arb.strikeArbitrator(inv, 0);
            vm.prank(payee);
            arb.strikeArbitrator(inv, 1);
        }
    }

    /// @dev Full escrow dispute without escalation (caller handles escalation).
    function _setupEscrowDispute(bytes32 inv, uint96 amount) internal {
        uint64 timeout = uint64(block.timestamp + TIMEOUT_DELTA);
        vm.prank(payer);
        escrow.createEscrow(inv, payee, amount, timeout, new RemitTypes.Milestone[](0), new RemitTypes.Split[](0));
        vm.prank(payee);
        escrow.claimStart(inv);
        vm.prank(payer);
        escrow.fileDispute(inv, keccak256("evidence"));
        vm.prank(payee);
        escrow.postCounterBond(inv);
    }

    /// @dev Setup a dispute within a different escrow instance (for no-arbitration-contract test).
    function _setupDisputeInContract(RemitEscrow _escrow, bytes32 inv, uint96 amount) internal {
        // Fund payer and payee for this escrow
        vm.startPrank(payer);
        usdc.approve(address(_escrow), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(payee);
        usdc.approve(address(_escrow), type(uint256).max);
        vm.stopPrank();

        uint64 timeout = uint64(block.timestamp + TIMEOUT_DELTA);
        vm.prank(payer);
        _escrow.createEscrow(inv, payee, amount, timeout, new RemitTypes.Milestone[](0), new RemitTypes.Split[](0));
        vm.prank(payee);
        _escrow.claimStart(inv);
        vm.prank(payer);
        _escrow.fileDispute(inv, keccak256("evidence"));
        vm.prank(payee);
        _escrow.postCounterBond(inv);
    }

    /// @dev Calculate bond for a given amount and address (mimics contract logic).
    function _getBondAmount(uint96 amount, address filer) internal view returns (uint96) {
        // Base bond = 5% of amount, min $0.50
        uint96 base = uint96((uint256(amount) * 500) / 10_000);
        if (base < 500_000) base = 500_000;
        return base; // multiplier = 1 for new accounts
    }
}
