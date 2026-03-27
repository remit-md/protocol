// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockUSDC} from "../../src/test/MockUSDC.sol";
import {MockFeeCalculator} from "../helpers/MockFeeCalculator.sol";
import {RemitEscrow} from "../../src/RemitEscrow.sol";
import {RemitTab} from "../../src/RemitTab.sol";
import {RemitTypes} from "../../src/libraries/RemitTypes.sol";

// =============================================================================
// CrossContractStateful - Medusa stateful fuzz (Campaign 2.4)
//
// Exercises Escrow + Tab simultaneously with SHARED USDC and fee calculator.
// Key cross-contract invariant: neither contract can steal from the other.
//
// Sequences tested:
//   Interleaved Escrow and Tab operations - random ordering
//
// Invariants under test:
//   INV-CC1: usdc.balanceOf(escrow) == ghost_escrowBalance  (no escrow leakage)
//   INV-CC2: usdc.balanceOf(tab)    == ghost_tabBalance     (no tab leakage)
//   INV-CC3: Escrow actions don't affect Tab balance (and vice versa)
//   INV-CC4: Total fees are reasonable across both contracts
//
// Medusa: calls action_* in random order; checks property_* after each call.
// Run: scripts/run_medusa.ps1 -ConfigFile medusa-cross.json
// =============================================================================

interface IHevm {
    function prank(address sender) external;
    function warp(uint256 timestamp) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 privateKey) external returns (address);
}

