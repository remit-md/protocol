// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RemitTypes} from "../libraries/RemitTypes.sol";

/// @title IRemitKeyRegistry
/// @notice Session key delegation registry for Remit agents
/// @dev Operators (master keys) delegate to agent session keys with spending limits, expiry, and revocation.
///      Other Remit contracts call this registry to validate session key signatures and record spending.
interface IRemitKeyRegistry {
    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Delegation record for a session key
    struct Delegation {
        address masterKey; // operator wallet that created this delegation
        address sessionKey; // agent wallet authorized to transact
        uint96 spendingLimit; // max USDC per transaction (6 decimals, 0 = unlimited)
        uint96 dailyLimit; // max USDC per day (6 decimals, 0 = unlimited)
        uint96 dailySpent; // USDC spent today (resets at day boundary)
        uint64 lastResetDay; // Unix day number of last daily reset (timestamp / 86400)
        uint8 allowedModelsBitmap; // bitmask of PaymentType enum values (0xFF = all allowed)
        uint64 expires; // unix timestamp when delegation expires (0 = no expiry)
        uint64 gracePeriodEnds; // for key rotation: old key valid until this timestamp (0 = none)
        bool revoked; // true if master key revoked this delegation
    }

    /// @notice Multi-signature configuration for a master key
    struct MultiSigConfig {
        address[] signers; // authorized signers
        uint8 threshold; // required number of signatures (e.g., 2 for 2-of-3)
        uint96 amountThreshold; // apply multi-sig for transactions >= this amount (0 = always)
    }

    // =========================================================================
    // Write Functions
    // =========================================================================

    /// @notice Master key delegates authority to a session key
    /// @param sessionKey Address of the session/agent key being delegated to
    /// @param spendingLimit Max USDC per transaction (0 = unlimited)
    /// @param dailyLimit Max USDC per day (0 = unlimited)
    /// @param allowedModelsBitmap Bitmask of PaymentType values allowed (0xFF = all)
    /// @param expires Delegation expiry timestamp (0 = no expiry)
    /// @param signature EIP-712 KeyDelegation signed by master key
    /// @dev Caller must be the master key. Session key must not have an active delegation.
    ///      Emits KeyDelegated.
    function delegateKey(
        address sessionKey,
        uint96 spendingLimit,
        uint96 dailyLimit,
        uint8 allowedModelsBitmap,
        uint64 expires,
        bytes calldata signature
    ) external;

    /// @notice Master key revokes a session key delegation
    /// @param sessionKey Address of the session key to revoke
    /// @dev Only callable by the master key that created the delegation. Emits KeyRevoked.
    function revokeKey(address sessionKey) external;

    /// @notice Atomically rotate session keys: delegate new key, revoke old key with grace period
    /// @param oldKey Address of the currently active session key
    /// @param newKey Address of the new session key to delegate
    /// @param gracePeriod Seconds during which oldKey remains valid for in-flight transactions
    /// @param newKeySignature EIP-712 KeyDelegation signature for new key, signed by master key
    /// @dev Only callable by the master key. Old key becomes grace-period-only; new key becomes active.
    ///      Emits KeyRevoked (for old key) and KeyDelegated (for new key).
    function rotateKey(address oldKey, address newKey, uint64 gracePeriod, bytes calldata newKeySignature) external;

    /// @notice Record spending against a session key's daily limit
    /// @param sessionKey Address of the session key
    /// @param amount USDC amount spent
    /// @dev Only callable by authorized Remit contracts. Reverts if limit exceeded.
    function recordSpend(address sessionKey, uint96 amount) external;

    /// @notice Configure multi-signature requirements for a master key
    /// @param signers List of authorized signers
    /// @param threshold Number of signatures required
    /// @param amountThreshold Apply multi-sig for transactions >= this USDC amount
    /// @dev Only callable by master key itself. Emits MultiSigConfigured.
    function configureMultiSig(address[] calldata signers, uint8 threshold, uint96 amountThreshold) external;

    /// @notice Authorize a contract to call recordSpend
    /// @param contractAddress Contract to authorize
    /// @dev Only callable by owner (protocol admin).
    function authorizeContract(address contractAddress) external;

    /// @notice Revoke a contract's authorization to call recordSpend
    /// @param contractAddress Contract to deauthorize
    /// @dev Only callable by owner (protocol admin). Used when decommissioning contracts.
    function deauthorizeContract(address contractAddress) external;

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @notice Check if a session key delegation is currently valid
    /// @param sessionKey Address of the session key
    /// @return valid True if delegation exists, not revoked, not expired, and not grace-period-only
    function isValidDelegation(address sessionKey) external view returns (bool valid);

    /// @notice Check if a session key can spend a given amount
    /// @param sessionKey Address of the session key
    /// @param amount USDC amount to spend
    /// @param paymentType PaymentType enum value for model restriction check
    /// @return ok True if within per-tx limit, daily limit, and allowed models
    function checkSpendingLimit(address sessionKey, uint96 amount, uint8 paymentType) external view returns (bool ok);

    /// @notice Get full delegation record for a session key
    /// @param sessionKey Address of the session key
    function getDelegation(address sessionKey) external view returns (Delegation memory);

    /// @notice Get all active session keys delegated from a master key
    /// @param masterKey Address of the master key
    /// @return sessionKeys Array of session key addresses (may include revoked/expired)
    function getActiveDelegations(address masterKey) external view returns (address[] memory sessionKeys);

    /// @notice Check if a transaction requires multi-sig validation for a master key
    /// @param masterKey Address of the master key
    /// @param amount USDC amount of the transaction
    /// @return required True if multi-sig is needed
    function requiresMultiSig(address masterKey, uint96 amount) external view returns (bool required);

    /// @notice Validate multi-sig signatures for a transaction
    /// @param masterKey Address of the master key
    /// @param hash EIP-712 hash of the transaction
    /// @param signatures Array of signatures from signers
    /// @return valid True if threshold signatures are valid
    function validateMultiSig(address masterKey, bytes32 hash, bytes[] calldata signatures)
        external
        view
        returns (bool valid);

    /// @notice Get the EIP-712 domain separator
    function domainSeparator() external view returns (bytes32);

    /// @notice Get the EIP-712 typehash for KeyDelegation
    function KEY_DELEGATION_TYPEHASH() external view returns (bytes32);
}
