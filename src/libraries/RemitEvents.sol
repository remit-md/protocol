// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RemitEvents
/// @notice Shared event definitions for all Remit contracts
library RemitEvents {
    // === Escrow Events ===
    event EscrowFunded(
        bytes32 indexed invoiceId, address indexed payer, address indexed payee, uint96 amount, uint64 timeout
    );

    event EscrowReleased(bytes32 indexed invoiceId, address indexed payee, uint96 amount, uint96 fee);

    event EscrowTimeout(bytes32 indexed invoiceId, address indexed payer, uint96 amount);

    event EscrowCancelled(bytes32 indexed invoiceId, address indexed payer, bool mutual, uint96 fee);

    event MilestoneReleased(bytes32 indexed invoiceId, uint8 milestoneIndex, uint96 amount);

    event ClaimStartConfirmed(bytes32 indexed invoiceId, address indexed payee, uint64 timestamp);

    event EvidenceSubmitted(bytes32 indexed invoiceId, uint8 milestoneIndex, bytes32 evidenceHash);

    // === Tab Events ===
    event TabOpened(
        bytes32 indexed tabId,
        address indexed payer,
        address indexed provider,
        uint96 limit,
        uint64 perUnit,
        uint64 expiry
    );

    event TabClosed(bytes32 indexed tabId, uint96 totalCharged, uint96 refund, uint96 fee);

    // === Stream Events ===
    event StreamOpened(
        bytes32 indexed streamId, address indexed payer, address indexed payee, uint64 ratePerSecond, uint96 maxTotal
    );

    event StreamClosed(bytes32 indexed streamId, uint96 totalStreamed, uint96 refund, uint96 fee);

    event StreamWithdrawal(bytes32 indexed streamId, address indexed payee, uint96 amount);

    // === Bounty Events ===
    event BountyPosted(
        bytes32 indexed bountyId, address indexed poster, uint96 amount, uint64 deadline, bytes32 taskHash
    );

    event BountyClaimed(bytes32 indexed bountyId, address indexed submitter, bytes32 evidenceHash);

    event BountyAwarded(bytes32 indexed bountyId, address indexed winner, uint96 amount, uint96 fee);

    event BountyExpired(bytes32 indexed bountyId, uint96 amount);

    // === Deposit Events ===
    event DepositLocked(
        bytes32 indexed depositId, address indexed depositor, address indexed provider, uint96 amount, uint64 expiry
    );

    event DepositReturned(bytes32 indexed depositId, address indexed depositor, uint96 amount);

    event DepositForfeited(bytes32 indexed depositId, address indexed provider, uint96 amount);

    // === General Events ===
    event DirectPayment(address indexed from, address indexed to, uint96 amount, uint96 fee, bytes32 memo);

    event FeeCollected(bytes32 indexed invoiceId, uint96 amount, address indexed feeRecipient);

    // === V2 Events ===

    /// @notice Emitted when a streaming payer's balance falls below 5x the rate
    event StreamBalanceWarning(
        bytes32 indexed streamId,
        address indexed payer,
        uint96 currentBalance,
        uint64 ratePerSecond,
        uint64 secondsRemaining
    );

    /// @notice Emitted when a stream is auto-terminated due to zero payer balance
    event StreamTerminatedInsufficientBalance(
        bytes32 indexed streamId, address indexed payer, address indexed payee, uint96 totalStreamed, uint96 fee
    );

    /// @notice Emitted when a bounty submission is rejected (bond returned to submitter)
    event BountyRejected(bytes32 indexed bountyId, address indexed submitter, address indexed poster, string reason);

    /// @notice Emitted when a master key delegates a session key
    event KeyDelegated(
        address indexed masterKey, address indexed sessionKey, uint96 spendingLimit, uint96 dailyLimit, uint64 expires
    );

    /// @notice Emitted when a session key is revoked
    event KeyRevoked(address indexed masterKey, address indexed sessionKey);

    /// @notice V2: Emitted when a pay-per-request payment is made (endpoint metadata attached)
    event PayPerRequest(address indexed payer, address indexed payee, uint96 amount, uint96 fee, string endpoint);

    /// @notice V3: Emitted when an x402 payment is settled through the Router.
    ///         The agent signed an EIP-3009 authorization targeting the Router as recipient;
    ///         the Router pulled the full amount, deducted the protocol fee, and forwarded net to `to`.
    /// @param from   Payer (signed the EIP-3009 authorization)
    /// @param to     Final recipient (net amount after fee)
    /// @param amount Total amount transferred (gross, before fee deduction)
    /// @param fee    Protocol fee collected and forwarded to feeRecipient
    /// @param nonce  EIP-3009 nonce consumed by this settlement (replay protection)
    event X402Payment(address indexed from, address indexed to, uint96 amount, uint96 fee, bytes32 indexed nonce);

    // === Admin Events ===

    /// @notice Emitted when contract ownership is transferred
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when a relayer is authorized to act on behalf of users (e.g. postBountyFor)
    event RelayerAuthorized(address indexed relayer);

    /// @notice Emitted when a relayer authorization is revoked
    event RelayerRevoked(address indexed relayer);

    /// @notice Emitted when a fee calculator caller is authorized
    event CallerAuthorized(address indexed caller);

    /// @notice Emitted when a fee calculator caller authorization is revoked
    event CallerRevoked(address indexed caller);

    /// @notice Emitted when a contract is authorized in the key registry
    event ContractAuthorized(address indexed contractAddress);

    /// @notice Emitted when a contract is deauthorized from the key registry
    event ContractDeauthorized(address indexed contractAddress);

    /// @notice Emitted when a router configuration value is updated
    event ConfigUpdated(string key, address indexed value);
}
