// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IOnrampVaultFactory
/// @notice Interface for the on-ramp vault factory (used by server chain_client).
interface IOnrampVaultFactory {
    /// @notice Get or deploy a vault for an operator. Idempotent.
    /// @param operator Operator wallet address.
    /// @return vault The vault clone address.
    function getOrCreate(address operator) external returns (address vault);

    /// @notice Predict the deterministic vault address (no deployment).
    /// @param operator Operator wallet address.
    /// @return The deterministic vault address.
    function predictVault(address operator) external view returns (address);

    /// @notice Look up an operator's vault (address(0) if not deployed).
    /// @param operator Operator wallet address.
    /// @return The vault address (or address(0)).
    function vaults(address operator) external view returns (address);
}
