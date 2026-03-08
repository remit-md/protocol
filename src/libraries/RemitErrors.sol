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
    error EscrowExpired(bytes32 invoiceId);
    error EscrowFrozen(bytes32 invoiceId);
    error SelfPayment(address wallet);

    // Authorization
    error Unauthorized(address caller);
    error InvalidSignature();
    error NonceReused(uint256 nonce);

    // Tab
    error TabDepleted(bytes32 tabId);
    error TabExpired(bytes32 tabId);
    error TabNotFound(bytes32 tabId);

    // Stream
    error StreamNotFound(bytes32 streamId);
    error AlreadyClosed(bytes32 id);
    error RateExceedsCap(uint256 rate, uint256 cap);

    // Bounty
    error BountyExpired(bytes32 bountyId);
    error BountyClaimed(bytes32 bountyId);
    error BountyMaxAttempts(bytes32 bountyId);

    // Deposit
    error DepositNotFound(bytes32 depositId);

    // Dispute
    error DisputeWindowClosed(bytes32 invoiceId);
    error DisputeAlreadyFiled(bytes32 invoiceId);

    // Cancellation
    error CancelBlockedClaimStart(bytes32 invoiceId);
    error CancelBlockedEvidence(bytes32 invoiceId);

    // General
    error ZeroAddress();
    error ZeroAmount();
    error InvalidTimeout(uint64 timeout);
}
