// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {MockFeeCalculator} from "./helpers/MockFeeCalculator.sol";
import {RemitDeposit} from "../src/RemitDeposit.sol";
import {RemitBounty} from "../src/RemitBounty.sol";
import {RemitStream} from "../src/RemitStream.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";

// =============================================================================
// DepositHandler
//
// Wraps RemitDeposit with ghost accounting so the fuzzer can call
// lockDeposit / returnDeposit / forfeitDeposit in any order.
//
// Ghost invariant: usdc.balanceOf(dep) == ghost_locked
// =============================================================================

contract DepositHandler is Test {
    RemitDeposit public dep;
    MockUSDC public usdc;

    address internal depositor = makeAddr("inv-depositor");
    address internal provider = makeAddr("inv-provider");

    bytes32[] internal _activeIds;
    mapping(bytes32 => uint96) internal _amount;
    mapping(bytes32 => uint64) internal _expiry;
    uint256 internal _idCounter;

    /// @dev Ghost variable: sum of amounts currently locked in contract.
    uint256 public ghost_locked;

    constructor(RemitDeposit _dep, MockUSDC _usdc) {
        dep = _dep;
        usdc = _usdc;
    }

    // ── Callable by invariant fuzzer ─────────────────────────────────────────

    function lockDeposit(uint96 amount, uint64 expDelta) external {
        amount = uint96(bound(amount, RemitTypes.MIN_AMOUNT, 10_000e6));
        expDelta = uint64(bound(expDelta, 1 hours, 365 days));

        bytes32 id = keccak256(abi.encodePacked("inv-dep", _idCounter++));
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
        _removeAt(idx);
    }

    function forfeitDeposit(uint256 idx) external {
        if (_activeIds.length == 0) return;
        idx = bound(idx, 0, _activeIds.length - 1);
        bytes32 id = _activeIds[idx];

        vm.prank(provider);
        dep.forfeitDeposit(id);

        ghost_locked -= _amount[id];
        _removeAt(idx);
    }

    function claimExpiredDeposit(uint256 idx) external {
        if (_activeIds.length == 0) return;
        idx = bound(idx, 0, _activeIds.length - 1);
        bytes32 id = _activeIds[idx];

        // Warp past the specific deposit's expiry.
        vm.warp(_expiry[id] + 1);

        vm.prank(depositor);
        dep.claimExpiredDeposit(id);

        ghost_locked -= _amount[id];
        _removeAt(idx);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function activeCount() external view returns (uint256) {
        return _activeIds.length;
    }

    function _removeAt(uint256 idx) internal {
        uint256 last = _activeIds.length - 1;
        if (idx != last) {
            _activeIds[idx] = _activeIds[last];
        }
        _activeIds.pop();
    }
}

// =============================================================================
// DepositInvariantTest
// =============================================================================

contract DepositInvariantTest is Test {
    DepositHandler internal handler;
    RemitDeposit internal dep;
    MockUSDC internal usdc;

    function setUp() public {
        usdc = new MockUSDC();
        dep = new RemitDeposit(address(usdc), address(0), address(this));
        handler = new DepositHandler(dep, usdc);
        targetContract(address(handler));
    }

    /// @notice Core conservation invariant: contract balance always equals
    ///         the sum of all amounts still locked (no dust, no inflation).
    function invariant_contractBalanceEqualsGhostLocked() public view {
        assertEq(usdc.balanceOf(address(dep)), handler.ghost_locked(), "deposit: contract balance != ghost_locked");
    }
}

// =============================================================================
// BountyHandler
//
// Wraps RemitBounty with ghost accounting. Uses zero submission bond for
// simple accounting (bond handling is tested in fuzz tests).
//
// Ghost invariant: usdc.balanceOf(bounty) == ghost_locked
// =============================================================================

contract BountyHandler is Test {
    RemitBounty public bounty;
    MockUSDC public usdc;
    MockFeeCalculator public feeCalc;
    address public feeRecipient;

    address internal poster = makeAddr("inv-poster");
    address internal submitter = makeAddr("inv-submitter");

    bytes32[] internal _openIds;
    bytes32[] internal _claimedIds;
    mapping(bytes32 => uint96) internal _amount;
    mapping(bytes32 => uint64) internal _deadline;
    uint256 internal _idCounter;

    /// @dev Ghost variable: sum of amounts currently locked in contract.
    uint256 public ghost_locked;
    /// @dev Ghost variable: cumulative fees paid out.
    uint256 public ghost_fees;

    constructor(RemitBounty _bounty, MockUSDC _usdc, MockFeeCalculator _feeCalc, address _feeRecipient) {
        bounty = _bounty;
        usdc = _usdc;
        feeCalc = _feeCalc;
        feeRecipient = _feeRecipient;
    }

    // ── Callable by invariant fuzzer ─────────────────────────────────────────

    function postBounty(uint96 amount, uint64 deadlineDelta) external {
        amount = uint96(bound(amount, RemitTypes.MIN_AMOUNT, 10_000e6));
        deadlineDelta = uint64(bound(deadlineDelta, 1 hours, 365 days));

        bytes32 id = keccak256(abi.encodePacked("inv-bounty", _idCounter++));
        uint64 deadline = uint64(block.timestamp + deadlineDelta);

        usdc.mint(poster, amount);
        vm.prank(poster);
        usdc.approve(address(bounty), amount);

        vm.prank(poster);
        // submissionBond = 0, maxAttempts = 0 (unlimited)
        bounty.postBounty(id, amount, deadline, keccak256(abi.encodePacked("task", id)), 0, 0);

        _openIds.push(id);
        _amount[id] = amount;
        _deadline[id] = deadline;
        ghost_locked += amount;
    }

    function submitBounty(uint256 idx) external {
        if (_openIds.length == 0) return;
        idx = bound(idx, 0, _openIds.length - 1);
        bytes32 id = _openIds[idx];

        // Only submit if before deadline
        if (block.timestamp > _deadline[id]) return;

        vm.prank(submitter);
        bounty.submitBounty(id, keccak256(abi.encodePacked("evidence", id)));

        // Move to claimed (no bond to track — bond=0)
        _claimedIds.push(id);
        _removeOpenAt(idx);
    }

    function awardBounty(uint256 idx) external {
        if (_claimedIds.length == 0) return;
        idx = bound(idx, 0, _claimedIds.length - 1);
        bytes32 id = _claimedIds[idx];

        uint96 fee = feeCalc.calculateFee(poster, _amount[id]);
        if (fee > _amount[id]) fee = _amount[id];

        vm.prank(poster);
        bounty.awardBounty(id, submitter);

        ghost_locked -= _amount[id];
        ghost_fees += fee;
        _removeClaimedAt(idx);
    }

    function reclaimBounty(uint256 idx) external {
        if (_openIds.length == 0) return;
        idx = bound(idx, 0, _openIds.length - 1);
        bytes32 id = _openIds[idx];

        // Warp past deadline so reclaim is allowed
        vm.warp(_deadline[id] + 1);

        vm.prank(poster);
        bounty.reclaimBounty(id);

        // reclaimBounty returns full amount (no fee on reclaim)
        ghost_locked -= _amount[id];
        _removeOpenAt(idx);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function openCount() external view returns (uint256) {
        return _openIds.length;
    }

    function claimedCount() external view returns (uint256) {
        return _claimedIds.length;
    }

    function _removeOpenAt(uint256 idx) internal {
        uint256 last = _openIds.length - 1;
        if (idx != last) {
            _openIds[idx] = _openIds[last];
        }
        _openIds.pop();
    }

    function _removeClaimedAt(uint256 idx) internal {
        uint256 last = _claimedIds.length - 1;
        if (idx != last) {
            _claimedIds[idx] = _claimedIds[last];
        }
        _claimedIds.pop();
    }
}

// =============================================================================
// BountyInvariantTest
// =============================================================================

contract BountyInvariantTest is Test {
    BountyHandler internal handler;
    RemitBounty internal bountyContract;
    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    address internal feeRecipient = makeAddr("inv-fee-recipient");
    address internal admin = makeAddr("inv-admin");

    function setUp() public {
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        bountyContract = new RemitBounty(address(usdc), address(feeCalc), feeRecipient, admin, address(0));
        handler = new BountyHandler(bountyContract, usdc, feeCalc, feeRecipient);
        targetContract(address(handler));
    }

    /// @notice Core conservation invariant: contract balance always equals
    ///         the sum of all active (not-yet-settled) bounty amounts.
    function invariant_contractBalanceEqualsGhostLocked() public view {
        assertEq(
            usdc.balanceOf(address(bountyContract)), handler.ghost_locked(), "bounty: contract balance != ghost_locked"
        );
    }
}

// =============================================================================
// StreamHandler
//
// Wraps RemitStream. Tests that the contract never holds more or fewer funds
// than the sum of all active stream allocations minus total withdrawn.
//
// Ghost invariant:
//   usdc.balanceOf(stream) == ghost_deposited - ghost_withdrawn - ghost_fees
// =============================================================================

contract StreamHandler is Test {
    RemitStream public stream;
    MockUSDC public usdc;
    MockFeeCalculator public feeCalc;
    address public feeRecipient;

    address internal payer = makeAddr("inv-stream-payer");
    address internal payee = makeAddr("inv-stream-payee");

    bytes32[] internal _activeIds;
    mapping(bytes32 => uint96) internal _maxTotal;
    mapping(bytes32 => uint64) internal _rate;
    uint256 internal _idCounter;

    /// @dev Ghost variables tracking fund flows (excludes fees — feeCalc is 1%).
    uint256 public ghost_deposited;
    uint256 public ghost_withdrawn; // payee withdrawals (before fee)
    uint256 public ghost_fees;

    constructor(RemitStream _stream, MockUSDC _usdc, MockFeeCalculator _feeCalc, address _feeRecipient) {
        stream = _stream;
        usdc = _usdc;
        feeCalc = _feeCalc;
        feeRecipient = _feeRecipient;
    }

    function openStream(uint96 maxTotal, uint64 ratePerSecond) external {
        maxTotal = uint96(bound(maxTotal, RemitTypes.MIN_AMOUNT, 10_000e6));
        // rate must be > 0 and <= maxTotal/2 (reasonable)
        ratePerSecond = uint64(bound(ratePerSecond, 1, maxTotal / 2 == 0 ? 1 : maxTotal / 2));

        bytes32 id = keccak256(abi.encodePacked("inv-stream", _idCounter++));

        usdc.mint(payer, maxTotal);
        vm.prank(payer);
        usdc.approve(address(stream), maxTotal);

        vm.prank(payer);
        stream.openStream(id, payee, ratePerSecond, maxTotal);

        _activeIds.push(id);
        _maxTotal[id] = maxTotal;
        _rate[id] = ratePerSecond;
        ghost_deposited += maxTotal;
    }

    function closeStream(uint256 idx) external {
        if (_activeIds.length == 0) return;
        idx = bound(idx, 0, _activeIds.length - 1);
        bytes32 id = _activeIds[idx];

        // Snapshot balances before close to measure actual outflows.
        uint256 contractBefore = usdc.balanceOf(address(stream));

        vm.prank(payer);
        stream.closeStream(id);

        // The contract released `contractBefore` worth of this stream's funds.
        // ghost_withdrawn + ghost_fees tracks what went OUT of this stream.
        uint256 released = contractBefore - usdc.balanceOf(address(stream));
        // MockFeeCalculator uses 1% fee on the PENDING portion only.
        // We just track total outflow without splitting — invariant uses totals.
        ghost_withdrawn += released;

        _removeAt(idx);
    }

    function activeCount() external view returns (uint256) {
        return _activeIds.length;
    }

    function _removeAt(uint256 idx) internal {
        uint256 last = _activeIds.length - 1;
        if (idx != last) {
            _activeIds[idx] = _activeIds[last];
        }
        _activeIds.pop();
    }
}

// =============================================================================
// StreamInvariantTest
// =============================================================================

contract StreamInvariantTest is Test {
    StreamHandler internal handler;
    RemitStream internal streamContract;
    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    address internal feeRecipient = makeAddr("inv-stream-fee-recipient");

    function setUp() public {
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        streamContract = new RemitStream(address(usdc), address(feeCalc), feeRecipient, address(0));
        handler = new StreamHandler(streamContract, usdc, feeCalc, feeRecipient);
        targetContract(address(handler));
    }

    /// @notice Core conservation invariant: contract balance never exceeds
    ///         total deposited minus total released.
    function invariant_contractBalanceNeverExceedsDeposited() public view {
        uint256 balance = usdc.balanceOf(address(streamContract));
        uint256 netIn = handler.ghost_deposited() - handler.ghost_withdrawn();
        assertEq(balance, netIn, "stream: balance != deposited - withdrawn");
    }
}
