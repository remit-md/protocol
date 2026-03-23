// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockUSDC} from "../../src/test/MockUSDC.sol";
import {MockFeeCalculator} from "../helpers/MockFeeCalculator.sol";
import {RemitTab} from "../../src/RemitTab.sol";
import {RemitTypes} from "../../src/libraries/RemitTypes.sol";

// =============================================================================
// TabStateful — Medusa stateful fuzz campaign for RemitTab (Campaign 2.3)
//
// Tests multi-step sequences:
//   openTab → closeTab (with charges)
//   openTab → closeTab (zero charges — full refund)
//   openTab → closeExpiredTab (after expiry, no sig needed for zero charges)
//
// Invariants under test (from INVARIANTS.md):
//   INV-T1: usdc.balanceOf(tab) == ghost_tabBalance at ALL times
//   INV-T2: On close, providerPayout + fee + refund == limit exactly
//   INV-T6: Total fees <= sum(limits) * MAX_FEE_BPS / 10_000
//
// Provider signs cumulative charge states off-chain. We use hevm.sign with a
// deterministic key so Medusa can generate valid EIP-712 provider signatures.
//
// Medusa: calls action_* in random order; checks property_* after each call.
// Run: scripts/run_medusa.ps1 -ConfigFile medusa-tab.json
// =============================================================================

interface IHevm {
    function prank(address sender) external;
    function warp(uint256 timestamp) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 privateKey) external returns (address);
}

