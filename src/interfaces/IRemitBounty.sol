// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RemitTypes} from "../libraries/RemitTypes.sol";

/// @title IRemitBounty
/// @notice Open bounties — first valid submission wins
/// @dev Fund-holding. IMMUTABLE.
interface IRemitBounty {
    /// @notice Post a bounty by locking USDC
    /// @param bountyId Unique bounty identifier
    /// @param amount Bounty reward amount (6 decimals)
    /// @param deadline Unix timestamp deadline
    /// @param taskHash keccak256 of task description
    /// @param submissionBond Bond required per submission (anti-spam)
    /// @param maxAttempts Max submissions allowed (0 = unlimited)
    /// @dev Caller must have approved amount USDC. Emits BountyPosted.
    function postBounty(
        bytes32 bountyId,
        uint96 amount,
        uint64 deadline,
        bytes32 taskHash,
        uint96 submissionBond,
        uint8 maxAttempts
    ) external;

    /// @notice Submit a solution to claim the bounty
    /// @param bountyId The bounty ID
    /// @param evidenceHash keccak256 of solution/evidence
    /// @dev Requires submissionBond. Emits BountyClaimed.
    function submitBounty(bytes32 bountyId, bytes32 evidenceHash) external;

    /// @notice Poster awards bounty to a submitter
    /// @param bountyId The bounty ID
    /// @param winner Address of the winning submitter
    /// @dev Only poster. Bond returned to winner. Emits BountyAwarded.
    function awardBounty(bytes32 bountyId, address winner) external;

    /// @notice Poster rejects a submission with a mandatory reason
    /// @param bountyId The bounty ID
    /// @param submitter Address of the submitter being rejected
    /// @param reason Non-empty rejection reason (reverts with BountyRejectionNoReason if empty)
    /// @dev V2: opens a 24-hour dispute window. Bond held until window closes or dispute resolved.
    ///      Emits BountyRejected. Status stays Claimed during the window.
    function rejectSubmission(bytes32 bountyId, address submitter, string calldata reason) external;

    /// @notice Submitter disputes a rejection within the 24-hour window
    /// @param bountyId The bounty ID
    /// @dev Only callable by the rejected submitter within BOUNTY_DISPUTE_WINDOW seconds of rejection.
    ///      Sets status to Disputed; funds frozen until admin resolves.
    function disputeRejection(bytes32 bountyId) external;

    /// @notice Finalize a rejection after the 24-hour dispute window expires without a dispute
    /// @param bountyId The bounty ID
    /// @dev Callable by anyone after window expires. Forfeits bond to poster, re-opens bounty.
    function finalizeRejection(bytes32 bountyId) external;

    /// @notice Admin resolves a disputed rejection
    /// @param bountyId The bounty ID
    /// @param submitterWins If true: submitter awarded bounty + bond returned. If false: bond forfeited, bounty re-opens.
    /// @dev Only protocolAdmin.
    function resolveRejectionDispute(bytes32 bountyId, bool submitterWins) external;

    /// @notice Reclaim bounty after deadline with no valid submission
    /// @param bountyId The bounty ID
    /// @dev Only poster, only after deadline. Emits BountyExpired.
    function reclaimBounty(bytes32 bountyId) external;

    // === View Functions ===

    function getBounty(bytes32 bountyId) external view returns (RemitTypes.Bounty memory);
}
