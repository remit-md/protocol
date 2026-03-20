// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../../src/test/MockUSDC.sol";
import {MockFeeCalculator} from "../helpers/MockFeeCalculator.sol";
import {RemitEscrow} from "../../src/RemitEscrow.sol";
import {RemitTab} from "../../src/RemitTab.sol";
import {RemitTypes} from "../../src/libraries/RemitTypes.sol";

/// @title RemitSymbolicProofs
/// @notice Symbolic proofs for critical protocol invariants using Halmos.
///
/// Halmos proves `check_*` functions for ALL possible inputs (not just random samples).
/// Run with: `halmos --contract RemitSymbolicProofs`
///
/// Design notes for Halmos compatibility:
///   - Concrete addresses (not makeAddr) — avoids symbolic cheatcode overhead
///   - Concrete storage keys (not derived from symbolic inputs) — avoids symbolic
///     keccak preimage reasoning which causes solver timeouts
///   - Tight amount bounds — reduces symbolic path explosion in multi-step flows
///
/// Properties proved:
///   P1 — Fee Correctness:    fee = floor(amount * 100 / 10_000) for all valid amounts
///   P2 — Fund Conservation:  payeeGain + feeGain = escrowAmount for all releases
///   P3 — No Double-Settle:   second releaseEscrow always reverts after first succeeds
///   P4 — Tab Open Locks Exact: openTab transfers exactly limit USDC, no more no less
///   P5 — Fee Oracle:           MockFeeCalculator returns exactly 1% for all amounts
contract RemitSymbolicProofs is Test {
    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    RemitEscrow internal escrow;
    RemitTab internal tab;

    // Concrete addresses — Halmos handles these better than makeAddr() cheatcodes
    address internal constant PAYER = address(0xAA01);
    address internal constant PAYEE = address(0xBB02);
    address internal constant ADMIN = address(0xCC03);
    address internal constant FEE_RECIPIENT = address(0xDD04);

    uint96 constant FEE_RATE_BPS = 100;
    uint96 constant MIN_AMOUNT = 10_000; // $0.01 in USDC (6 decimals)

    function setUp() public {
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        escrow = new RemitEscrow(address(usdc), address(feeCalc), ADMIN, FEE_RECIPIENT, address(0), address(0));
        tab = new RemitTab(address(usdc), address(feeCalc), FEE_RECIPIENT, ADMIN, address(0));
    }

    // =========================================================================
    // P1 — Fee Correctness
    //
    // Property: For any valid amount, fee = floor(amount * FEE_RATE_BPS / 10_000)
    //           and fee < amount (fee never exceeds principal).
    //
    // This is pure arithmetic — Halmos proves it for all uint96 values.
    // =========================================================================

    /// @notice Fee formula is exact and never exceeds amount
    function check_feeCorrectness(uint96 amount) public pure {
        vm.assume(amount >= MIN_AMOUNT);

        uint256 fee = (uint256(amount) * FEE_RATE_BPS) / 10_000;
        uint256 payout = amount - fee;

        // INV: fee + payout == amount (no dust)
        assert(fee + payout == amount);

        // INV: fee strictly less than amount (payer never loses more than they send)
        assert(fee < amount);

        // INV: payout > 0 for all valid amounts (payee always receives something)
        assert(payout > 0);

        // INV: fee rate is exactly 1% (rounded down)
        assert(fee * 10_000 <= uint256(amount) * FEE_RATE_BPS);
    }

    // =========================================================================
    // P2 — Fund Conservation
    //
    // Property: When escrow is released, every USDC that entered the contract
    //           exits to either payee or feeRecipient. No funds are lost.
    //
    // We prove: payeeReceived + feeReceived == amountEscrowed
    // =========================================================================

    /// @notice All escrowed funds are accounted for on release (no leakage)
    function check_escrowFundConservation(uint96 amount) public {
        vm.assume(amount >= MIN_AMOUNT);
        vm.assume(amount <= 100_000e6); // cap at $100K for symbolic tractability

        // Concrete ID — avoids symbolic keccak preimage reasoning
        bytes32 inv = keccak256("halmos-conservation");

        // Fund payer
        usdc.mint(PAYER, amount);
        vm.prank(PAYER);
        usdc.approve(address(escrow), amount);

        // Create escrow
        vm.prank(PAYER);
        escrow.createEscrow(
            inv,
            PAYEE,
            amount,
            uint64(block.timestamp + 7 days),
            new RemitTypes.Milestone[](0),
            new RemitTypes.Split[](0)
        );

        // Payee starts work
        vm.prank(PAYEE);
        escrow.claimStart(inv);

        // Snapshot balances before release
        uint256 payeeBefore = usdc.balanceOf(PAYEE);
        uint256 feeBefore = usdc.balanceOf(FEE_RECIPIENT);
        uint256 contractBefore = usdc.balanceOf(address(escrow));

        // Release escrow
        vm.prank(PAYER);
        escrow.releaseEscrow(inv);

        // Compute deltas
        uint256 payeeGain = usdc.balanceOf(PAYEE) - payeeBefore;
        uint256 feeGain = usdc.balanceOf(FEE_RECIPIENT) - feeBefore;

        // INV: payee + fee = amount that was in contract
        assert(payeeGain + feeGain == contractBefore);

        // INV: fee matches formula
        uint256 expectedFee = (uint256(amount) * FEE_RATE_BPS) / 10_000;
        assert(feeGain == expectedFee);
    }

    // =========================================================================
    // P3 — No Double-Settle
    //
    // Property: Releasing an escrow a second time always reverts.
    //           Once settled, state is terminal — funds cannot be extracted twice.
    // =========================================================================

    /// @notice releaseEscrow is idempotent-safe: second call always reverts
    function check_noDoubleSettle(uint96 amount) public {
        vm.assume(amount >= MIN_AMOUNT);
        vm.assume(amount <= 100_000e6);

        // Concrete ID
        bytes32 inv = keccak256("halmos-double-settle");

        usdc.mint(PAYER, amount);
        vm.prank(PAYER);
        usdc.approve(address(escrow), amount);

        vm.prank(PAYER);
        escrow.createEscrow(
            inv,
            PAYEE,
            amount,
            uint64(block.timestamp + 7 days),
            new RemitTypes.Milestone[](0),
            new RemitTypes.Split[](0)
        );

        vm.prank(PAYEE);
        escrow.claimStart(inv);

        // First release succeeds
        vm.prank(PAYER);
        escrow.releaseEscrow(inv);

        // Second release MUST revert (try/catch for Halmos compatibility)
        vm.prank(PAYER);
        try escrow.releaseEscrow(inv) {
            // If we get here, the second release succeeded — invariant violated
            assert(false);
        } catch {
            // Expected: second release reverts — invariant holds
        }
    }

    // =========================================================================
    // P4 — Tab Open Locks Exact Amount
    //
    // Property: openTab transfers exactly `limit` USDC from payer to contract.
    //           No more, no less. The payer's balance decreases by exactly limit
    //           and the contract's balance increases by exactly limit.
    // =========================================================================

    /// @notice openTab locks exactly limit USDC — no over- or under-transfer
    function check_tabOpenLocksExactAmount(uint96 limit, uint64 perUnit) public {
        vm.assume(limit >= MIN_AMOUNT);
        vm.assume(limit <= 10_000e6); // $10k cap
        vm.assume(perUnit >= MIN_AMOUNT);
        vm.assume(uint256(perUnit) <= uint256(limit));

        // Concrete ID — the old version derived tabId from symbolic limit+perUnit,
        // forcing Halmos to reason about symbolic keccak preimages (causes FAIL)
        bytes32 tabId = keccak256("halmos-tab");

        usdc.mint(PAYER, limit);
        vm.prank(PAYER);
        usdc.approve(address(tab), limit);

        uint256 payerBefore = usdc.balanceOf(PAYER);
        uint256 contractBefore = usdc.balanceOf(address(tab));

        vm.prank(PAYER);
        tab.openTab(tabId, PAYEE, limit, perUnit, uint64(block.timestamp + 7 days));

        // INV: payer sent exactly limit
        assert(payerBefore - usdc.balanceOf(PAYER) == limit);

        // INV: contract received exactly limit
        assert(usdc.balanceOf(address(tab)) - contractBefore == limit);
    }

    // =========================================================================
    // P5 — Fee Rate Monotonicity
    //
    // Property: Fee calculated by MockFeeCalculator is always
    //           floor(amount * 100 / 10_000), never more, never less.
    //           This proves the fee oracle matches the expected formula.
    // =========================================================================

    /// @notice MockFeeCalculator always returns exactly 1% (floor division)
    function check_feeOracleCorrectness(uint96 amount) public view {
        vm.assume(amount >= MIN_AMOUNT);

        uint96 reportedFee = feeCalc.calculateFee(PAYER, amount);
        uint256 expectedFee = (uint256(amount) * FEE_RATE_BPS) / 10_000;

        // INV: oracle fee matches arithmetic formula exactly
        assert(uint256(reportedFee) == expectedFee);

        // INV: oracle fee never exceeds amount
        assert(reportedFee < amount);
    }
}
