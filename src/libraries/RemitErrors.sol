// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RemitErrors
/// @notice Shared custom errors for all Remit contracts
library RemitErrors {
    // Escrow
    error InsufficientBalance(uint256 required, uint256 available);
    error BelowMinimum(uint256 amount, uint256 minimum);
    error EscrowAlreadyFunded(bytes32 invoiceId);
    error EscrowNotFound(bytes32 invoiceId);
    error EscrowFrozen(bytes32 invoiceId);
    error SelfPayment(address wallet);

    // Authorization
    error Unauthorized(address caller);
    error InvalidSignature();

    // Tab
    error TabDepleted(bytes32 tabId);
    error TabNotFound(bytes32 tabId);

    // Stream
    error StreamNotFound(bytes32 streamId);
    error AlreadyClosed(bytes32 id);

    // Bounty
    error BountyExpired(bytes32 bountyId);
    error BountyClaimed(bytes32 bountyId);
    error BountyMaxAttempts(bytes32 bountyId);

    // Deposit
    error DepositNotFound(bytes32 depositId);

    // Milestone
    error MilestoneEscrowBlocked(bytes32 invoiceId);

    // Cancellation
    error CancelBlockedClaimStart(bytes32 invoiceId);
    error CancelBlockedEvidence(bytes32 invoiceId);

    // General
    error ZeroAddress();
    error ZeroAmount();
    error InvalidTimeout(uint64 timeout);

    // V2: Escrow timeout floors
    error TimeoutBelowFloor(uint64 timeout, uint64 floor);

    // V2: Session key / delegation
    error DelegationExpired(address sessionKey);
    error DelegationLimitExceeded(address sessionKey, uint256 amount, uint256 limit);

    // V2: Streaming balance depletion
    error StreamTerminated(bytes32 streamId);

    // V2: Bounty
    error BountyRejectionNoReason(bytes32 bountyId);

}
