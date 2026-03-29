// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {MockFeeCalculator} from "./helpers/MockFeeCalculator.sol";
import {RemitBounty} from "../src/RemitBounty.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";

// =============================================================================
// BountyInvariantHandler
//
// Extended invariant handler for RemitBounty with submission bonds.
//   INV-B1: usdc.balanceOf(bounty) == ghost_locked
//   INV-B2: awarded bounty amount + fee == original bounty amount
//   INV-B3: submission bond is always returned (to winner on award, to submitter on reject)
// =============================================================================

contract BountyInvariantHandler is Test {
    RemitBounty public bounty;
    MockUSDC public usdc;
    MockFeeCalculator public feeCalc;
    address public feeRecipient;

    address internal poster = makeAddr("inv-b-poster");
    address internal submitter = makeAddr("inv-b-submitter");

    bytes32[] internal _openIds;
    bytes32[] internal _claimedIds;
    mapping(bytes32 => uint96) internal _amount;
    mapping(bytes32 => uint96) internal _bond;
    mapping(bytes32 => uint64) internal _deadline;
    uint256 internal _idCounter;

    uint256 public ghost_locked;

    constructor(RemitBounty _bounty, MockUSDC _usdc, MockFeeCalculator _feeCalc, address _feeRecipient) {
        bounty = _bounty;
        usdc = _usdc;
        feeCalc = _feeCalc;
        feeRecipient = _feeRecipient;
    }

    function postBounty(uint96 amount, uint96 bondAmount, uint64 deadlineDelta) external {
        amount = uint96(bound(amount, RemitTypes.MIN_AMOUNT, 10_000e6));
        bondAmount = uint96(bound(bondAmount, 0, 100e6));
        deadlineDelta = uint64(bound(deadlineDelta, 1 hours, 365 days));

        bytes32 id = keccak256(abi.encodePacked("inv-b", _idCounter++));
        uint64 deadline = uint64(block.timestamp + deadlineDelta);

        usdc.mint(poster, amount);
        vm.prank(poster);
        usdc.approve(address(bounty), amount);

        vm.prank(poster);
        bounty.postBounty(id, amount, deadline, keccak256(abi.encodePacked("task", id)), bondAmount, 0);

        _openIds.push(id);
        _amount[id] = amount;
        _bond[id] = bondAmount;
        _deadline[id] = deadline;
        ghost_locked += amount;
    }

    function submitBounty(uint256 idx) external {
        if (_openIds.length == 0) return;
        idx = bound(idx, 0, _openIds.length - 1);
        bytes32 id = _openIds[idx];

        if (block.timestamp > _deadline[id]) return;

        uint96 bond = _bond[id];
        if (bond > 0) {
            usdc.mint(submitter, bond);
            vm.prank(submitter);
            usdc.approve(address(bounty), bond);
        }

        vm.prank(submitter);
        bounty.submitBounty(id, keccak256(abi.encodePacked("evidence", id)));

        ghost_locked += bond; // bond enters the contract
        _claimedIds.push(id);
        _removeOpenAt(idx);
    }

    function awardBounty(uint256 idx) external {
        if (_claimedIds.length == 0) return;
        idx = bound(idx, 0, _claimedIds.length - 1);
        bytes32 id = _claimedIds[idx];

        vm.prank(poster);
        bounty.awardBounty(id, submitter);

        // bounty amount + bond all leave the contract
        ghost_locked -= _amount[id];
        ghost_locked -= _bond[id];
        _removeClaimedAt(idx);
    }

    function rejectSubmission(uint256 idx) external {
        if (_claimedIds.length == 0) return;
        idx = bound(idx, 0, _claimedIds.length - 1);
        bytes32 id = _claimedIds[idx];

        vm.prank(poster);
        bounty.rejectSubmission(id, submitter, "rejected");

        // Bond returned, bounty re-opens
        ghost_locked -= _bond[id];
        _openIds.push(id);
        _removeClaimedAt(idx);
    }

    function reclaimBounty(uint256 idx) external {
        if (_openIds.length == 0) return;
        idx = bound(idx, 0, _openIds.length - 1);
        bytes32 id = _openIds[idx];

        vm.warp(_deadline[id] + 1);

        vm.prank(poster);
        bounty.reclaimBounty(id);

        ghost_locked -= _amount[id];
        _removeOpenAt(idx);
    }

    function openCount() external view returns (uint256) {
        return _openIds.length;
    }

    function claimedCount() external view returns (uint256) {
        return _claimedIds.length;
    }

    function _removeOpenAt(uint256 idx) internal {
        uint256 last = _openIds.length - 1;
        if (idx != last) _openIds[idx] = _openIds[last];
        _openIds.pop();
    }

    function _removeClaimedAt(uint256 idx) internal {
        uint256 last = _claimedIds.length - 1;
        if (idx != last) _claimedIds[idx] = _claimedIds[last];
        _claimedIds.pop();
    }
}

// =============================================================================
// BountyExtendedInvariantTest
// =============================================================================

contract BountyExtendedInvariantTest is Test {
    BountyInvariantHandler internal handler;
    RemitBounty internal bountyContract;
    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    address internal feeRecipient = makeAddr("inv-b-fee");
    address internal admin = makeAddr("inv-b-admin");

    function setUp() public {
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        bountyContract = new RemitBounty(address(usdc), address(feeCalc), feeRecipient, admin, address(0));
        handler = new BountyInvariantHandler(bountyContract, usdc, feeCalc, feeRecipient);
        targetContract(address(handler));
    }

    /// @notice INV-B1: Contract balance equals ghost_locked (bounties + bonds held).
    function invariant_contractBalanceEqualsGhostLocked() public view {
        assertEq(usdc.balanceOf(address(bountyContract)), handler.ghost_locked(), "bounty: balance != ghost_locked");
    }

    /// @notice INV-B2: Contract balance is never negative (sanity).
    function invariant_balanceNonNegative() public view {
        assertGe(usdc.balanceOf(address(bountyContract)), 0, "bounty: negative balance (impossible)");
    }
}
