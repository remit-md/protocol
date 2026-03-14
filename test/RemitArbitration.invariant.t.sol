// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {RemitArbitration} from "../src/RemitArbitration.sol";

// =============================================================================
// ArbitrationHandler
//
// Ghost accounting for RemitArbitration (arbitrator bond pool).
//
// Ghost invariant (INV-A1):
//   usdc.balanceOf(arbitration) == ghost_bonds
//   where ghost_bonds = sum of active bond amounts for all registered arbitrators
//
// On registerArbitrator:   ghost_bonds += MIN_ARBITRATOR_BOND
// On claimArbitratorBond:  ghost_bonds -= MIN_ARBITRATOR_BOND (bond not slashed in this scenario)
// On removeArbitrator:     ghost_bonds unchanged (bond stays until claimed)
//
// Additional invariant (INV-A2):
//   For all addr in pool: _arbitrators[addr].active == true
//   (checked via getArbitrator + getPoolSize)
// =============================================================================

contract ArbitrationHandler is Test {
    RemitArbitration public arb;
    MockUSDC public usdc;

    uint256 public constant MAX_ARBITRATORS = 10;
    uint256 public constant BOND = 100_000_000; // MIN_ARBITRATOR_BOND

    // Ghost accounting
    uint256 public ghost_bonds;

    // Active arbitrators (wallet → registered)
    address[] internal _activeArbs;
    address[] internal _removedArbs; // removed but bond not yet claimed
    mapping(address => bool) internal _isActive;
    mapping(address => bool) internal _isRemoved;
    mapping(address => uint64) internal _removedAt;

    uint256 internal _arbCounter;

    constructor(RemitArbitration _arb, MockUSDC _usdc) {
        arb = _arb;
        usdc = _usdc;
    }

    // ── registerArbitrator ───────────────────────────────────────────────────

    /// @dev Registers a fresh arbitrator wallet. Mints and bonds 100 USDC.
    function registerArbitrator() external {
        // Limit pool size to keep test manageable.
        if (_activeArbs.length >= MAX_ARBITRATORS) return;

        address wallet = vm.addr(uint256(keccak256(abi.encodePacked("inv-arb", _arbCounter++))));
        if (_isActive[wallet] || _isRemoved[wallet]) return; // already used

        usdc.mint(wallet, BOND);
        vm.prank(wallet);
        usdc.approve(address(arb), BOND);

        vm.prank(wallet);
        arb.registerArbitrator("ipfs://test");

        _activeArbs.push(wallet);
        _isActive[wallet] = true;
        ghost_bonds += BOND;
    }

    // ── removeArbitrator ─────────────────────────────────────────────────────

    /// @dev An active arbitrator voluntarily removes themselves.
    ///      Bond stays in contract — ghost_bonds unchanged.
    function removeArbitrator(uint256 idx) external {
        if (_activeArbs.length == 0) return;
        idx = bound(idx, 0, _activeArbs.length - 1);
        address wallet = _activeArbs[idx];

        vm.prank(wallet);
        arb.removeArbitrator();

        _removedArbs.push(wallet);
        _removedAt[wallet] = uint64(block.timestamp);
        _isActive[wallet] = false;
        _isRemoved[wallet] = true;
        _removeActiveAt(idx);
        // ghost_bonds unchanged — bond still in contract
    }

    // ── claimArbitratorBond ──────────────────────────────────────────────────

    /// @dev Removed arbitrator claims bond after cooldown.
    function claimArbitratorBond(uint256 idx) external {
        if (_removedArbs.length == 0) return;
        idx = bound(idx, 0, _removedArbs.length - 1);
        address wallet = _removedArbs[idx];

        // Warp past the 7-day cooldown.
        uint64 cooldown = arb.ARBITRATOR_BOND_COOLDOWN();
        vm.warp(_removedAt[wallet] + cooldown + 1);

        vm.prank(wallet);
        arb.claimArbitratorBond();

        ghost_bonds -= BOND;
        _isRemoved[wallet] = false;
        _removeRemovedAt(idx);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function activeCount() external view returns (uint256) {
        return _activeArbs.length;
    }

    function removedCount() external view returns (uint256) {
        return _removedArbs.length;
    }

    function _removeActiveAt(uint256 idx) internal {
        uint256 last = _activeArbs.length - 1;
        if (idx != last) _activeArbs[idx] = _activeArbs[last];
        _activeArbs.pop();
    }

    function _removeRemovedAt(uint256 idx) internal {
        uint256 last = _removedArbs.length - 1;
        if (idx != last) _removedArbs[idx] = _removedArbs[last];
        _removedArbs.pop();
    }
}

// =============================================================================
// ArbitrationInvariantTest
// =============================================================================

contract ArbitrationInvariantTest is Test {
    ArbitrationHandler internal handler;
    RemitArbitration internal arbContract;
    MockUSDC internal usdc;
    address internal owner = makeAddr("inv-arb-owner");

    function setUp() public {
        usdc = new MockUSDC();
        arbContract = new RemitArbitration(address(usdc), owner);
        handler = new ArbitrationHandler(arbContract, usdc);
        targetContract(address(handler));
    }

    /// @notice INV-A1: Contract USDC balance always equals the sum of all
    ///         outstanding arbitrator bonds tracked by ghost accounting.
    function invariant_bondConservation() public view {
        assertEq(
            usdc.balanceOf(address(arbContract)),
            handler.ghost_bonds(),
            "arbitration: balance != ghost_bonds (bond conservation violated)"
        );
    }

    /// @notice INV-A2: Pool size reported by contract never exceeds registered active count.
    ///         Checks that removeArbitrator + swap-and-pop keeps pool consistent.
    function invariant_poolSizeLteActiveCount() public view {
        assertLe(
            arbContract.getPoolSize(),
            handler.activeCount(),
            "arbitration: pool size > handler active count (pool inconsistency)"
        );
    }

    /// @notice INV-A2b: Pool size equals handler active count (strict consistency).
    function invariant_poolSizeEqualsActiveCount() public view {
        assertEq(arbContract.getPoolSize(), handler.activeCount(), "arbitration: pool size != handler active count");
    }
}
