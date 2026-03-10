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

    /// @notice Either party files a dispute, posting a bond. Replaces admin-only freezeEscrow.
    /// @param invoiceId The escrow's invoice ID
    /// @param evidenceHash keccak256 hash of dispute evidence
    /// @dev Bond = max(5% of amount, $0.50) × escalating multiplier based on filer's dispute history.
    ///      Caller must be payer or payee and have approved bond amount. Emits EscrowDisputed + DisputeBondPosted.
    function fileDispute(bytes32 invoiceId, bytes32 evidenceHash) external;

    /// @notice Respondent (non-filer) posts a counter-bond within 72 hours of dispute filing.
    /// @param invoiceId The escrow's invoice ID
    /// @dev Counter-bond equals filer's current bond. Emits CounterBondPosted.
    function postCounterBond(bytes32 invoiceId) external;

    /// @notice Filer claims default win if respondent fails to post counter-bond within 72 hours.
    /// @param invoiceId The escrow's invoice ID
    /// @dev Only callable by filer after counter-bond deadline. Filer wins dispute + gets bond back.
    ///      Emits DisputeBondReturned + DisputeDefaultWin.
    function claimDefaultWin(bytes32 invoiceId) external;

    /// @notice Filer increases their bond before counter-bond is posted (signaling mechanism).
    /// @param invoiceId The escrow's invoice ID
    /// @param additionalAmount Extra USDC to add to the filer's bond
    /// @dev Only callable by filer before counter-bond deadline and before respondent posts. Emits BondIncreased.
    function increaseBond(bytes32 invoiceId, uint96 additionalAmount) external;

    /// @notice Protocol resolves dispute by splitting funds and handling bond forfeiture.
    /// @param invoiceId The escrow's invoice ID
    /// @param payerAmount Amount returned to payer
    /// @param payeeAmount Amount sent to payee
    /// @param payeeWins If true: payee wins (payee's bond returned, payer's bond forfeited). If false: payer wins.
    /// @dev Only callable by protocol admin. payerAmount + payeeAmount must equal escrowed amount. Emits DisputeResolved.
    function resolveDispute(bytes32 invoiceId, uint96 payerAmount, uint96 payeeAmount, bool payeeWins) external;

    /// @notice Escalate a stalled dispute to the arbitration contract.
    /// @param invoiceId The escrow's invoice ID
    /// @dev Permissionless: callable by anyone once both bonds are posted AND counter-bond
    ///      deadline has passed (72h from filing) without admin resolution.
    ///      Calls RemitArbitration.routeDispute(). Reverts if arbitration not enabled (address(0)).
    function escalateToArbitration(bytes32 invoiceId) external;

    /// @notice Arbitration contract settles a dispute and triggers fund distribution.
    /// @param invoiceId The escrow's invoice ID
    /// @param payerPercent Percentage of escrowed funds returned to payer (0–100)
    /// @param payeePercent Percentage of escrowed funds released to payee (0–100)
    /// @param arbitrator Address of the arbitrator who rendered the decision (receives fee)
    /// @param arbitratorFee USDC fee taken from the loser's bond and paid to arbitrator
    /// @dev Only callable by the authorized arbitrationContract. payerPercent + payeePercent = 100.
    ///      Distributes escrow funds and handles bond forfeiture. Emits DisputeResolved.
    function resolveDisputeArbitration(
        bytes32 invoiceId,
        uint8 payerPercent,
        uint8 payeePercent,
        address arbitrator,
        uint96 arbitratorFee
    ) external;

    // === View Functions ===

    /// @notice Get escrow details
    function getEscrow(bytes32 invoiceId) external view returns (RemitTypes.Escrow memory);

    /// @notice Get dispute bond details (empty if no active dispute)
    function getDisputeBond(bytes32 invoiceId) external view returns (RemitTypes.DisputeBond memory);

    /// @notice Get milestone details
    function getMilestones(bytes32 invoiceId) external view returns (RemitTypes.Milestone[] memory);

    /// @notice Get split details
    function getSplits(bytes32 invoiceId) external view returns (RemitTypes.Split[] memory);
}