contract TabStateful {
    IHevm internal constant hevm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    RemitTab internal tab;

    address internal constant PAYER = address(0x10000);
    address internal constant ADMIN = address(0xAD00);
    address internal constant FEE_WALLET = address(0xFEE00);

    // Deterministic provider key — used to sign TabCharge attestations.
    // Any non-zero value well below secp256k1 order is valid.
    uint256 internal constant PROVIDER_KEY = 0x1234567890123456789012345678901234567890123456789012345678901234;
    address internal immutable PROVIDER;

    // EIP-712 typehash (must match RemitTab.TAB_CHARGE_TYPEHASH)
    bytes32 internal constant TAB_CHARGE_TYPEHASH =
        keccak256("TabCharge(bytes32 tabId,uint96 totalCharged,uint32 callCount)");

    // ── Ghost accounting ─────────────────────────────────────────────────────

    // All USDC locked into the tab contract (limits)
    uint256 internal ghost_totalIn;
    // All USDC released from the tab contract (payouts + refunds)
    uint256 internal ghost_totalOut;
    // Net balance: ghost_totalIn - ghost_totalOut; must equal usdc.balanceOf(tab)
    uint256 internal ghost_tabBalance;
    // Total fees collected (for INV-T6 upper-bound check)
    uint256 internal ghost_feesCollected;
    // Total limits locked (denominator for fee rate check)
    uint256 internal ghost_totalFunded;

    // ── Tab tracking ──────────────────────────────────────────────────────────

    bytes32[] internal _openTabIds;

    mapping(bytes32 => uint96) internal _limit;
    mapping(bytes32 => uint64) internal _expiry;
    // 0=Open, 1=Closed
    mapping(bytes32 => uint8) internal _state;

    uint256 internal _idCounter;
    uint64 internal _currentTime;

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor() {
        PROVIDER = hevm.addr(PROVIDER_KEY);
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        tab = new RemitTab(address(usdc), address(feeCalc), FEE_WALLET, ADMIN, address(0));

        _currentTime = uint64(block.timestamp);

        // Pre-fund payer (provider only receives, never sends in this harness)
        usdc.mint(PAYER, 100_000_000e6);
        hevm.prank(PAYER);
        usdc.approve(address(tab), type(uint256).max);
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

    /// @dev Sign a TabCharge struct as the provider. Used by action_closeTab.
    function _signTabCharge(bytes32 tabId, uint96 totalCharged, uint32 callCount) internal returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(TAB_CHARGE_TYPEHASH, tabId, totalCharged, callCount));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tab.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = hevm.sign(PROVIDER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _removeOpen(uint256 idx) internal {
        uint256 last = _openTabIds.length - 1;
        if (idx != last) _openTabIds[idx] = _openTabIds[last];
        _openTabIds.pop();
    }

    function _findOpenIdx(bytes32 id) internal view returns (uint256) {
        for (uint256 i = 0; i < _openTabIds.length; i++) {
            if (_openTabIds[i] == id) return i;
        }
        return type(uint256).max;
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    /// @notice Payer opens a tab, locking USDC in the contract.
    function action_openTab(uint96 limit, uint64 expiryDelta) external {
        limit = _clamp(limit, RemitTypes.MIN_AMOUNT, 1_000e6);
        uint64 expiry = _currentTime + _clamp64(expiryDelta, 4 days, 30 days);
        bytes32 id = keccak256(abi.encode("tab", _idCounter++, address(this)));

        uint256 payerBefore = usdc.balanceOf(PAYER);
        hevm.prank(PAYER);
        try tab.openTab(id, PROVIDER, limit, uint64(RemitTypes.MIN_AMOUNT), expiry) {
            assert(payerBefore - usdc.balanceOf(PAYER) == limit); // exact lock

            ghost_totalIn += limit;
            ghost_tabBalance += limit;
            ghost_totalFunded += limit;
            _openTabIds.push(id);
            _limit[id] = limit;
            _expiry[id] = expiry;
            _state[id] = 0;
        } catch {}
    }

    /// @notice Payer closes a tab with provider-signed cumulative charges.
    ///         totalCharged in [0, limit]. Zero charges → full refund to payer.
    function action_closeTab(uint256 idxSeed, uint96 chargedSeed, uint32 callCount) external {
        uint256 len = _openTabIds.length;
        if (len == 0) return;
        bytes32 id = _openTabIds[idxSeed % len];
        if (_state[id] != 0) return;

        uint96 limit = _limit[id];
        uint96 totalCharged = _clamp(chargedSeed, 0, limit);

        bytes memory sig = _signTabCharge(id, totalCharged, callCount);

        uint256 providerBefore = usdc.balanceOf(PROVIDER);
        uint256 payerBefore = usdc.balanceOf(PAYER);
        uint256 feeBefore = usdc.balanceOf(FEE_WALLET);

        hevm.prank(PAYER);
        try tab.closeTab(id, totalCharged, callCount, sig) {
            uint256 providerOut = usdc.balanceOf(PROVIDER) - providerBefore;
            uint256 fee = usdc.balanceOf(FEE_WALLET) - feeBefore;
            uint256 refund = usdc.balanceOf(PAYER) - payerBefore;

            assert(providerOut + fee + refund == limit); // INV-T2: conservation on close

            uint96 expectedFee = uint96((uint256(totalCharged) * RemitTypes.FEE_RATE_BPS) / 10_000);
            assert(fee == expectedFee); // fee formula exact

            ghost_totalOut += limit;
            ghost_tabBalance -= limit;
            ghost_feesCollected += fee;
            _state[id] = 1;
            _removeOpen(_findOpenIdx(id));
        } catch {}
    }

    /// @notice Payer force-closes an expired tab with zero charges (no sig required).
    ///         Full limit is refunded.
    function action_closeExpiredTab(uint256 idxSeed) external {
        uint256 len = _openTabIds.length;
        if (len == 0) return;
        bytes32 id = _openTabIds[idxSeed % len];
        if (_state[id] != 0) return;
        if (_currentTime <= _expiry[id]) return; // must be past expiry

        uint96 limit = _limit[id];
        uint256 payerBefore = usdc.balanceOf(PAYER);

        hevm.prank(PAYER);
        try tab.closeExpiredTab(id, 0, 0, "") {
            assert(usdc.balanceOf(PAYER) - payerBefore == limit); // full refund

            ghost_totalOut += limit;
            ghost_tabBalance -= limit;
            _state[id] = 1;
            _removeOpen(_findOpenIdx(id));
        } catch {}
    }

    /// @notice Advance block time (enables expiry and degradation scenarios).
    function action_warpTime(uint64 delta) external {
        delta = _clamp64(delta, 0, 60 days);
        _currentTime += delta;
        hevm.warp(_currentTime);
    }

    // ── Properties ───────────────────────────────────────────────────────────

    /// @notice INV-T1: USDC in tab contract exactly equals ghost accounting.
    function property_fundConservation() external view returns (bool) {
        return usdc.balanceOf(address(tab)) == ghost_tabBalance;
    }

    /// @notice Total conservation: all USDC in == (in-tab + out).
    function property_totalConservation() external view returns (bool) {
        return ghost_totalIn == ghost_tabBalance + ghost_totalOut;
    }

    /// @notice INV-T6: Fees never exceed 2% of total locked (generous upper bound).
    function property_feesReasonable() external view returns (bool) {
        if (ghost_totalFunded == 0) return true;
        return ghost_feesCollected <= (ghost_totalFunded * 200) / 10_000;
    }
}
