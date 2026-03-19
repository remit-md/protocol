// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IRemitKeyRegistry} from "./interfaces/IRemitKeyRegistry.sol";
import {RemitErrors} from "./libraries/RemitErrors.sol";
import {RemitEvents} from "./libraries/RemitEvents.sol";

/// @title RemitKeyRegistry
/// @notice Session key delegation registry for Remit agents
/// @dev Non-fund-holding contract — manages delegation metadata only, no USDC held here.
///      Operators (master keys) delegate to agent session keys with spending limits, expiry, and revocation.
///      Contracts that process payments call isValidDelegation() + checkSpendingLimit() + recordSpend().
contract RemitKeyRegistry is IRemitKeyRegistry, ReentrancyGuard, EIP712, Ownable {
    using ECDSA for bytes32;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice EIP-712 typehash for KeyDelegation authorization messages
    bytes32 public constant KEY_DELEGATION_TYPEHASH = keccak256(
        "KeyDelegation(address masterKey,address sessionKey,uint96 spendingLimit,uint96 dailyLimit,uint8 allowedModelsBitmap,uint64 expires,uint256 nonce)"
    );

    /// @notice EIP-712 typehash for KeyRotation authorization messages
    bytes32 public constant KEY_ROTATION_TYPEHASH = keccak256(
        "KeyRotation(address masterKey,address oldKey,address newKey,uint64 gracePeriod,uint96 spendingLimit,uint96 dailyLimit,uint8 allowedModelsBitmap,uint64 expires,uint256 nonce)"
    );

    // =========================================================================
    // State
    // =========================================================================

    /// @dev sessionKey → Delegation record
    mapping(address => Delegation) private _delegations;

    /// @dev masterKey → list of session keys ever delegated (includes revoked/expired)
    mapping(address => address[]) private _masterKeyDelegations;

    /// @dev masterKey → multi-sig config (optional)
    mapping(address => MultiSigConfig) private _multiSigConfigs;

    /// @dev masterKey → nonce (for EIP-712 replay prevention)
    mapping(address => uint256) private _nonces;

    /// @dev contractAddress → authorized to call recordSpend
    mapping(address => bool) private _authorizedContracts;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param owner Protocol admin (owns this contract, can authorize Remit contracts)
    constructor(address owner) EIP712("RemitKeyRegistry", "1") Ownable(owner) {}

    // =========================================================================
    // Write Functions
    // =========================================================================

    /// @inheritdoc IRemitKeyRegistry
    /// @dev Master key signs EIP-712 KeyDelegation message. Caller must BE the master key.
    function delegateKey(
        address sessionKey,
        uint96 spendingLimit,
        uint96 dailyLimit,
        uint8 allowedModelsBitmap,
        uint64 expires,
        bytes calldata signature
    ) external override nonReentrant {
        address masterKey = msg.sender;

        // --- Checks ---
        if (sessionKey == address(0)) revert RemitErrors.ZeroAddress();
        if (sessionKey == masterKey) revert RemitErrors.SelfPayment(masterKey);
        // KR-I-02: bitmap = 0 means no payment types allowed → unusable key, reject at creation
        if (allowedModelsBitmap == 0) revert RemitErrors.ZeroAmount();

        // Session key must not already have an active (non-revoked, non-expired) delegation
        Delegation storage existing = _delegations[sessionKey];
        if (existing.masterKey != address(0) && !existing.revoked) {
            if (existing.expires == 0 || existing.expires > block.timestamp) {
                revert RemitErrors.DelegationLimitExceeded(sessionKey, 0, 0);
            }
        }

        if (expires != 0 && expires <= block.timestamp) revert RemitErrors.InvalidTimeout(expires);

        // Verify EIP-712 signature from master key
        uint256 nonce = _nonces[masterKey]++;
        bytes32 structHash = keccak256(
            abi.encode(
                KEY_DELEGATION_TYPEHASH,
                masterKey,
                sessionKey,
                spendingLimit,
                dailyLimit,
                allowedModelsBitmap,
                expires,
                nonce
            )
        );
        address recovered = _hashTypedDataV4(structHash).recover(signature);
        if (recovered != masterKey) revert RemitErrors.InvalidSignature();

        // --- Effects ---
        _delegations[sessionKey] = Delegation({
            masterKey: masterKey,
            sessionKey: sessionKey,
            spendingLimit: spendingLimit,
            dailyLimit: dailyLimit,
            dailySpent: 0,
            lastResetDay: uint64(block.timestamp / 86400),
            allowedModelsBitmap: allowedModelsBitmap,
            expires: expires,
            gracePeriodEnds: 0,
            revoked: false
        });
        _masterKeyDelegations[masterKey].push(sessionKey);

        emit RemitEvents.KeyDelegated(masterKey, sessionKey, spendingLimit, dailyLimit, expires);
    }

    /// @inheritdoc IRemitKeyRegistry
    function revokeKey(address sessionKey) external override {
        Delegation storage d = _delegations[sessionKey];
        if (d.masterKey != msg.sender) revert RemitErrors.Unauthorized(msg.sender);
        if (d.revoked) revert RemitErrors.Unauthorized(sessionKey);

        // --- Effects ---
        d.revoked = true;
        d.gracePeriodEnds = 0;

        emit RemitEvents.KeyRevoked(msg.sender, sessionKey);
    }

    /// @inheritdoc IRemitKeyRegistry
    /// @dev Atomically: delegates newKey with same limits as oldKey, starts grace period on oldKey.
    function rotateKey(address oldKey, address newKey, uint64 gracePeriod, bytes calldata newKeySignature)
        external
        override
        nonReentrant
    {
        address masterKey = msg.sender;

        // --- Checks ---
        if (newKey == address(0)) revert RemitErrors.ZeroAddress();
        if (newKey == masterKey || newKey == oldKey) revert RemitErrors.SelfPayment(masterKey);

        Delegation storage old = _delegations[oldKey];
        if (old.masterKey != masterKey) revert RemitErrors.Unauthorized(masterKey);
        if (old.revoked) revert RemitErrors.DelegationExpired(oldKey);

        // New key must not already have an active delegation
        Delegation storage existingNew = _delegations[newKey];
        if (existingNew.masterKey != address(0) && !existingNew.revoked) {
            if (existingNew.expires == 0 || existingNew.expires > block.timestamp) {
                revert RemitErrors.DelegationLimitExceeded(newKey, 0, 0);
            }
        }

        // Verify EIP-712 KeyRotation signature from master key
        uint256 nonce = _nonces[masterKey]++;
        bytes32 structHash = keccak256(
            abi.encode(
                KEY_ROTATION_TYPEHASH,
                masterKey,
                oldKey,
                newKey,
                gracePeriod,
                old.spendingLimit,
                old.dailyLimit,
                old.allowedModelsBitmap,
                old.expires,
                nonce
            )
        );
        address recovered = _hashTypedDataV4(structHash).recover(newKeySignature);
        if (recovered != masterKey) revert RemitErrors.InvalidSignature();

        // --- Effects ---
        // Grant old key a grace period for in-flight transactions, then mark revoked
        old.gracePeriodEnds = uint64(block.timestamp) + gracePeriod;
        old.revoked = true;

        // Delegate new key (inherits limits from old key)
        _delegations[newKey] = Delegation({
            masterKey: masterKey,
            sessionKey: newKey,
            spendingLimit: old.spendingLimit,
            dailyLimit: old.dailyLimit,
            dailySpent: 0,
            lastResetDay: uint64(block.timestamp / 86400),
            allowedModelsBitmap: old.allowedModelsBitmap,
            expires: old.expires,
            gracePeriodEnds: 0,
            revoked: false
        });
        _masterKeyDelegations[masterKey].push(newKey);

        emit RemitEvents.KeyRevoked(masterKey, oldKey);
        emit RemitEvents.KeyDelegated(masterKey, newKey, old.spendingLimit, old.dailyLimit, old.expires);
    }

    /// @inheritdoc IRemitKeyRegistry
    /// @dev Only callable by Remit contracts authorized via authorizeContract().
    ///      Resets daily spend at day boundaries. Reverts if limits exceeded.
    function recordSpend(address sessionKey, uint96 amount) external override {
        if (!_authorizedContracts[msg.sender]) revert RemitErrors.Unauthorized(msg.sender);

        Delegation storage d = _delegations[sessionKey];
        if (d.masterKey == address(0)) return; // master key (no delegation) — no tracking needed

        // Reset daily spend at day boundary
        uint64 today = uint64(block.timestamp / 86400);
        if (today > d.lastResetDay) {
            d.dailySpent = 0;
            d.lastResetDay = today;
        }

        // Check per-tx limit
        if (d.spendingLimit != 0 && amount > d.spendingLimit) {
            revert RemitErrors.DelegationLimitExceeded(sessionKey, amount, d.spendingLimit);
        }

        // Check daily limit
        if (d.dailyLimit != 0) {
            uint96 newDailySpent = d.dailySpent + amount;
            if (newDailySpent > d.dailyLimit) {
                revert RemitErrors.DelegationLimitExceeded(sessionKey, newDailySpent, d.dailyLimit);
            }
            d.dailySpent = newDailySpent;
        }
    }

    /// @inheritdoc IRemitKeyRegistry
    function configureMultiSig(address[] calldata signers, uint8 threshold, uint96 amountThreshold) external override {
        if (threshold == 0 || threshold > signers.length) revert RemitErrors.BelowMinimum(threshold, 1);
        if (signers.length > 10) revert RemitErrors.BelowMinimum(10, signers.length); // max 10 signers

        // Validate no zero-address signers
        for (uint256 i; i < signers.length; ++i) {
            if (signers[i] == address(0)) revert RemitErrors.ZeroAddress();
        }

        MultiSigConfig storage config = _multiSigConfigs[msg.sender];
        config.threshold = threshold;
        config.amountThreshold = amountThreshold;
        // Copy signers array
        delete config.signers;
        for (uint256 i; i < signers.length; ++i) {
            config.signers.push(signers[i]);
        }
    }

    /// @inheritdoc IRemitKeyRegistry
    function authorizeContract(address contractAddress) external override onlyOwner {
        if (contractAddress == address(0)) revert RemitErrors.ZeroAddress();
        _authorizedContracts[contractAddress] = true;
        emit RemitEvents.ContractAuthorized(contractAddress);
    }

    /// @inheritdoc IRemitKeyRegistry
    /// @dev Used when decommissioning old contract versions (e.g. after an upgrade).
    function deauthorizeContract(address contractAddress) external override onlyOwner {
        if (contractAddress == address(0)) revert RemitErrors.ZeroAddress();
        _authorizedContracts[contractAddress] = false;
        emit RemitEvents.ContractDeauthorized(contractAddress);
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @inheritdoc IRemitKeyRegistry
    function isValidDelegation(address sessionKey) external view override returns (bool valid) {
        Delegation storage d = _delegations[sessionKey];
        if (d.masterKey == address(0)) return false; // no delegation exists
        if (d.revoked) {
            // Allow grace period for key rotation
            if (d.gracePeriodEnds == 0 || block.timestamp > d.gracePeriodEnds) return false;
        }
        if (d.expires != 0 && block.timestamp >= d.expires) return false;
        return true;
    }

    /// @inheritdoc IRemitKeyRegistry
    function checkSpendingLimit(address sessionKey, uint96 amount, uint8 paymentType)
        external
        view
        override
        returns (bool ok)
    {
        Delegation storage d = _delegations[sessionKey];
        if (d.masterKey == address(0)) return true; // master key — no limits

        // Check model restriction (bitmask)
        if (d.allowedModelsBitmap != 0xFF && (d.allowedModelsBitmap & (uint8(1) << paymentType)) == 0) {
            return false;
        }

        // Check per-tx limit
        if (d.spendingLimit != 0 && amount > d.spendingLimit) return false;

        // Check daily limit (with day boundary reset simulation)
        if (d.dailyLimit != 0) {
            uint96 spentToday = d.dailySpent;
            uint64 today = uint64(block.timestamp / 86400);
            if (today > d.lastResetDay) spentToday = 0; // would be reset on next write
            if (spentToday + amount > d.dailyLimit) return false;
        }

        return true;
    }

    /// @inheritdoc IRemitKeyRegistry
    function getDelegation(address sessionKey) external view override returns (Delegation memory) {
        return _delegations[sessionKey];
    }

    /// @inheritdoc IRemitKeyRegistry
    function getActiveDelegations(address masterKey) external view override returns (address[] memory sessionKeys) {
        return _masterKeyDelegations[masterKey];
    }

    /// @inheritdoc IRemitKeyRegistry
    function requiresMultiSig(address masterKey, uint96 amount) external view override returns (bool required) {
        MultiSigConfig storage config = _multiSigConfigs[masterKey];
        if (config.threshold == 0) return false; // not configured
        return config.amountThreshold == 0 || amount >= config.amountThreshold;
    }

    /// @inheritdoc IRemitKeyRegistry
    function validateMultiSig(address masterKey, bytes32 hash, bytes[] calldata signatures)
        external
        view
        override
        returns (bool valid)
    {
        MultiSigConfig storage config = _multiSigConfigs[masterKey];
        if (config.threshold == 0) return false;

        uint256 validCount;
        uint256 signerCount = config.signers.length;

        // Track used signers to prevent duplicate signatures
        // Using a bitmask (up to 256 signers, we limit to 10 so uint16 is fine)
        uint256 usedBitmask;

        for (uint256 i; i < signatures.length && validCount < config.threshold; ++i) {
            address recovered = hash.recover(signatures[i]);
            for (uint256 j; j < signerCount; ++j) {
                if (config.signers[j] == recovered && (usedBitmask & (uint256(1) << j)) == 0) {
                    usedBitmask |= (uint256(1) << j);
                    ++validCount;
                    break;
                }
            }
        }

        return validCount >= config.threshold;
    }

    /// @inheritdoc IRemitKeyRegistry
    function domainSeparator() external view override returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Get the current nonce for a master key (for EIP-712 replay prevention)
    function getNonce(address masterKey) external view returns (uint256) {
        return _nonces[masterKey];
    }

    /// @notice Check if a contract is authorized to call recordSpend
    function isAuthorizedContract(address contractAddress) external view returns (bool) {
        return _authorizedContracts[contractAddress];
    }
}
