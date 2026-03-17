// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUSDC
/// @notice Minimal interface for Circle's USDC contract, covering EIP-3009 and EIP-2612.
/// @dev Real USDC on Base/Ethereum and MockUSDC in test both implement this interface.
interface IUSDC {
    /// @notice Execute a transfer on behalf of `from` using a pre-signed EIP-3009 authorization.
    /// @param from       Address that signed the authorization
    /// @param to         Transfer recipient
    /// @param value      Amount to transfer (6 decimals)
    /// @param validAfter Earliest timestamp the auth is valid
    /// @param validBefore Expiry timestamp of the auth
    /// @param nonce      Unique nonce chosen by the signer (replay protection)
    /// @param v          ECDSA v
    /// @param r          ECDSA r
    /// @param s          ECDSA s
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice Returns whether a nonce has been consumed for a given authorizer.
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);

    /// @notice Standard ERC-20 transfer.
    function transfer(address to, uint256 value) external returns (bool);

    /// @notice Standard ERC-20 balanceOf.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Standard ERC-20 approve.
    function approve(address spender, uint256 value) external returns (bool);

    /// @notice Standard ERC-20 allowance.
    function allowance(address owner, address spender) external view returns (uint256);

    // ── EIP-2612: permit ────────────────────────────────────────────────────────

    /// @notice Approve via off-chain signature (EIP-2612).
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;

    /// @notice Returns the current permit nonce for an address.
    function nonces(address owner) external view returns (uint256);

    /// @notice Returns the EIP-712 domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
