// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RemitTypes} from "../libraries/RemitTypes.sol";

/// @title IRemitEscrow
/// @notice Escrow contract for task-based payments between agents
/// @dev Fund-holding contract. IMMUTABLE (no proxy, no upgrade).
interface IRemitEscrow {
    /// @notice Create and fund an escrow for a task
    /// @param invoiceId Unique invoice identifier (keccak256 of invoice JSON)
    /// @param payee Address of the payee agent
    /// @param amount USDC amount (6 decimals) — must be >= MIN_AMOUNT
    /// @param timeout Unix timestamp when escrow expires
    /// @param milestones Array of milestone definitions (empty for single-release)
    /// @param splits Array of payment splits (empty for single payee)
    /// @dev Caller must have approved USDC transfer. Emits EscrowFunded.
    function createEscrow(
        bytes32 invoiceId,
        address payee,
        uint96 amount,
        uint64 timeout,
        RemitTypes.Milestone[] calldata milestones,
        RemitTypes.Split[] calldata splits
    ) external;

    /// @notice Payee signals they have begun work. Blocks payer unilateral cancel.
    /// @param invoiceId The escrow's invoice ID
    /// @dev Only callable by payee. Irreversible. Emits ClaimStartConfirmed.
    function claimStart(bytes32 invoiceId) external;

    /// @notice Payee submits evidence of work completion
    /// @param invoiceId The escrow's invoice ID
    /// @param milestoneIndex Milestone index (0 for whole-escrow evidence)
    /// @param evidenceHash keccak256 hash of evidence data
    /// @dev Only callable by payee. Emits EvidenceSubmitted.
    function submitEvidence(bytes32 invoiceId, uint8 milestoneIndex, bytes32 evidenceHash) external;

    /// @notice Payer releases full escrow amount to payee
    /// @param invoiceId The escrow's invoice ID
    /// @dev Only callable by payer. Fee deducted. Emits EscrowReleased.
    function releaseEscrow(bytes32 invoiceId) external;

    /// @notice Payer releases a single milestone
    /// @param invoiceId The escrow's invoice ID
    /// @param milestoneIndex Index of the milestone to release
    /// @dev Only callable by payer. Emits MilestoneReleased.
    function releaseMilestone(bytes32 invoiceId, uint8 milestoneIndex) external;

    /// @notice Payer cancels escrow (only before CLAIM_START, no evidence)
    /// @param invoiceId The escrow's invoice ID
    /// @dev 0.1% cancellation fee. Emits EscrowCancelled.
    function cancelEscrow(bytes32 invoiceId) external;

    /// @notice Both parties agree to cancel
    /// @param invoiceId The escrow's invoice ID
    /// @param payerSig EIP-712 signature from payer
    /// @param payeeSig EIP-712 signature from payee
    /// @dev No fee on mutual cancel. Emits EscrowCancelled.
    function mutualCancel(bytes32 invoiceId, bytes calldata payerSig, bytes calldata payeeSig) external;

    /// @notice Payer reclaims funds after timeout (no evidence submitted)
    /// @param invoiceId The escrow's invoice ID
    /// @dev Only if: timeout passed AND no evidence. Emits EscrowTimeout.
    function claimTimeout(bytes32 invoiceId) external;

    /// @notice Payee claims funds after timeout (evidence submitted but not verified)
    /// @param invoiceId The escrow's invoice ID
    /// @dev Only if: timeout passed AND evidence submitted AND not released. Emits EscrowReleased.
    function claimTimeoutPayee(bytes32 invoiceId) external;

    /// @notice Protocol freezes escrow due to dispute
    /// @param invoiceId The escrow's invoice ID
    /// @dev Only callable by protocol admin. Emits EscrowDisputed.
    function freezeEscrow(bytes32 invoiceId) external;

    /// @notice Protocol resolves dispute by splitting funds
    /// @param invoiceId The escrow's invoice ID
    /// @param payerAmount Amount returned to payer
    /// @param payeeAmount Amount sent to payee
    /// @dev Only callable by protocol admin. payerAmount + payeeAmount must equal escrowed amount. Emits DisputeResolved.
    function resolveDispute(bytes32 invoiceId, uint96 payerAmount, uint96 payeeAmount) external;

    // === View Functions ===

    /// @notice Get escrow details
    function getEscrow(bytes32 invoiceId) external view returns (RemitTypes.Escrow memory);

    /// @notice Get milestone details
    function getMilestones(bytes32 invoiceId) external view returns (RemitTypes.Milestone[] memory);

    /// @notice Get split details
    function getSplits(bytes32 invoiceId) external view returns (RemitTypes.Split[] memory);
}
