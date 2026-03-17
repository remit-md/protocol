// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RemitTypes} from "../libraries/RemitTypes.sol";

/// @title IRemitStream
/// @notice Continuous streaming payments (lockup-linear model)
/// @dev Fund-holding. IMMUTABLE.
interface IRemitStream {
    /// @notice Open a payment stream
    /// @param streamId Unique stream identifier
    /// @param payee Address receiving the stream
    /// @param ratePerSecond USDC per second (6 decimals)
    /// @param maxTotal Maximum total USDC to lock (safety cap)
    /// @dev Caller must have approved maxTotal USDC. Emits StreamOpened.
    function openStream(bytes32 streamId, address payee, uint64 ratePerSecond, uint96 maxTotal) external;

    /// @notice Payee withdraws accrued funds
    /// @param streamId The stream ID
    /// @dev Withdrawable = ratePerSecond * elapsed - alreadyWithdrawn. Emits StreamWithdrawal.
    function withdraw(bytes32 streamId) external;

    /// @notice Close the stream. Settle remaining.
    /// @param streamId The stream ID
    /// @dev Either party. Payee gets accrued, payer gets remainder. Emits StreamClosed.
    function closeStream(bytes32 streamId) external;

    /// @notice V2: Check stream balance and emit StreamBalanceWarning or auto-terminate.
    ///         Callable by anyone (payer, payee, keeper). Emits StreamBalanceWarning if
    ///         remaining < 5 * ratePerSecond, or StreamTerminatedInsufficientBalance if depleted.
    /// @param streamId The stream ID
    function settle(bytes32 streamId) external;

    // === For Variants (relayer-submitted) ===

    function openStreamFor(address payer, bytes32 streamId, address payee, uint64 ratePerSecond, uint96 maxTotal)
        external;
    function withdrawFor(address payee, bytes32 streamId) external;
    function closeStreamFor(address caller, bytes32 streamId) external;
    function authorizeRelayer(address relayer) external;
    function revokeRelayer(address relayer) external;
    function isAuthorizedRelayer(address relayer) external view returns (bool);

    // === View Functions ===

    function getStream(bytes32 streamId) external view returns (RemitTypes.Stream memory);

    /// @notice Calculate currently withdrawable amount
    function withdrawable(bytes32 streamId) external view returns (uint96);
}
