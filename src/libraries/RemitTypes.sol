// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RemitTypes
/// @notice Shared type definitions for all Remit contracts
library RemitTypes {
    /// @notice Escrow status
    enum EscrowStatus {
        Funded, // 0: payer has funded, payee hasn't started
        Active, // 1: payee called claimStart
        Completed, // 2: funds released
        Disputed, // 3: dispute filed, frozen
        Cancelled, // 4: mutual or unilateral cancel
        TimedOut // 5: timeout expired
    }

    /// @notice Milestone status
    enum MilestoneStatus {
        Pending, // 0: not yet worked on
        Submitted, // 1: evidence submitted
        Released, // 2: funds released for this milestone
        Disputed // 3: dispute on this milestone
    }

    /// @notice Tab status
    enum TabStatus {
        Open, // 0: active, charges allowed
        Depleted, // 1: funds exhausted
        Closed, // 2: closed by either party
        Expired // 3: past expiry time
    }

    /// @notice Stream status
    enum StreamStatus {
        Active, // 0: streaming
        Closed // 1: stopped
    }

    /// @notice Bounty status
    enum BountyStatus {
        Open, // 0: accepting submissions
        Claimed, // 1: submission received, under review
        Awarded, // 2: winner paid
        Expired // 3: deadline passed
    }

    /// @notice Deposit status
    enum DepositStatus {
        Locked, // 0: funds locked
        Returned, // 1: returned to depositor
        Forfeited // 2: forfeited to provider
    }

    /// @notice Core escrow struct (packed for gas efficiency)
    /// @dev amount uses uint96 (max ~79B USDC, sufficient) to pack with address
    struct Escrow {
        address payer;
        uint96 amount; // USDC amount (6 decimals)
        address payee;
        uint96 feeAmount; // pre-calculated fee
        uint64 timeout; // unix timestamp of expiry
        uint64 createdAt;
        EscrowStatus status;
        bool claimStarted;
        bool evidenceSubmitted;
        bytes32 evidenceHash;
        uint8 milestoneCount;
        uint8 splitCount;
    }

    /// @notice Milestone within an escrow
    struct Milestone {
        uint96 amount;
        uint64 timeout; // per-milestone timeout
        MilestoneStatus status;
        bytes32 evidenceHash;
    }

    /// @notice Payment split (auto-distribute on release)
    struct Split {
        address payee;
        uint96 amount;
    }

    /// @notice Metered tab (off-chain payment channel)
    struct Tab {
        address payer;
        uint96 limit; // max USDC authorized
        address provider;
        uint96 totalCharged; // cumulative charges
        uint64 perUnit; // cost per unit (USDC, 6 decimals)
        uint64 expiry;
        TabStatus status;
    }

    /// @notice Payment stream
    struct Stream {
        address payer;
        uint96 maxTotal; // safety cap
        address payee;
        uint96 withdrawn; // total withdrawn so far
        uint64 ratePerSecond; // USDC per second (6 decimals)
        uint64 startedAt;
        uint64 closedAt; // 0 if still active
        StreamStatus status;
    }

    /// @notice Bounty
    struct Bounty {
        address poster;
        uint96 amount;
        uint64 deadline;
        uint64 createdAt;
        uint8 maxAttempts;
        uint8 attemptCount;
        address winner;
        BountyStatus status;
        bytes32 taskHash;
        uint96 submissionBond;
    }

    /// @notice Deposit
    struct Deposit {
        address depositor;
        uint96 amount;
        address provider;
        uint64 expiry;
        DepositStatus status;
    }

    /// @notice Fee tiers
    uint96 constant FEE_RATE_BPS = 100; // 1% = 100 basis points
    uint96 constant FEE_RATE_PREFERRED_BPS = 50; // 0.5% = 50 basis points
    uint96 constant FEE_THRESHOLD = 10_000e6; // $10,000 in USDC (6 decimals)
    uint96 constant MIN_AMOUNT = 10_000; // $0.01 in USDC (6 decimals)
    uint96 constant CANCEL_FEE_BPS = 10; // 0.1% = 10 basis points
}
