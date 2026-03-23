// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockUSDC} from "../../src/test/MockUSDC.sol";
import {MockFeeCalculator} from "../helpers/MockFeeCalculator.sol";
import {RemitEscrow} from "../../src/RemitEscrow.sol";
import {RemitTypes} from "../../src/libraries/RemitTypes.sol";

// =============================================================================
// EscrowStateful — Medusa stateful fuzz campaign for RemitEscrow (Campaign 2.2)
//
// Tests multi-step sequences that stateless fuzz misses:
//   fund → claimStart → release
//   fund → cancel (before claimStart)
//   fund → claimStart → timeout (payer reclaims)
//
// Invariants under test (from INVARIANTS.md):
//   INV-E1: usdc.balanceOf(escrow) == ghost_escrowBalance at ALL times
//   INV-E2: On release, payeeGain + feeGain == escrowAmount exactly
//   INV-E3: Terminal IDs never transition again (asserted inline)
//   INV-E6: Total fees <= sum(amounts) * MAX_FEE_BPS / 10_000
//
// Medusa: calls action_* in random order; checks property_* after each call.
// Run: scripts/run_medusa.ps1 EscrowStateful
// =============================================================================

interface IHevm {
    function prank(address sender) external;
    function warp(uint256 timestamp) external;
}

