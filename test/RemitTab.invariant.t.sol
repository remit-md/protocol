// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {MockFeeCalculator} from "./helpers/MockFeeCalculator.sol";
import {RemitTab} from "../src/RemitTab.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";

// =============================================================================
// TabHandler
//
// Ghost accounting for RemitTab.
//
// Ghost invariant (INV-T1 / INV-T2):
//   usdc.balanceOf(tab) == ghost_locked
//   where ghost_locked = sum of funds still held in tab contract
//
// On openTab:         ghost_locked += limit
// On closeTab:        ghost_locked -= limit  (all: providerPayout + fee + refund = limit)
// =============================================================================

contract TabHandler is Test {
    RemitTab public tab;
    MockUSDC public usdc;
    MockFeeCalculator public feeCalc;

    address public feeRecipient;
    address public admin;
    address public payer;

    // Provider has a known signing key so we can generate EIP-712 provider sigs.
    uint256 internal providerKey = uint256(keccak256("inv-tab-provider-key"));
    address public provider;

    uint256 public ghost_locked;

    // Open tabs
    bytes32[] internal _openIds;

    mapping(bytes32 => uint96) internal _limit;
    mapping(bytes32 => uint64) internal _expiry;

    uint256 internal _idCounter;
    uint32 internal _callCountSeed;

    constructor(RemitTab _tab, MockUSDC _usdc, MockFeeCalculator _feeCalc, address _feeRecipient, address _admin) {
        tab = _tab;
        usdc = _usdc;
        feeCalc = _feeCalc;
        feeRecipient = _feeRecipient;
        admin = _admin;
        payer = makeAddr("inv-tab-payer");
        provider = vm.addr(providerKey);

        usdc.mint(payer, 10_000_000e6);
        vm.prank(payer);
        usdc.approve(address(tab), type(uint256).max);
    }

    // ── openTab ──────────────────────────────────────────────────────────────

    function openTab(uint96 limit, uint64 expiryDelta) external {
        limit = uint96(bound(limit, RemitTypes.MIN_AMOUNT, 10_000e6));
        expiryDelta = uint64(bound(expiryDelta, 1 hours, 30 days));

        bytes32 id = keccak256(abi.encodePacked("inv-tab", _idCounter++));
        uint64 exp = uint64(block.timestamp + expiryDelta);

        usdc.mint(payer, limit);

        vm.prank(payer);
        tab.openTab(
            id,
            provider,
            limit,
            1e6,
            /* $1 per unit */
            exp
        );

        _openIds.push(id);
        _limit[id] = limit;
        _expiry[id] = exp;
        ghost_locked += limit;
    }

    // ── closeTab ─────────────────────────────────────────────────────────────

    /// @dev Close a tab with a valid provider signature. Total charged ∈ [0, limit].
    function closeTab(uint256 idx, uint96 charged) external {
        if (_openIds.length == 0) return;
        idx = bound(idx, 0, _openIds.length - 1);
        bytes32 id = _openIds[idx];

        uint96 limit = _limit[id];
        charged = uint96(bound(charged, 0, limit));
        uint32 callCount = _callCountSeed++;

        bytes memory sig = _providerSig(id, charged, callCount);

        vm.prank(payer);
        tab.closeTab(id, charged, callCount, sig);

        // All limit funds leave contract (provider + refund + fee = limit).
        ghost_locked -= limit;
        _removeOpen(idx);
    }

    // ── closeExpiredTab ───────────────────────────────────────────────────────

    /// @dev Close an expired tab. Warps past expiry.
    function closeExpiredTab(uint256 idx, uint96 charged) external {
        if (_openIds.length == 0) return;
        idx = bound(idx, 0, _openIds.length - 1);
        bytes32 id = _openIds[idx];

        uint96 limit = _limit[id];
        charged = uint96(bound(charged, 0, limit));
        uint32 callCount = _callCountSeed++;

        vm.warp(_expiry[id] + 1);

        bytes memory sig;
        if (charged > 0) {
            sig = _providerSig(id, charged, callCount);
        }

        vm.prank(payer);
        tab.closeExpiredTab(id, charged, callCount, sig);

        ghost_locked -= limit;
        _removeOpen(idx);
    }



    // ── Helpers ──────────────────────────────────────────────────────────────

    function openCount() external view returns (uint256) {
        return _openIds.length;
    }

    /// @dev Generate a valid provider EIP-712 signature for a charge attestation.
    function _providerSig(bytes32 tabId, uint96 totalCharged, uint32 callCount) internal view returns (bytes memory) {
        bytes32 domainSep = tab.domainSeparator();
        bytes32 structHash = keccak256(abi.encode(tab.TAB_CHARGE_TYPEHASH(), tabId, totalCharged, callCount));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(providerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _removeOpen(uint256 idx) internal {
        uint256 last = _openIds.length - 1;
        if (idx != last) _openIds[idx] = _openIds[last];
        _openIds.pop();
    }

}

// =============================================================================
// TabInvariantTest
// =============================================================================

contract TabInvariantTest is Test {
    TabHandler internal handler;
    RemitTab internal tabContract;
    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    address internal feeRecipient = makeAddr("inv-tab-fee-recipient");
    address internal admin = makeAddr("inv-tab-admin");

    function setUp() public {
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        tabContract = new RemitTab(address(usdc), address(feeCalc), feeRecipient, admin, address(0));
        handler = new TabHandler(tabContract, usdc, feeCalc, feeRecipient, admin);
        targetContract(address(handler));
    }

    /// @notice INV-T1/T2: Contract balance always equals ghost_locked.
    ///         Validates that providerPayout + fee + refund = limit on every close.
    function invariant_conservationOfFunds() public view {
        assertEq(
            usdc.balanceOf(address(tabContract)),
            handler.ghost_locked(),
            "tab: balance != ghost_locked (fund conservation violated)"
        );
    }

    /// @notice INV-T1: Balance is non-negative (trivially true but explicit).
    function invariant_balanceNonNegative() public view {
        assertGe(usdc.balanceOf(address(tabContract)), 0, "tab: balance < 0 (impossible, sanity check)");
    }
}
