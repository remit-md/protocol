// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRemitBounty} from "./interfaces/IRemitBounty.sol";
import {IRemitFeeCalculator} from "./interfaces/IRemitFeeCalculator.sol";
import {RemitTypes} from "./libraries/RemitTypes.sol";
import {RemitErrors} from "./libraries/RemitErrors.sol";
import {RemitEvents} from "./libraries/RemitEvents.sol";

/// @title RemitBounty
/// @notice Open bounty system for AI agent task completion
/// @dev Fund-holding contract. IMMUTABLE — no proxy, no upgrade path.
///      Poster locks USDC. Submitter bonds and transitions status to Claimed.
///      Poster awards (bond returned to winner) or rejects (bond forfeited to poster, anti-spam).
///      Only one active submission at a time. CEI enforced throughout.
contract RemitBounty is IRemitBounty, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Immutable state
    // =========================================================================

    IERC20 public immutable usdc;
    IRemitFeeCalculator public immutable feeCalculator;
    address public immutable feeRecipient;

    // =========================================================================
    // Storage
    // =========================================================================

    mapping(bytes32 => RemitTypes.Bounty) private _bounties;
    /// @dev bountyId → submitter → evidenceHash (non-zero iff submitted)
    mapping(bytes32 => mapping(address => bytes32)) private _submissions;
    /// @dev bountyId → currently pending submitter (set when status = Claimed, cleared otherwise)
    mapping(bytes32 => address) private _pendingSubmitter;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _usdc USDC token address
    /// @param _feeCalculator Fee calculator contract address
    /// @param _feeRecipient Address that receives protocol fees
    constructor(address _usdc, address _feeCalculator, address _feeRecipient) {
        if (_usdc == address(0)) revert RemitErrors.ZeroAddress();
        if (_feeCalculator == address(0)) revert RemitErrors.ZeroAddress();
        if (_feeRecipient == address(0)) revert RemitErrors.ZeroAddress();

        usdc = IERC20(_usdc);
        feeCalculator = IRemitFeeCalculator(_feeCalculator);
        feeRecipient = _feeRecipient;
    }

    // =========================================================================
    // External Functions
    // =========================================================================

    /// @inheritdoc IRemitBounty
    /// @dev CEI: validate → update state → transfer USDC in
    function postBounty(
        bytes32 bountyId,
        uint96 amount,
        uint64 deadline,
        bytes32 taskHash,
        uint96 submissionBond,
        uint8 maxAttempts
    ) external nonReentrant {
        // --- Checks ---
        if (_bounties[bountyId].poster != address(0)) revert RemitErrors.EscrowAlreadyFunded(bountyId);
        if (amount < RemitTypes.MIN_AMOUNT) revert RemitErrors.BelowMinimum(amount, RemitTypes.MIN_AMOUNT);
        if (deadline <= block.timestamp) revert RemitErrors.InvalidTimeout(deadline);
        if (taskHash == bytes32(0)) revert RemitErrors.ZeroAmount();

        // --- Effects ---
        _bounties[bountyId] = RemitTypes.Bounty({
            poster: msg.sender,
            amount: amount,
            deadline: deadline,
            createdAt: uint64(block.timestamp),
            maxAttempts: maxAttempts,
            attemptCount: 0,
            winner: address(0),
            status: RemitTypes.BountyStatus.Open,
            taskHash: taskHash,
            submissionBond: submissionBond
        });

        // --- Interactions ---
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit RemitEvents.BountyPosted(bountyId, msg.sender, amount, deadline, taskHash);
    }

    /// @inheritdoc IRemitBounty
    /// @dev Requires status == Open (one submission at a time). Bonds USDC.
    ///      CEI: validate → update state → transfer bond in
    function submitBounty(bytes32 bountyId, bytes32 evidenceHash) external nonReentrant {
        RemitTypes.Bounty storage bounty = _getBounty(bountyId);

        // --- Checks ---
        if (bounty.status != RemitTypes.BountyStatus.Open) revert RemitErrors.BountyClaimed(bountyId);
        if (block.timestamp > bounty.deadline) revert RemitErrors.BountyExpired(bountyId);
        if (bounty.maxAttempts != 0 && bounty.attemptCount >= bounty.maxAttempts) {
            revert RemitErrors.BountyMaxAttempts(bountyId);
        }
        if (evidenceHash == bytes32(0)) revert RemitErrors.ZeroAmount();
        if (msg.sender == bounty.poster) revert RemitErrors.SelfPayment(msg.sender);

        // --- Effects ---
        _submissions[bountyId][msg.sender] = evidenceHash;
        _pendingSubmitter[bountyId] = msg.sender;
        bounty.attemptCount += 1;
        bounty.status = RemitTypes.BountyStatus.Claimed;

        // --- Interactions ---
        if (bounty.submissionBond > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), bounty.submissionBond);
        }

        emit RemitEvents.BountyClaimed(bountyId, msg.sender, evidenceHash);
    }

    /// @inheritdoc IRemitBounty
    /// @dev Only poster. `winner` must be the pending submitter with a valid submission.
    ///      CEI: validate → set state → distribute bounty + bond
    function awardBounty(bytes32 bountyId, address winner) external nonReentrant {
        RemitTypes.Bounty storage bounty = _getBounty(bountyId);

        // --- Checks ---
        if (msg.sender != bounty.poster) revert RemitErrors.Unauthorized(msg.sender);
        if (bounty.status != RemitTypes.BountyStatus.Claimed) revert RemitErrors.AlreadyClosed(bountyId);
        if (winner != _pendingSubmitter[bountyId]) revert RemitErrors.Unauthorized(winner);
        if (_submissions[bountyId][winner] == bytes32(0)) revert RemitErrors.Unauthorized(winner);

        uint96 fee = feeCalculator.calculateFee(bounty.poster, bounty.amount);
        if (fee > bounty.amount) fee = bounty.amount; // safety cap
        uint96 winnerGets = bounty.amount - fee;
        uint96 bond = bounty.submissionBond;

        // --- Effects ---
        bounty.status = RemitTypes.BountyStatus.Awarded;
        bounty.winner = winner;
        delete _pendingSubmitter[bountyId];

        // --- Interactions ---
        usdc.safeTransfer(winner, winnerGets);
        if (bond > 0) usdc.safeTransfer(winner, bond); // return submission bond
        if (fee > 0) usdc.safeTransfer(feeRecipient, fee);

        emit RemitEvents.BountyAwarded(bountyId, winner, winnerGets, fee);
    }

    /// @inheritdoc IRemitBounty
    /// @dev Only poster. Bond NOT returned (anti-spam); bond transferred to poster.
    ///      Bounty re-opens for new submissions.
    ///      CEI: validate → clear state → transfer bond to poster
    function rejectSubmission(bytes32 bountyId, address submitter) external nonReentrant {
        RemitTypes.Bounty storage bounty = _getBounty(bountyId);

        // --- Checks ---
        if (msg.sender != bounty.poster) revert RemitErrors.Unauthorized(msg.sender);
        if (bounty.status != RemitTypes.BountyStatus.Claimed) revert RemitErrors.AlreadyClosed(bountyId);
        if (submitter != _pendingSubmitter[bountyId]) revert RemitErrors.Unauthorized(submitter);

        uint96 bond = bounty.submissionBond;

        // --- Effects ---
        delete _submissions[bountyId][submitter];
        delete _pendingSubmitter[bountyId];
        bounty.status = RemitTypes.BountyStatus.Open;

        // --- Interactions ---
        // Bond forfeited: poster receives it as anti-spam compensation
        if (bond > 0) usdc.safeTransfer(bounty.poster, bond);
    }

    /// @inheritdoc IRemitBounty
    /// @dev Only poster, only after deadline, not if already awarded.
    ///      If Claimed at deadline, returns bond to the pending submitter (edge-case fairness).
    ///      CEI: validate → snapshot state → set Expired → distribute
    function reclaimBounty(bytes32 bountyId) external nonReentrant {
        RemitTypes.Bounty storage bounty = _getBounty(bountyId);

        // --- Checks ---
        if (msg.sender != bounty.poster) revert RemitErrors.Unauthorized(msg.sender);
        if (block.timestamp <= bounty.deadline) revert RemitErrors.InvalidTimeout(bounty.deadline);
        if (bounty.status == RemitTypes.BountyStatus.Awarded) revert RemitErrors.AlreadyClosed(bountyId);
        if (bounty.status == RemitTypes.BountyStatus.Expired) revert RemitErrors.AlreadyClosed(bountyId);

        // Snapshot before state changes
        bool wasClaimed = bounty.status == RemitTypes.BountyStatus.Claimed;
        address pendingSubmitter = _pendingSubmitter[bountyId]; // address(0) if Open
        uint96 bond = (wasClaimed && bounty.submissionBond > 0) ? bounty.submissionBond : 0;

        // --- Effects ---
        bounty.status = RemitTypes.BountyStatus.Expired;
        if (wasClaimed) delete _pendingSubmitter[bountyId];

        // --- Interactions ---
        usdc.safeTransfer(bounty.poster, bounty.amount);
        // Return bond to pending submitter — they submitted in good faith before deadline
        if (bond > 0) usdc.safeTransfer(pendingSubmitter, bond);

        emit RemitEvents.BountyExpired(bountyId, bounty.amount);
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @inheritdoc IRemitBounty
    function getBounty(bytes32 bountyId) external view returns (RemitTypes.Bounty memory) {
        return _bounties[bountyId];
    }

    /// @notice Get currently pending submitter (non-zero when status is Claimed)
    function getPendingSubmitter(bytes32 bountyId) external view returns (address) {
        return _pendingSubmitter[bountyId];
    }

    /// @notice Get evidence hash for a submitter (non-zero if they have submitted)
    function getSubmission(bytes32 bountyId, address submitter) external view returns (bytes32) {
        return _submissions[bountyId][submitter];
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    function _getBounty(bytes32 bountyId) internal view returns (RemitTypes.Bounty storage) {
        RemitTypes.Bounty storage bounty = _bounties[bountyId];
        if (bounty.poster == address(0)) revert RemitErrors.EscrowNotFound(bountyId);
        return bounty;
    }
}
