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

    /// @notice Poster rejects a submission
    /// @param bountyId The bounty ID
    /// @param submitter Address of the submitter being rejected
    /// @dev Bond NOT returned on rejection (anti-spam). Re-opens for new submissions.
    function rejectSubmission(bytes32 bountyId, address submitter) external;

    /// @notice Reclaim bounty after deadline with no valid submission
    /// @param bountyId The bounty ID
    /// @dev Only poster, only after deadline. Emits BountyExpired.
    function reclaimBounty(bytes32 bountyId) external;

    // === View Functions ===

    function getBounty(bytes32 bountyId) external view returns (RemitTypes.Bounty memory);
}
