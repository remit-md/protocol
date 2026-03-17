// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RemitTypes} from "../libraries/RemitTypes.sol";

/// @title IRemitDeposit
/// @notice Refundable deposits / collateral
/// @dev Fund-holding. IMMUTABLE.
interface IRemitDeposit {
    /// @notice Lock a deposit
    /// @param depositId Unique deposit identifier
    /// @param provider Service provider address
    /// @param amount USDC amount (6 decimals)
    /// @param expiry Unix timestamp for auto-return
    /// @dev Caller must have approved USDC. Emits DepositLocked.
    function lockDeposit(bytes32 depositId, address provider, uint96 amount, uint64 expiry) external;

    /// @notice Provider returns deposit to depositor
    /// @param depositId The deposit ID
    /// @dev Only provider. Emits DepositReturned.
    function returnDeposit(bytes32 depositId) external;

    /// @notice Provider forfeits deposit (keeps funds)
    /// @param depositId The deposit ID
    /// @dev Only provider. Triggers dispute automatically. Emits DepositForfeited.
    function forfeitDeposit(bytes32 depositId) external;

    /// @notice Depositor reclaims after expiry
    /// @param depositId The deposit ID
    /// @dev Only after expiry. Emits DepositReturned.
    function claimExpiredDeposit(bytes32 depositId) external;

    // === Relayer-Delegated (For-variants) ===

    /// @notice Lock deposit on behalf of a depositor (relayer pulls USDC from depositor)
    function lockDepositFor(address depositor, bytes32 depositId, address provider, uint96 amount, uint64 expiry)
        external;

    /// @notice Return deposit on behalf of the provider
    function returnDepositFor(bytes32 depositId, address provider) external;

    /// @notice Forfeit deposit on behalf of the provider
    function forfeitDepositFor(bytes32 depositId, address provider) external;

    /// @notice Claim expired deposit on behalf of the depositor
    function claimExpiredDepositFor(bytes32 depositId, address depositor) external;

    // === Relayer Admin ===

    function authorizeRelayer(address relayer) external;
    function revokeRelayer(address relayer) external;
    function isAuthorizedRelayer(address relayer) external view returns (bool);

    // === View Functions ===

    function getDeposit(bytes32 depositId) external view returns (RemitTypes.Deposit memory);
}
