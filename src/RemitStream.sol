// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRemitStream} from "./interfaces/IRemitStream.sol";
import {IRemitFeeCalculator} from "./interfaces/IRemitFeeCalculator.sol";
import {RemitTypes} from "./libraries/RemitTypes.sol";
import {RemitErrors} from "./libraries/RemitErrors.sol";
import {RemitEvents} from "./libraries/RemitEvents.sol";

/// @title RemitStream
/// @notice Lockup-linear streaming payments for AI agent services
/// @dev Fund-holding contract. IMMUTABLE — no proxy, no upgrade path.
///      Payer locks maxTotal USDC upfront. Payee withdraws accrued funds on demand.
///      Fee is charged on the pending (non-withdrawn) amount at close time only.
///      CEI pattern enforced. ReentrancyGuard on all fund-moving functions.
contract RemitStream is IRemitStream, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Immutable state
    // =========================================================================

    IERC20 public immutable usdc;
    IRemitFeeCalculator public immutable feeCalculator;
    address public immutable feeRecipient;

    // =========================================================================
    // Storage
    // =========================================================================

    mapping(bytes32 => RemitTypes.Stream) private _streams;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _usdc USDC token address
    /// @param _feeCalculator Fee calculator contract address
    /// @param _feeRecipient Address that receives protocol fees
    constructor(address _usdc, address _feeCalculator, address _feeRecipient) {
        if (_usdc == address(0)) revert RemitErrors.ZeroAddress();
        if (_feeCalculator == address(0)) revert RemitErrors.ZeroAddress();
        if (_feeRecipient == address(0)) revert RemitErrors.ZeroAddress();

        usdc = IERC20(_usdc);
        feeCalculator = IRemitFeeCalculator(_feeCalculator);
        feeRecipient = _feeRecipient;
    }

    // =========================================================================
    // External Functions
    // =========================================================================

    /// @inheritdoc IRemitStream
    /// @dev CEI: validate → update state → transfer USDC in
    function openStream(bytes32 streamId, address payee, uint64 ratePerSecond, uint96 maxTotal) external nonReentrant {
        // --- Checks ---
        // Duplicate-stream guard: startedAt is non-zero for any existing stream
        if (_streams[streamId].startedAt != 0) revert RemitErrors.EscrowAlreadyFunded(streamId);
        if (payee == address(0)) revert RemitErrors.ZeroAddress();
        if (payee == msg.sender) revert RemitErrors.SelfPayment(msg.sender);
        if (maxTotal < RemitTypes.MIN_AMOUNT) revert RemitErrors.BelowMinimum(maxTotal, RemitTypes.MIN_AMOUNT);
        if (ratePerSecond == 0) revert RemitErrors.ZeroAmount();

        // --- Effects ---
        _streams[streamId] = RemitTypes.Stream({
            payer: msg.sender,
            maxTotal: maxTotal,
            payee: payee,
            withdrawn: 0,
            ratePerSecond: ratePerSecond,
            startedAt: uint64(block.timestamp),
            closedAt: 0,
            status: RemitTypes.StreamStatus.Active
        });

        // --- Interactions ---
        usdc.safeTransferFrom(msg.sender, address(this), maxTotal);

        emit RemitEvents.StreamOpened(streamId, msg.sender, payee, ratePerSecond, maxTotal);
    }

    /// @inheritdoc IRemitStream
    /// @dev Only the payee may withdraw mid-stream. No fee on individual withdrawals.
    ///      CEI: validate → update withdrawn → transfer to payee
    function withdraw(bytes32 streamId) external nonReentrant {
        RemitTypes.Stream storage stream = _streams[streamId];

        // --- Checks ---
        if (stream.startedAt == 0) revert RemitErrors.StreamNotFound(streamId);
        if (stream.status != RemitTypes.StreamStatus.Active) revert RemitErrors.AlreadyClosed(streamId);
        if (msg.sender != stream.payee) revert RemitErrors.Unauthorized(msg.sender);

        uint96 amount = _pendingWithdrawable(stream);
        if (amount == 0) revert RemitErrors.ZeroAmount();

        // --- Effects ---
        stream.withdrawn += amount;

        // --- Interactions ---
        usdc.safeTransfer(stream.payee, amount);

        emit RemitEvents.StreamWithdrawal(streamId, stream.payee, amount);
    }

    /// @inheritdoc IRemitStream
    /// @dev Either party (payer or payee) may close.
    ///      Fee is charged only on the pending (non-withdrawn) accrued amount.
    ///      CEI: validate → mark closed → distribute funds
    function closeStream(bytes32 streamId) external nonReentrant {
        RemitTypes.Stream storage stream = _streams[streamId];

        // --- Checks ---
        if (stream.startedAt == 0) revert RemitErrors.StreamNotFound(streamId);
        if (stream.status != RemitTypes.StreamStatus.Active) revert RemitErrors.AlreadyClosed(streamId);
        if (msg.sender != stream.payer && msg.sender != stream.payee) {
            revert RemitErrors.Unauthorized(msg.sender);
        }

        uint64 elapsed = uint64(block.timestamp) - stream.startedAt;
        uint96 totalStreamed = _cappedStream(stream.ratePerSecond, elapsed, stream.maxTotal);
        uint96 pending = totalStreamed - stream.withdrawn; // owed to payee, not yet paid
        uint96 refund = stream.maxTotal - totalStreamed; // unstreamed → back to payer

        uint96 fee = 0;
        uint96 payeeGets = pending;
        if (pending > 0) {
            fee = feeCalculator.calculateFee(stream.payer, pending);
            if (fee > pending) fee = pending; // safety cap (should never trigger with sane fee calc)
            payeeGets = pending - fee;
        }

        // --- Effects ---
        stream.status = RemitTypes.StreamStatus.Closed;
        stream.closedAt = uint64(block.timestamp);

        // --- Interactions ---
        if (payeeGets > 0) usdc.safeTransfer(stream.payee, payeeGets);
        if (refund > 0) usdc.safeTransfer(stream.payer, refund);
        if (fee > 0) usdc.safeTransfer(feeRecipient, fee);

        emit RemitEvents.StreamClosed(streamId, totalStreamed, refund, fee);
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @inheritdoc IRemitStream
    function getStream(bytes32 streamId) external view returns (RemitTypes.Stream memory) {
        return _streams[streamId];
    }

    /// @inheritdoc IRemitStream
    function withdrawable(bytes32 streamId) external view returns (uint96) {
        RemitTypes.Stream storage stream = _streams[streamId];
        if (stream.startedAt == 0) return 0;
        if (stream.status != RemitTypes.StreamStatus.Active) return 0;
        return _pendingWithdrawable(stream);
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @dev Compute withdrawable amount for an active stream
    function _pendingWithdrawable(RemitTypes.Stream storage stream) internal view returns (uint96) {
        uint64 elapsed = uint64(block.timestamp) - stream.startedAt;
        uint96 totalStreamed = _cappedStream(stream.ratePerSecond, elapsed, stream.maxTotal);
        return totalStreamed - stream.withdrawn;
    }

    /// @dev min(rate * elapsed, cap) — overflow-safe via uint256 intermediate
    function _cappedStream(uint64 rate, uint64 elapsed, uint96 cap) internal pure returns (uint96) {
        uint256 streamed = uint256(rate) * uint256(elapsed);
        return streamed >= uint256(cap) ? cap : uint96(streamed);
    }
}
