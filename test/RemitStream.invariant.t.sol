// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {MockFeeCalculator} from "./helpers/MockFeeCalculator.sol";
import {RemitStream} from "../src/RemitStream.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";

// =============================================================================
// StreamInvariantHandler
//
// Extended invariant handler for RemitStream. Tests:
//   INV-S1: usdc.balanceOf(stream) == ghost_deposited - ghost_outflows
//   INV-S2: no stream can have withdrawn > maxTotal
//   INV-S3: withdrawable never exceeds maxTotal - withdrawn
// =============================================================================

contract StreamInvariantHandler is Test {
    RemitStream public stream;
    MockUSDC public usdc;
    MockFeeCalculator public feeCalc;
    address public feeRecipient;

    address internal payer = makeAddr("inv-s-payer");
    address internal payee = makeAddr("inv-s-payee");

    bytes32[] internal _activeIds;
    mapping(bytes32 => uint96) internal _maxTotal;
    uint256 internal _idCounter;

    uint256 public ghost_deposited;
    uint256 public ghost_outflows; // everything that left the contract

    constructor(RemitStream _stream, MockUSDC _usdc, MockFeeCalculator _feeCalc, address _feeRecipient) {
        stream = _stream;
        usdc = _usdc;
        feeCalc = _feeCalc;
        feeRecipient = _feeRecipient;
    }

    function openStream(uint96 maxTotal, uint64 ratePerSecond) external {
        maxTotal = uint96(bound(maxTotal, RemitTypes.MIN_AMOUNT, 10_000e6));
        ratePerSecond = uint64(bound(ratePerSecond, 1, maxTotal / 2 == 0 ? 1 : maxTotal / 2));

        bytes32 id = keccak256(abi.encodePacked("inv-stream-ext", _idCounter++));

        usdc.mint(payer, maxTotal);
        vm.prank(payer);
        usdc.approve(address(stream), maxTotal);

        vm.prank(payer);
        stream.openStream(id, payee, ratePerSecond, maxTotal);

        _activeIds.push(id);
        _maxTotal[id] = maxTotal;
        ghost_deposited += maxTotal;
    }

    function withdraw(uint256 idx) external {
        if (_activeIds.length == 0) return;
        idx = bound(idx, 0, _activeIds.length - 1);
        bytes32 id = _activeIds[idx];

        uint96 w = stream.withdrawable(id);
        if (w == 0) return;

        uint256 contractBefore = usdc.balanceOf(address(stream));

        vm.prank(payee);
        stream.withdraw(id);

        ghost_outflows += contractBefore - usdc.balanceOf(address(stream));
    }

    function closeStream(uint256 idx) external {
        if (_activeIds.length == 0) return;
        idx = bound(idx, 0, _activeIds.length - 1);
        bytes32 id = _activeIds[idx];

        uint256 contractBefore = usdc.balanceOf(address(stream));

        vm.prank(payer);
        stream.closeStream(id);

        ghost_outflows += contractBefore - usdc.balanceOf(address(stream));
        _removeAt(idx);
    }

    function advanceTime(uint64 delta) external {
        delta = uint64(bound(delta, 1, 7 days));
        vm.warp(block.timestamp + delta);
    }

    function activeCount() external view returns (uint256) {
        return _activeIds.length;
    }

    function getActiveId(uint256 idx) external view returns (bytes32) {
        return _activeIds[idx];
    }

    function getMaxTotal(bytes32 id) external view returns (uint96) {
        return _maxTotal[id];
    }

    function _removeAt(uint256 idx) internal {
        uint256 last = _activeIds.length - 1;
        if (idx != last) _activeIds[idx] = _activeIds[last];
        _activeIds.pop();
    }
}

// =============================================================================
// StreamExtendedInvariantTest
// =============================================================================

contract StreamExtendedInvariantTest is Test {
    StreamInvariantHandler internal handler;
    RemitStream internal streamContract;
    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    address internal feeRecipient = makeAddr("inv-s-fee");

    function setUp() public {
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        streamContract = new RemitStream(address(usdc), address(feeCalc), feeRecipient, makeAddr("admin"), address(0));
        handler = new StreamInvariantHandler(streamContract, usdc, feeCalc, feeRecipient);
        targetContract(address(handler));
    }

    /// @notice INV-S1: Contract balance equals deposited minus all outflows.
    function invariant_balanceEqualsDepositedMinusOutflows() public view {
        assertEq(
            usdc.balanceOf(address(streamContract)),
            handler.ghost_deposited() - handler.ghost_outflows(),
            "stream: balance != deposited - outflows"
        );
    }

    /// @notice INV-S2: For every active stream, withdrawn <= maxTotal.
    function invariant_withdrawnNeverExceedsMaxTotal() public view {
        uint256 count = handler.activeCount();
        for (uint256 i; i < count; ++i) {
            bytes32 id = handler.getActiveId(i);
            RemitTypes.Stream memory s = streamContract.getStream(id);
            assertLe(s.withdrawn, s.maxTotal, "stream: withdrawn > maxTotal");
        }
    }

    /// @notice INV-S3: Withdrawable + withdrawn <= maxTotal for active streams.
    function invariant_withdrawablePlusWithdrawnCapped() public view {
        uint256 count = handler.activeCount();
        for (uint256 i; i < count; ++i) {
            bytes32 id = handler.getActiveId(i);
            RemitTypes.Stream memory s = streamContract.getStream(id);
            uint96 w = streamContract.withdrawable(id);
            assertLe(uint256(w) + uint256(s.withdrawn), s.maxTotal, "stream: withdrawable + withdrawn > maxTotal");
        }
    }
}
