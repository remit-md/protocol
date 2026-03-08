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
}
