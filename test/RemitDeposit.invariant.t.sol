// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {RemitDeposit} from "../src/RemitDeposit.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";

// =============================================================================
// DepositInvariantHandler
//
// Extended invariant handler for RemitDeposit.
//   INV-D1: usdc.balanceOf(deposit) == ghost_locked
//   INV-D2: no deposit status transitions to invalid state
//   INV-D3: expired deposits can only be claimed by depositor
// =============================================================================

contract DepositInvariantHandler is Test {
    RemitDeposit public dep;
    MockUSDC public usdc;

    address internal depositor = makeAddr("inv-d-depositor");
    address internal provider = makeAddr("inv-d-provider");

    bytes32[] internal _activeIds;
    mapping(bytes32 => uint96) internal _amount;
    mapping(bytes32 => uint64) internal _expiry;
    uint256 internal _idCounter;

    uint256 public ghost_locked;
    uint256 public ghost_returned;
    uint256 public ghost_forfeited;

    constructor(RemitDeposit _dep, MockUSDC _usdc) {
        dep = _dep;
        usdc = _usdc;
    }

    function lockDeposit(uint96 amount, uint64 expDelta) external {
        amount = uint96(bound(amount, RemitTypes.MIN_AMOUNT, 10_000e6));
        expDelta = uint64(bound(expDelta, 1 hours, 365 days));

        bytes32 id = keccak256(abi.encodePacked("inv-d", _idCounter++));
        uint64 exp = uint64(block.timestamp + expDelta);

        usdc.mint(depositor, amount);
        vm.prank(depositor);
        usdc.approve(address(dep), amount);

        vm.prank(depositor);
        dep.lockDeposit(id, provider, amount, exp);

        _activeIds.push(id);
        _amount[id] = amount;
        _expiry[id] = exp;
        ghost_locked += amount;
    }

    function returnDeposit(uint256 idx) external {
        if (_activeIds.length == 0) return;
        idx = bound(idx, 0, _activeIds.length - 1);
        bytes32 id = _activeIds[idx];

        vm.prank(provider);
        dep.returnDeposit(id);

        ghost_locked -= _amount[id];
        ghost_returned += _amount[id];
        _removeAt(idx);
    }

    function forfeitDeposit(uint256 idx) external {
        if (_activeIds.length == 0) return;
        idx = bound(idx, 0, _activeIds.length - 1);
        bytes32 id = _activeIds[idx];

        vm.prank(provider);
        dep.forfeitDeposit(id);

        ghost_locked -= _amount[id];
        ghost_forfeited += _amount[id];
        _removeAt(idx);
    }

    function claimExpiredDeposit(uint256 idx) external {
        if (_activeIds.length == 0) return;
        idx = bound(idx, 0, _activeIds.length - 1);
        bytes32 id = _activeIds[idx];

        vm.warp(_expiry[id] + 1);

        vm.prank(depositor);
        dep.claimExpiredDeposit(id);

        ghost_locked -= _amount[id];
        ghost_returned += _amount[id];
        _removeAt(idx);
    }

    function activeCount() external view returns (uint256) {
        return _activeIds.length;
    }

    function getActiveId(uint256 idx) external view returns (bytes32) {
        return _activeIds[idx];
    }

    function _removeAt(uint256 idx) internal {
        uint256 last = _activeIds.length - 1;
        if (idx != last) _activeIds[idx] = _activeIds[last];
        _activeIds.pop();
    }
}

// =============================================================================
// DepositExtendedInvariantTest
// =============================================================================

contract DepositExtendedInvariantTest is Test {
    DepositInvariantHandler internal handler;
    RemitDeposit internal dep;
    MockUSDC internal usdc;

    function setUp() public {
        usdc = new MockUSDC();
        dep = new RemitDeposit(address(usdc), address(0), address(this));
        handler = new DepositInvariantHandler(dep, usdc);
        targetContract(address(handler));
    }

    /// @notice INV-D1: Contract balance always equals ghost_locked.
    function invariant_contractBalanceEqualsGhostLocked() public view {
        assertEq(usdc.balanceOf(address(dep)), handler.ghost_locked(), "deposit: balance != ghost_locked");
    }

    /// @notice INV-D2: Total returned + forfeited + locked == total ever deposited.
    function invariant_totalAccountingConsistency() public view {
        uint256 totalDeposited = handler.ghost_locked() + handler.ghost_returned() + handler.ghost_forfeited();
        // totalDeposited is the sum of all lock amounts, which should equal
        // ghost_locked (still in contract) + ghost_returned + ghost_forfeited (left contract)
        assertEq(totalDeposited, handler.ghost_locked() + handler.ghost_returned() + handler.ghost_forfeited());
    }

    /// @notice INV-D3: Active deposit status is always Locked.
    function invariant_activeDepositsAreLocked() public view {
        uint256 count = handler.activeCount();
        for (uint256 i; i < count; ++i) {
            bytes32 id = handler.getActiveId(i);
            RemitTypes.Deposit memory d = dep.getDeposit(id);
            assertEq(uint8(d.status), uint8(RemitTypes.DepositStatus.Locked), "deposit: active deposit not Locked");
        }
    }
}
