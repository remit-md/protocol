// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {RemitOnrampVault} from "./RemitOnrampVault.sol";

/// @title OnrampVaultFactory
/// @notice Deploys deterministic EIP-1167 clones of RemitOnrampVault, one per operator.
/// @dev Does NOT hold funds — each vault holds its own USDC.
///      Uses CREATE2 with salt = keccak256(operator) for deterministic addressing.
///      No admin functions. Once deployed, the factory's parameters are frozen.
///
///      Gas: clone deployment ~45K gas (~$0.005 on Base).
contract OnrampVaultFactory {
    using Clones for address;

    // =========================================================================
    // Immutable state
    // =========================================================================

    /// @dev Address of the RemitOnrampVault implementation (clones delegate to this).
    address public immutable implementation;

    /// @dev USDC token address (passed to each clone on init).
    address public immutable usdc;

    /// @dev Protocol fee recipient (passed to each clone on init).
    address public immutable feeRecipient;

    // =========================================================================
    // Storage
    // =========================================================================

    /// @dev operator wallet => deployed vault clone address.
    mapping(address => address) public vaults;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a new vault clone is deployed for an operator.
    event VaultCreated(address indexed operator, address indexed vault);

    // =========================================================================
    // Errors
    // =========================================================================

    error ZeroAddress();

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _implementation Deployed RemitOnrampVault implementation address.
    /// @param _usdc USDC token address.
    /// @param _feeRecipient Protocol fee recipient address.
    constructor(address _implementation, address _usdc, address _feeRecipient) {
        if (_implementation == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();

        implementation = _implementation;
        usdc = _usdc;
        feeRecipient = _feeRecipient;
    }

    // =========================================================================
    // External functions
    // =========================================================================

    /// @notice Get or deploy a vault for an operator. Idempotent.
    /// @param _operator Operator wallet address.
    /// @return vault The vault clone address (existing or newly deployed).
    function getOrCreate(address _operator) external returns (address vault) {
        if (_operator == address(0)) revert ZeroAddress();

        vault = vaults[_operator];
        if (vault != address(0)) return vault;

        bytes32 salt = keccak256(abi.encodePacked(_operator));
        vault = implementation.cloneDeterministic(salt);
        RemitOnrampVault(vault).initialize(_operator, usdc, feeRecipient);
        vaults[_operator] = vault;

        emit VaultCreated(_operator, vault);
    }

    /// @notice Predict the deterministic vault address for an operator.
    /// @dev Does NOT deploy. USDC sent to a predicted-but-undeployed address will be
    ///      accessible once the clone is deployed at that address. However, the server
    ///      should always call getOrCreate() before returning the vault address to users.
    /// @param _operator Operator wallet address.
    /// @return The deterministic vault address.
    function predictVault(address _operator) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(_operator));
        return implementation.predictDeterministicAddress(salt);
    }
}
