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

    event EscrowDisputed(bytes32 indexed invoiceId, address indexed filer, bytes32 reasonHash);

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

    event TabCharged(bytes32 indexed tabId, uint96 amount, uint96 totalCharged, uint96 remaining);

    event TabClosed(bytes32 indexed tabId, uint96 totalCharged, uint96 refund, uint96 fee);

    event TabDepleted(bytes32 indexed tabId, uint96 totalCharged);

    // === Stream Events ===
    event StreamOpened(
        bytes32 indexed streamId, address indexed payer, address indexed payee, uint64 ratePerSecond, uint96 maxTotal
    );

    event StreamClosed(bytes32 indexed streamId, uint96 totalStreamed, uint96 refund, uint96 fee);

    event StreamWithdrawal(bytes32 indexed streamId, address indexed payee, uint96 amount);

    // === Subscription Events ===
    event SubscriptionCreated(
        bytes32 indexed subId, address indexed payer, address indexed provider, uint96 amount, uint64 interval
    );

    event SubscriptionCharged(bytes32 indexed subId, uint96 amount, uint64 nextChargeAt);

    event SubscriptionCancelled(bytes32 indexed subId, address indexed canceller);

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

    event DisputeFiled(bytes32 indexed invoiceId, address indexed filer, bytes32 reasonHash, bytes32 evidenceHash);

    event DisputeResolved(bytes32 indexed invoiceId, uint96 payerAmount, uint96 payeeAmount);

    event FeeCollected(bytes32 indexed invoiceId, uint96 amount, address indexed feeRecipient);

    // === V2 Events ===

    /// @notice Emitted when a metered tab partial dispute is filed (charges after degradation_timestamp are disputed)
    event TabPartialDispute(
        bytes32 indexed tabId,
        address indexed payer,
        uint64 degradationTimestamp,
        uint96 disputedAmount,
        uint96 undisputedAmount
    );

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

    /// @notice Emitted when a bounty submission is rejected (reason required)
    event BountyRejected(
        bytes32 indexed bountyId,
        address indexed submitter,
        address indexed poster,
        string reason,
        uint64 disputeWindowEnds
    );

    /// @notice Emitted when a master key delegates a session key
    event KeyDelegated(
        address indexed masterKey, address indexed sessionKey, uint96 spendingLimit, uint96 dailyLimit, uint64 expires
    );

    /// @notice Emitted when a session key is revoked
    event KeyRevoked(address indexed masterKey, address indexed sessionKey);

    /// @notice Emitted when a session key is nearing expiry (off-chain indexer should warn operator)
    /// @param masterKey The operator wallet that owns the delegation
    /// @param sessionKey The session key about to expire
    /// @param expiresAt Unix timestamp when the delegation expires
    event KeyExpiring(address indexed masterKey, address indexed sessionKey, uint64 expiresAt);

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

    /// @notice V2: Emitted when a dispute bond is posted by the filing party (payer or payee)
    event DisputeBondPosted(bytes32 indexed invoiceId, address indexed filer, uint96 bondAmount);

    /// @notice V2: Emitted when the respondent posts their counter-bond
    event CounterBondPosted(bytes32 indexed invoiceId, address indexed respondent, uint96 bondAmount);

    /// @notice V2: Emitted when filer wins by default (respondent failed to post counter-bond in time)
    event DisputeDefaultWin(
        bytes32 indexed invoiceId, address indexed winner, uint96 bondReturned, uint96 escrowAmount
    );

    /// @notice V2: Emitted when a dispute bond is forfeited (loser's bond goes to protocol fee recipient)
    event DisputeBondForfeited(bytes32 indexed invoiceId, address indexed loser, uint96 bondAmount);

    /// @notice V2: Emitted when a dispute bond is returned to the winner
    event DisputeBondReturned(bytes32 indexed invoiceId, address indexed winner, uint96 bondAmount);

    /// @notice V2: Emitted when the filer increases their bond (signaling higher confidence)
    event BondIncreased(bytes32 indexed invoiceId, address indexed filer, uint96 additionalAmount, uint96 totalBond);

    // === V2 Arbitration Events ===

    /// @notice Emitted when an arbitrator registers and stakes their bond
    event ArbitratorRegistered(address indexed wallet, uint256 bondAmount, string metadataUri);

    /// @notice Emitted when an arbitrator leaves the pool (bond locked in cooldown)
    event ArbitratorRemoved(address indexed wallet, uint64 bondReleasedAt);

    /// @notice Emitted when three arbitrators are proposed for a dispute
    event ArbitratorsProposed(bytes32 indexed invoiceId, address arbitrator0, address arbitrator1, address arbitrator2);

    /// @notice Emitted when a party strikes a proposed arbitrator
    event ArbitratorStruck(bytes32 indexed invoiceId, address indexed striker, uint8 index);

    /// @notice Emitted when a final arbitrator is assigned and the 48h decision window begins
    event ArbitratorAssigned(bytes32 indexed invoiceId, address indexed arbitrator, uint64 deadline);

    /// @notice Emitted when the assigned arbitrator renders a decision with partial award percentages
    event ArbitrationDecisionRendered(
        bytes32 indexed invoiceId, address indexed arbitrator, uint8 payerPercent, uint8 payeePercent
    );

    /// @notice Emitted when a disputed escrow is escalated to the arbitration contract
    event DisputeEscalatedToArbitration(bytes32 indexed invoiceId, address indexed arbitrationContract, uint8 tier);

    // === Admin Events ===

    /// @notice Emitted when contract ownership is transferred
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when a relayer is authorized to act on behalf of users (e.g. postBountyFor)
    event RelayerAuthorized(address indexed relayer);

    /// @notice Emitted when a relayer authorization is revoked
    event RelayerRevoked(address indexed relayer);
}
