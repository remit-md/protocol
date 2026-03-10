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
    error DelegationNotFound(address sessionKey);

    // V2: Streaming balance depletion
    error StreamTerminated(bytes32 streamId);

    // V2: Bounty
    error BountyRejectionNoReason(bytes32 bountyId);

    // V2: Dispute bonds
    error DisputeBondInsufficient(uint256 provided, uint256 required);

    // V2: Arbitration
    error ArbitratorNotFound(address wallet);
    error ArbitratorAlreadyRegistered(address wallet);
    error ArbitratorBondInsufficient(uint256 provided, uint256 required);
    error ArbitrationCaseNotFound(bytes32 invoiceId);
    error ArbitrationCaseAlreadyExists(bytes32 invoiceId);
    error StrikeAlreadyCast(bytes32 invoiceId);
    error InvalidPercentageSum(uint8 payerPercent, uint8 payeePercent);
    error ArbitrationDeadlinePassed(bytes32 invoiceId);
    error PoolTooSmall(uint256 available, uint256 required);
    error EscalationNotReady(uint64 deadline);
    error NotArbitrationContract(address caller);
    error ArbitrationCooldownNotMet(uint64 releaseAt);
    error ArbitratorNotAssigned(bytes32 invoiceId, address caller);
    error ArbitrationAlreadyDecided(bytes32 invoiceId);
}