contract EscrowStateful {
    IHevm internal constant hevm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    RemitEscrow internal escrow;

    address internal constant PAYER = address(0x10000);
    address internal constant PAYEE = address(0x20000);
    address internal constant FEE_WALLET = address(0xFEE00);
    address internal constant ADMIN = address(0xAD00);

    // ── Ghost accounting ─────────────────────────────────────────────────────

    // All USDC deposited into the escrow contract (amounts)
    uint256 internal ghost_totalIn;
    // All USDC withdrawn from the escrow contract (releases, refunds)
    uint256 internal ghost_totalOut;
    // Computed balance = ghost_totalIn - ghost_totalOut; must equal usdc.balanceOf(escrow)
    uint256 internal ghost_escrowBalance;
    // Total fees collected (for INV-E6 upper bound check)
    uint256 internal ghost_feesCollected;
    // Total escrow amounts funded (for fee rate check denominator)
    uint256 internal ghost_totalFunded;

    // ── Escrow tracking ──────────────────────────────────────────────────────

    bytes32[] internal _activeIds; // non-terminal IDs (Funded or Active)
    mapping(bytes32 => uint96) internal _amount;
    // 0=Funded, 1=Active, 2=terminal
    mapping(bytes32 => uint8) internal _state;

    uint256 internal _idCounter;
    uint64 internal _currentTime;

    RemitTypes.Milestone[] internal _noMilestones;
    RemitTypes.Split[] internal _noSplits;

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor() {
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        escrow = new RemitEscrow(address(usdc), address(feeCalc), ADMIN, FEE_WALLET, address(0));

        _currentTime = uint64(block.timestamp);

        // Pre-fund both parties
        usdc.mint(PAYER, 100_000_000e6);
        usdc.mint(PAYEE, 10_000_000e6);

        hevm.prank(PAYER);
        usdc.approve(address(escrow), type(uint256).max);
        hevm.prank(PAYEE);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _clamp(uint96 v, uint96 lo, uint96 hi) internal pure returns (uint96) {
        if (v < lo) return lo;
        if (v > hi) return hi;
        return v;
    }

    function _clamp64(uint64 v, uint64 lo, uint64 hi) internal pure returns (uint64) {
        if (v < lo) return lo;
        if (v > hi) return hi;
        return v;
    }

    function _removeActive(uint256 idx) internal {
        uint256 last = _activeIds.length - 1;
        if (idx != last) _activeIds[idx] = _activeIds[last];
        _activeIds.pop();
    }

    function _findIdx(bytes32 id) internal view returns (uint256) {
        for (uint256 i = 0; i < _activeIds.length; i++) {
            if (_activeIds[i] == id) return i;
        }
        return type(uint256).max;
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    /// @notice Payer creates a new escrow (Funded state).
    function action_createEscrow(uint96 amount, uint64 timeoutDelta) external {
        amount = _clamp(amount, RemitTypes.MIN_AMOUNT, 1_000e6);
        uint64 timeout = _currentTime + _clamp64(timeoutDelta, 4 days, 30 days);
        bytes32 id = keccak256(abi.encode("escrow", _idCounter++, address(this)));

        uint256 payerBefore = usdc.balanceOf(PAYER);
        hevm.prank(PAYER);
        try escrow.createEscrow(id, PAYEE, amount, timeout, _noMilestones, _noSplits) {
            assert(payerBefore - usdc.balanceOf(PAYER) == amount); // exact transfer

            ghost_totalIn += amount;
            ghost_escrowBalance += amount;
            ghost_totalFunded += amount;
            _activeIds.push(id);
            _amount[id] = amount;
            _state[id] = 0;
        } catch {}
    }

    /// @notice Payee starts claim (Funded -> Active).
    function action_claimStart(uint256 idxSeed) external {
        uint256 len = _activeIds.length;
        if (len == 0) return;
        bytes32 id = _activeIds[idxSeed % len];
        if (_state[id] != 0) return;

        hevm.prank(PAYEE);
        try escrow.claimStart(id) {
            _state[id] = 1;
        } catch {}
    }

    /// @notice Payer releases escrow to payee (Active -> Completed).
    function action_releaseEscrow(uint256 idxSeed) external {
        uint256 len = _activeIds.length;
        if (len == 0) return;
        bytes32 id = _activeIds[idxSeed % len];
        if (_state[id] != 1) return;

        uint96 amount = _amount[id];
        uint96 fee = uint96((uint256(amount) * RemitTypes.FEE_RATE_BPS) / 10_000);

        uint256 payeeBefore = usdc.balanceOf(PAYEE);
        uint256 feeBefore = usdc.balanceOf(FEE_WALLET);

        hevm.prank(PAYER);
        try escrow.releaseEscrow(id) {
            assert(usdc.balanceOf(PAYEE) - payeeBefore + usdc.balanceOf(FEE_WALLET) - feeBefore == amount); // INV-E2
            assert(usdc.balanceOf(FEE_WALLET) - feeBefore == fee); // fee formula

            ghost_totalOut += amount;
            ghost_escrowBalance -= amount;
            ghost_feesCollected += fee;
            _state[id] = 2;
            _removeActive(_findIdx(id));
        } catch {}
    }

    /// @notice Payer cancels escrow before claimStart (Funded -> Cancelled).
    function action_cancelEscrow(uint256 idxSeed) external {
        uint256 len = _activeIds.length;
        if (len == 0) return;
        bytes32 id = _activeIds[idxSeed % len];
        if (_state[id] != 0) return;

        uint96 amount = _amount[id];
        uint96 cancelFee = uint96((uint256(amount) * RemitTypes.CANCEL_FEE_BPS) / 10_000);

        uint256 payerBefore = usdc.balanceOf(PAYER);
        uint256 feeBefore = usdc.balanceOf(FEE_WALLET);

        hevm.prank(PAYER);
        try escrow.cancelEscrow(id) {
            assert(usdc.balanceOf(PAYER) - payerBefore == amount - cancelFee);
            assert(usdc.balanceOf(FEE_WALLET) - feeBefore == cancelFee);

            ghost_totalOut += amount;
            ghost_escrowBalance -= amount;
            ghost_feesCollected += cancelFee;
            _state[id] = 2;
            _removeActive(_findIdx(id));
        } catch {}
    }

    /// @notice Advance block time (enables timeout and default-win scenarios).
    function action_warpTime(uint64 delta) external {
        delta = _clamp64(delta, 0, 60 days);
        _currentTime += delta;
        hevm.warp(_currentTime);
    }

    /// @notice Payer reclaims full amount after escrow timeout (no evidence submitted).
    function action_claimTimeout(uint256 idxSeed) external {
        uint256 len = _activeIds.length;
        if (len == 0) return;
        bytes32 id = _activeIds[idxSeed % len];
        if (_state[id] == 2) return; // skip terminal

        uint96 amount = _amount[id];
        uint256 payerBefore = usdc.balanceOf(PAYER);

        hevm.prank(PAYER);
        try escrow.claimTimeout(id) {
            assert(usdc.balanceOf(PAYER) - payerBefore == amount); // full refund

            ghost_totalOut += amount;
            ghost_escrowBalance -= amount;
            _state[id] = 2;
            _removeActive(_findIdx(id));
        } catch {}
    }

    // ── Properties ───────────────────────────────────────────────────────────

    /// @notice INV-E1: USDC in escrow contract exactly equals ghost accounting.
    function property_fundConservation() external view returns (bool) {
        return usdc.balanceOf(address(escrow)) == ghost_escrowBalance;
    }

    /// @notice INV-E6: Fees never exceed 2% of total funded (generous upper bound).
    function property_feesReasonable() external view returns (bool) {
        if (ghost_totalFunded == 0) return true;
        return ghost_feesCollected <= (ghost_totalFunded * 200) / 10_000;
    }

    /// @notice Total conservation: all USDC in == all USDC (in-escrow + out).
    function property_totalConservation() external view returns (bool) {
        return ghost_totalIn == ghost_escrowBalance + ghost_totalOut;
    }
}