contract CrossContractStateful {
    IHevm internal constant hevm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    RemitEscrow internal escrow;
    RemitTab internal tab;

    address internal constant PAYER = address(0x10000);
    address internal constant PAYEE = address(0x20000);
    address internal constant ADMIN = address(0xAD00);
    address internal constant FEE_WALLET = address(0xFEE00);

    // Provider key for Tab charge signatures
    uint256 internal constant PROVIDER_KEY = 0x1234567890123456789012345678901234567890123456789012345678901234;
    address internal immutable PROVIDER;

    bytes32 internal constant TAB_CHARGE_TYPEHASH =
        keccak256("TabCharge(bytes32 tabId,uint96 totalCharged,uint32 callCount)");

    // ── Ghost accounting - independent per contract ───────────────────────────

    uint256 internal ghost_escrowBalance;
    uint256 internal ghost_tabBalance;
    uint256 internal ghost_feesCollected;
    uint256 internal ghost_totalFunded;

    // ── Escrow tracking ──────────────────────────────────────────────────────

    bytes32[] internal _activeEscrows;
    mapping(bytes32 => uint96) internal _escrowAmount;
    // 0=Funded, 1=Active, 2=terminal
    mapping(bytes32 => uint8) internal _escrowState;

    // ── Tab tracking ──────────────────────────────────────────────────────────

    bytes32[] internal _openTabs;
    mapping(bytes32 => uint96) internal _tabLimit;
    mapping(bytes32 => uint64) internal _tabExpiry;
    // 0=Open, 1=Closed
    mapping(bytes32 => uint8) internal _tabState;

    uint256 internal _idCounter;
    uint64 internal _currentTime;

    RemitTypes.Milestone[] internal _noMilestones;
    RemitTypes.Split[] internal _noSplits;

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor() {
        PROVIDER = hevm.addr(PROVIDER_KEY);
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();

        // Both contracts share the same USDC token and fee calculator
        escrow = new RemitEscrow(address(usdc), address(feeCalc), ADMIN, FEE_WALLET, address(0));
        tab = new RemitTab(address(usdc), address(feeCalc), FEE_WALLET, ADMIN, address(0));

        _currentTime = uint64(block.timestamp);

        usdc.mint(PAYER, 100_000_000e6);
        usdc.mint(PAYEE, 10_000_000e6);

        hevm.prank(PAYER);
        usdc.approve(address(escrow), type(uint256).max);
        hevm.prank(PAYER);
        usdc.approve(address(tab), type(uint256).max);
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

    function _signTabCharge(bytes32 tabId, uint96 totalCharged, uint32 callCount) internal returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(TAB_CHARGE_TYPEHASH, tabId, totalCharged, callCount));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tab.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = hevm.sign(PROVIDER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _removeEscrow(uint256 idx) internal {
        uint256 last = _activeEscrows.length - 1;
        if (idx != last) _activeEscrows[idx] = _activeEscrows[last];
        _activeEscrows.pop();
    }

    function _findEscrowIdx(bytes32 id) internal view returns (uint256) {
        for (uint256 i = 0; i < _activeEscrows.length; i++) {
            if (_activeEscrows[i] == id) return i;
        }
        return type(uint256).max;
    }

    function _removeTab(uint256 idx) internal {
        uint256 last = _openTabs.length - 1;
        if (idx != last) _openTabs[idx] = _openTabs[last];
        _openTabs.pop();
    }

    function _findTabIdx(bytes32 id) internal view returns (uint256) {
        for (uint256 i = 0; i < _openTabs.length; i++) {
            if (_openTabs[i] == id) return i;
        }
        return type(uint256).max;
    }

    // ── Escrow Actions ───────────────────────────────────────────────────────

    /// @notice Payer creates an escrow.
    function action_createEscrow(uint96 amount, uint64 timeoutDelta) external {
        amount = _clamp(amount, RemitTypes.MIN_AMOUNT, 1_000e6);
        uint64 timeout = _currentTime + _clamp64(timeoutDelta, 4 days, 30 days);
        bytes32 id = keccak256(abi.encode("escrow", _idCounter++, address(this)));

        uint256 payerBefore = usdc.balanceOf(PAYER);
        hevm.prank(PAYER);
        try escrow.createEscrow(id, PAYEE, amount, timeout, _noMilestones, _noSplits) {
            assert(payerBefore - usdc.balanceOf(PAYER) == amount);

            ghost_escrowBalance += amount;
            ghost_totalFunded += amount;
            _activeEscrows.push(id);
            _escrowAmount[id] = amount;
            _escrowState[id] = 0;
        } catch {}
    }

    /// @notice Payee starts claim (Funded → Active).
    function action_escrow_claimStart(uint256 idxSeed) external {
        uint256 len = _activeEscrows.length;
        if (len == 0) return;
        bytes32 id = _activeEscrows[idxSeed % len];
        if (_escrowState[id] != 0) return;

        hevm.prank(PAYEE);
        try escrow.claimStart(id) {
            _escrowState[id] = 1;
        } catch {}
    }

    /// @notice Payer releases escrow (Active → Completed).
    function action_escrow_release(uint256 idxSeed) external {
        uint256 len = _activeEscrows.length;
        if (len == 0) return;
        bytes32 id = _activeEscrows[idxSeed % len];
        if (_escrowState[id] != 1) return;

        uint96 amount = _escrowAmount[id];
        uint96 fee = uint96((uint256(amount) * RemitTypes.FEE_RATE_BPS) / 10_000);

        uint256 payeeBefore = usdc.balanceOf(PAYEE);
        uint256 feeBefore = usdc.balanceOf(FEE_WALLET);

        hevm.prank(PAYER);
        try escrow.releaseEscrow(id) {
            assert(usdc.balanceOf(PAYEE) - payeeBefore + usdc.balanceOf(FEE_WALLET) - feeBefore == amount);

            ghost_escrowBalance -= amount;
            ghost_feesCollected += fee;
            _escrowState[id] = 2;
            _removeEscrow(_findEscrowIdx(id));
        } catch {}
    }

    /// @notice Payer cancels escrow before claimStart (Funded → Cancelled).
    function action_escrow_cancel(uint256 idxSeed) external {
        uint256 len = _activeEscrows.length;
        if (len == 0) return;
        bytes32 id = _activeEscrows[idxSeed % len];
        if (_escrowState[id] != 0) return;

        uint96 amount = _escrowAmount[id];
        uint96 cancelFee = uint96((uint256(amount) * RemitTypes.CANCEL_FEE_BPS) / 10_000);

        hevm.prank(PAYER);
        try escrow.cancelEscrow(id) {
            ghost_escrowBalance -= amount;
            ghost_feesCollected += cancelFee;
            _escrowState[id] = 2;
            _removeEscrow(_findEscrowIdx(id));
        } catch {}
    }

    // ── Tab Actions ──────────────────────────────────────────────────────────

    /// @notice Payer opens a tab.
    function action_openTab(uint96 limit, uint64 expiryDelta) external {
        limit = _clamp(limit, RemitTypes.MIN_AMOUNT, 1_000e6);
        uint64 expiry = _currentTime + _clamp64(expiryDelta, 4 days, 30 days);
        bytes32 id = keccak256(abi.encode("tab", _idCounter++, address(this)));

        uint256 payerBefore = usdc.balanceOf(PAYER);
        hevm.prank(PAYER);
        try tab.openTab(id, PROVIDER, limit, uint64(RemitTypes.MIN_AMOUNT), expiry) {
            assert(payerBefore - usdc.balanceOf(PAYER) == limit);

            ghost_tabBalance += limit;
            ghost_totalFunded += limit;
            _openTabs.push(id);
            _tabLimit[id] = limit;
            _tabExpiry[id] = expiry;
            _tabState[id] = 0;
        } catch {}
    }

    /// @notice Payer closes a tab with provider-signed charges.
    function action_closeTab(uint256 idxSeed, uint96 chargedSeed, uint32 callCount) external {
        uint256 len = _openTabs.length;
        if (len == 0) return;
        bytes32 id = _openTabs[idxSeed % len];
        if (_tabState[id] != 0) return;

        uint96 limit = _tabLimit[id];
        uint96 totalCharged = _clamp(chargedSeed, 0, limit);

        bytes memory sig = _signTabCharge(id, totalCharged, callCount);

        uint96 fee = uint96((uint256(totalCharged) * RemitTypes.FEE_RATE_BPS) / 10_000);

        hevm.prank(PAYER);
        try tab.closeTab(id, totalCharged, callCount, sig) {
            ghost_tabBalance -= limit;
            ghost_feesCollected += fee;
            _tabState[id] = 1;
            _removeTab(_findTabIdx(id));
        } catch {}
    }

    // ── Shared Actions ───────────────────────────────────────────────────────

    /// @notice Advance block time.
    function action_warpTime(uint64 delta) external {
        delta = _clamp64(delta, 0, 60 days);
        _currentTime += delta;
        hevm.warp(_currentTime);
    }

    // ── Properties ───────────────────────────────────────────────────────────

    /// @notice INV-CC1: Escrow contract balance equals ghost accounting.
    function property_escrowConservation() external view returns (bool) {
        return usdc.balanceOf(address(escrow)) == ghost_escrowBalance;
    }

    /// @notice INV-CC2: Tab contract balance equals ghost accounting.
    function property_tabConservation() external view returns (bool) {
        return usdc.balanceOf(address(tab)) == ghost_tabBalance;
    }

    /// @notice INV-CC3: Neither contract holds the other's funds.
    ///         Each contract's balance is exactly what ghost accounting expects.
    ///         (property_escrowConservation + property_tabConservation together prove this.)
    function property_noContractInterference() external view returns (bool) {
        return
            usdc.balanceOf(address(escrow)) == ghost_escrowBalance && usdc.balanceOf(address(tab)) == ghost_tabBalance;
    }

    /// @notice INV-CC4: Total fees across both contracts ≤ 2% of all funded amounts.
    function property_feesReasonable() external view returns (bool) {
        if (ghost_totalFunded == 0) return true;
        return ghost_feesCollected <= (ghost_totalFunded * 200) / 10_000;
    }
}
