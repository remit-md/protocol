// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IRemitEscrow} from "./interfaces/IRemitEscrow.sol";
import {IRemitFeeCalculator} from "./interfaces/IRemitFeeCalculator.sol";
import {IRemitKeyRegistry} from "./interfaces/IRemitKeyRegistry.sol";
import {RemitTypes} from "./libraries/RemitTypes.sol";
import {RemitErrors} from "./libraries/RemitErrors.sol";
import {RemitEvents} from "./libraries/RemitEvents.sol";
import {RemitKeyValidator} from "./libraries/RemitKeyValidator.sol";

/// @title RemitEscrow
/// @notice Task-based escrow payments for AI agents using USDC
/// @dev Fund-holding contract. IMMUTABLE — no proxy, no upgrade path.
///      CEI pattern strictly enforced. ReentrancyGuard on all fund-moving functions.
contract RemitEscrow is IRemitEscrow, ReentrancyGuard, Pausable, EIP712 {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @dev EIP-712 typehash for mutual cancel signatures
    bytes32 public constant MUTUAL_CANCEL_TYPEHASH =
        keccak256("MutualCancel(bytes32 invoiceId,address payer,address payee)");

    // =========================================================================
    // Immutable state (set once in constructor, never changed)
    // =========================================================================

    IERC20 public immutable usdc;
    IRemitFeeCalculator public immutable feeCalculator;
    address public immutable protocolAdmin;
    address public immutable feeRecipient;
    /// @dev V2: Session key registry. address(0) = key management not enabled.
    IRemitKeyRegistry public immutable keyRegistry;

    // =========================================================================
    // Relayer authorization
    // =========================================================================

    mapping(address => bool) private _authorizedRelayers;

    modifier onlyAuthorizedRelayer() {
        if (!_authorizedRelayers[msg.sender]) revert RemitErrors.Unauthorized(msg.sender);
        _;
    }

    // =========================================================================
    // Storage
    // =========================================================================

    mapping(bytes32 => RemitTypes.Escrow) private _escrows;
    mapping(bytes32 => RemitTypes.Milestone[]) private _milestones;
    mapping(bytes32 => RemitTypes.Split[]) private _splits;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _usdc USDC token address
    /// @param _feeCalculator Fee calculator contract address
    /// @param _protocolAdmin Admin address
    /// @param _feeRecipient Address that receives protocol fees
    /// @param _keyRegistry V2: Session key registry (address(0) to disable)
    constructor(
        address _usdc,
        address _feeCalculator,
        address _protocolAdmin,
        address _feeRecipient,
        address _keyRegistry
    ) EIP712("RemitEscrow", "1") {
        if (_usdc == address(0)) revert RemitErrors.ZeroAddress();
        if (_feeCalculator == address(0)) revert RemitErrors.ZeroAddress();
        if (_protocolAdmin == address(0)) revert RemitErrors.ZeroAddress();
        if (_feeRecipient == address(0)) revert RemitErrors.ZeroAddress();

        usdc = IERC20(_usdc);
        feeCalculator = IRemitFeeCalculator(_feeCalculator);
        protocolAdmin = _protocolAdmin;
        feeRecipient = _feeRecipient;
        keyRegistry = IRemitKeyRegistry(_keyRegistry);
    }

    // =========================================================================
    // External Functions
    // =========================================================================

    /// @inheritdoc IRemitEscrow
    /// @dev CEI: validate → compute fee → update state → transfer USDC
    function createEscrow(
        bytes32 invoiceId,
        address payee,
        uint96 amount,
        uint64 timeout,
        RemitTypes.Milestone[] calldata milestones,
        RemitTypes.Split[] calldata splits
    ) external nonReentrant whenNotPaused {
        // --- Checks ---
        if (_escrows[invoiceId].payer != address(0)) revert RemitErrors.EscrowAlreadyFunded(invoiceId);
        if (payee == address(0)) revert RemitErrors.ZeroAddress();
        if (payee == msg.sender) revert RemitErrors.SelfPayment(msg.sender);
        if (amount < RemitTypes.MIN_AMOUNT) revert RemitErrors.BelowMinimum(amount, RemitTypes.MIN_AMOUNT);
        if (timeout <= block.timestamp) revert RemitErrors.InvalidTimeout(timeout);
        // V2: Validate session key delegation (no-op if keyRegistry not set or caller is master key)
        RemitKeyValidator._validateAndRecord(keyRegistry, msg.sender, amount, RemitTypes.PaymentType.ESCROW);
        // V2: Enforce minimum timeout based on escrowed amount
        _enforceTimeoutFloor(amount, timeout);

        // Validate milestone amounts sum to total
        if (milestones.length > 0) {
            uint96 milestoneSum;
            for (uint256 i; i < milestones.length; ++i) {
                milestoneSum += milestones[i].amount;
                // V2: Enforce per-milestone timeout floor
                _enforceTimeoutFloor(milestones[i].amount, milestones[i].timeout);
            }
            if (milestoneSum != amount) revert RemitErrors.BelowMinimum(milestoneSum, amount);
        }

        // Validate split amounts sum to total
        if (splits.length > 0) {
            uint96 splitSum;
            for (uint256 i; i < splits.length; ++i) {
                if (splits[i].payee == address(0)) revert RemitErrors.ZeroAddress();
                splitSum += splits[i].amount;
            }
            if (splitSum != amount) revert RemitErrors.BelowMinimum(splitSum, amount);
        }

        uint96 fee = feeCalculator.calculateFee(msg.sender, amount);

        // --- Effects ---
        _escrows[invoiceId] = RemitTypes.Escrow({
            payer: msg.sender,
            amount: amount,
            payee: payee,
            feeAmount: fee,
            timeout: timeout,
            createdAt: uint64(block.timestamp),
            status: RemitTypes.EscrowStatus.Funded,
            claimStarted: false,
            evidenceSubmitted: false,
            milestoneReleased: 0,
            evidenceHash: bytes32(0),
            milestoneCount: uint8(milestones.length),
            splitCount: uint8(splits.length),
            feesPaid: 0
        });

        // Store milestones
        for (uint256 i; i < milestones.length; ++i) {
            _milestones[invoiceId].push(milestones[i]);
        }

        // Store splits
        for (uint256 i; i < splits.length; ++i) {
            _splits[invoiceId].push(splits[i]);
        }

        // --- Interactions ---
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit RemitEvents.EscrowFunded(invoiceId, msg.sender, payee, amount, timeout);
    }

    /// @inheritdoc IRemitEscrow
    function claimStart(bytes32 invoiceId) external {
        RemitTypes.Escrow storage escrow = _getEscrow(invoiceId);

        if (escrow.payee != msg.sender && escrow.payer != msg.sender) revert RemitErrors.Unauthorized(msg.sender);
        if (escrow.status != RemitTypes.EscrowStatus.Funded) revert RemitErrors.EscrowFrozen(invoiceId);

        // --- Effects ---
        escrow.claimStarted = true;
        escrow.status = RemitTypes.EscrowStatus.Active;

        emit RemitEvents.ClaimStartConfirmed(invoiceId, msg.sender, uint64(block.timestamp));
    }

    // =========================================================================
    // For variants (relayer-submitted on behalf of users)
    // =========================================================================

    /// @notice Create an escrow on behalf of `payer` (relayer-submitted).
    ///         Payer must have approved USDC to this contract (typically via EIP-2612 permit).
    function createEscrowFor(
        address payer,
        bytes32 invoiceId,
        address payee,
        uint96 amount,
        uint64 timeout,
        RemitTypes.Milestone[] calldata milestones,
        RemitTypes.Split[] calldata splits
    ) external nonReentrant whenNotPaused onlyAuthorizedRelayer {
        if (payer == address(0)) revert RemitErrors.ZeroAddress();
        if (_escrows[invoiceId].payer != address(0)) revert RemitErrors.EscrowAlreadyFunded(invoiceId);
        if (payee == address(0)) revert RemitErrors.ZeroAddress();
        if (payee == payer) revert RemitErrors.SelfPayment(payer);
        if (amount < RemitTypes.MIN_AMOUNT) revert RemitErrors.BelowMinimum(amount, RemitTypes.MIN_AMOUNT);
        if (timeout <= block.timestamp) revert RemitErrors.InvalidTimeout(timeout);
        RemitKeyValidator._validateAndRecord(keyRegistry, payer, amount, RemitTypes.PaymentType.ESCROW);
        _enforceTimeoutFloor(amount, timeout);

        if (milestones.length > 0) {
            uint96 milestoneSum;
            for (uint256 i; i < milestones.length; ++i) {
                milestoneSum += milestones[i].amount;
                _enforceTimeoutFloor(milestones[i].amount, milestones[i].timeout);
            }
            if (milestoneSum != amount) revert RemitErrors.BelowMinimum(milestoneSum, amount);
        }

        if (splits.length > 0) {
            uint96 splitSum;
            for (uint256 i; i < splits.length; ++i) {
                if (splits[i].payee == address(0)) revert RemitErrors.ZeroAddress();
                splitSum += splits[i].amount;
            }
            if (splitSum != amount) revert RemitErrors.BelowMinimum(splitSum, amount);
        }

        uint96 fee = feeCalculator.calculateFee(payer, amount);

        _escrows[invoiceId] = RemitTypes.Escrow({
            payer: payer,
            amount: amount,
            payee: payee,
            feeAmount: fee,
            timeout: timeout,
            createdAt: uint64(block.timestamp),
            status: RemitTypes.EscrowStatus.Funded,
            claimStarted: false,
            evidenceSubmitted: false,
            milestoneReleased: 0,
            evidenceHash: bytes32(0),
            milestoneCount: uint8(milestones.length),
            splitCount: uint8(splits.length),
            feesPaid: 0
        });

        for (uint256 i; i < milestones.length; ++i) {
            _milestones[invoiceId].push(milestones[i]);
        }
        for (uint256 i; i < splits.length; ++i) {
            _splits[invoiceId].push(splits[i]);
        }

        // Pull from payer (not msg.sender)
        usdc.safeTransferFrom(payer, address(this), amount);

        emit RemitEvents.EscrowFunded(invoiceId, payer, payee, amount, timeout);
    }

    /// @notice Release escrow on behalf of `payer` (relayer-submitted).
    function releaseEscrowFor(address payer, bytes32 invoiceId) external nonReentrant onlyAuthorizedRelayer {
        RemitTypes.Escrow storage escrow = _getEscrow(invoiceId);

        if (escrow.payer != payer) revert RemitErrors.Unauthorized(payer);
        if (escrow.status != RemitTypes.EscrowStatus.Active) revert RemitErrors.EscrowFrozen(invoiceId);
        if (escrow.milestoneCount > 0) revert RemitErrors.MilestoneEscrowBlocked(invoiceId);

        uint96 amount = escrow.amount;
        uint96 fee = escrow.feeAmount;
        address payee = escrow.payee;
        uint8 splitCount = escrow.splitCount;

        escrow.status = RemitTypes.EscrowStatus.Completed;
        feeCalculator.recordTransaction(payer, amount);

        if (splitCount > 0) {
            RemitTypes.Split[] storage splits = _splits[invoiceId];
            uint96 feeAccumulated;
            for (uint256 i; i < splitCount; ++i) {
                uint96 splitFee;
                if (i < splitCount - 1) {
                    splitFee = uint96((uint256(fee) * splits[i].amount) / amount);
                    feeAccumulated += splitFee;
                } else {
                    splitFee = fee - feeAccumulated;
                }
                uint96 splitNet = splits[i].amount - splitFee;
                usdc.safeTransfer(splits[i].payee, splitNet);
            }
            usdc.safeTransfer(feeRecipient, fee);
        } else {
            uint96 net = amount - fee;
            usdc.safeTransfer(payee, net);
            usdc.safeTransfer(feeRecipient, fee);
        }

        emit RemitEvents.EscrowReleased(invoiceId, payee, amount - fee, fee);
        emit RemitEvents.FeeCollected(invoiceId, fee, feeRecipient);
    }

    /// @notice Cancel escrow on behalf of `payer` (relayer-submitted).
    function cancelEscrowFor(address payer, bytes32 invoiceId) external nonReentrant onlyAuthorizedRelayer {
        RemitTypes.Escrow storage escrow = _getEscrow(invoiceId);

        if (escrow.payer != payer) revert RemitErrors.Unauthorized(payer);
        if (escrow.status != RemitTypes.EscrowStatus.Funded) revert RemitErrors.EscrowFrozen(invoiceId);
        if (escrow.claimStarted) revert RemitErrors.CancelBlockedClaimStart(invoiceId);
        if (escrow.evidenceSubmitted) revert RemitErrors.CancelBlockedEvidence(invoiceId);

        uint96 amount = escrow.amount;
        uint96 cancelFee = uint96((uint256(amount) * RemitTypes.CANCEL_FEE_BPS) / 10_000);
        uint96 refund = amount - cancelFee;

        escrow.status = RemitTypes.EscrowStatus.Cancelled;

        usdc.safeTransfer(payer, refund);
        usdc.safeTransfer(feeRecipient, cancelFee);

        emit RemitEvents.EscrowCancelled(invoiceId, payer, false, cancelFee);
        emit RemitEvents.FeeCollected(invoiceId, cancelFee, feeRecipient);
    }

    /// @notice Claim start on behalf of `caller` (relayer-submitted).
    ///         Caller must be either payer or payee of the escrow.
    function claimStartFor(address caller, bytes32 invoiceId) external onlyAuthorizedRelayer {
        RemitTypes.Escrow storage escrow = _getEscrow(invoiceId);

        if (escrow.payee != caller && escrow.payer != caller) revert RemitErrors.Unauthorized(caller);
        if (escrow.status != RemitTypes.EscrowStatus.Funded) revert RemitErrors.EscrowFrozen(invoiceId);

        escrow.claimStarted = true;
        escrow.status = RemitTypes.EscrowStatus.Active;

        emit RemitEvents.ClaimStartConfirmed(invoiceId, caller, uint64(block.timestamp));
    }

    // =========================================================================
    // Evidence & Release
    // =========================================================================

    /// @inheritdoc IRemitEscrow
    function submitEvidence(bytes32 invoiceId, uint8 milestoneIndex, bytes32 evidenceHash) external {
        RemitTypes.Escrow storage escrow = _getEscrow(invoiceId);

        if (escrow.payee != msg.sender) revert RemitErrors.Unauthorized(msg.sender);
        if (escrow.status != RemitTypes.EscrowStatus.Active && escrow.status != RemitTypes.EscrowStatus.Funded) {
            revert RemitErrors.EscrowFrozen(invoiceId);
        }

        // Validate milestone index if milestone escrow
        if (escrow.milestoneCount > 0 && milestoneIndex >= escrow.milestoneCount) {
            revert RemitErrors.EscrowNotFound(invoiceId);
        }

        // --- Effects ---
        escrow.evidenceSubmitted = true;
        escrow.evidenceHash = evidenceHash;

        // Update milestone status if applicable
        if (escrow.milestoneCount > 0) {
            _milestones[invoiceId][milestoneIndex].status = RemitTypes.MilestoneStatus.Submitted;
            _milestones[invoiceId][milestoneIndex].evidenceHash = evidenceHash;
        }

        emit RemitEvents.EvidenceSubmitted(invoiceId, milestoneIndex, evidenceHash);
    }

    /// @inheritdoc IRemitEscrow
    /// @dev CEI: validate → update state → transfer USDC
    function releaseEscrow(bytes32 invoiceId) external nonReentrant {
        RemitTypes.Escrow storage escrow = _getEscrow(invoiceId);

        if (escrow.payer != msg.sender) revert RemitErrors.Unauthorized(msg.sender);
        if (escrow.status != RemitTypes.EscrowStatus.Active) revert RemitErrors.EscrowFrozen(invoiceId);
        if (escrow.milestoneCount > 0) revert RemitErrors.MilestoneEscrowBlocked(invoiceId);

        uint96 amount = escrow.amount;
        uint96 fee = escrow.feeAmount;
        address payer = escrow.payer;
        address payee = escrow.payee;
        uint8 splitCount = escrow.splitCount;

        // --- Effects (before interactions) ---
        escrow.status = RemitTypes.EscrowStatus.Completed;

        // Record volume for fee tier tracking
        feeCalculator.recordTransaction(payer, amount);

        // --- Interactions ---
        if (splitCount > 0) {
            // Distribute to splits proportionally minus fee.
            // Last split's fee is computed as remainder to prevent rounding dust
            // from causing total outflow > escrowed amount.
            RemitTypes.Split[] storage splits = _splits[invoiceId];
            uint96 feeAccumulated;
            for (uint256 i; i < splitCount; ++i) {
                uint96 splitFee;
                if (i < splitCount - 1) {
                    splitFee = uint96((uint256(fee) * splits[i].amount) / amount);
                    feeAccumulated += splitFee;
                } else {
                    // Last split gets the remainder to guarantee sum(splitFees) == fee
                    splitFee = fee - feeAccumulated;
                }
                uint96 splitNet = splits[i].amount - splitFee;
                usdc.safeTransfer(splits[i].payee, splitNet);
            }
            usdc.safeTransfer(feeRecipient, fee);
        } else {
            uint96 net = amount - fee;
            usdc.safeTransfer(payee, net);
            usdc.safeTransfer(feeRecipient, fee);
        }

        emit RemitEvents.EscrowReleased(invoiceId, payee, amount - fee, fee);
        emit RemitEvents.FeeCollected(invoiceId, fee, feeRecipient);
    }

    /// @inheritdoc IRemitEscrow
    /// @dev CEI: validate → update milestone state → transfer USDC
    function releaseMilestone(bytes32 invoiceId, uint8 milestoneIndex) external nonReentrant {
        RemitTypes.Escrow storage escrow = _getEscrow(invoiceId);

        if (escrow.payer != msg.sender) revert RemitErrors.Unauthorized(msg.sender);
        if (escrow.status != RemitTypes.EscrowStatus.Active) revert RemitErrors.EscrowFrozen(invoiceId);
        if (milestoneIndex >= escrow.milestoneCount) revert RemitErrors.EscrowNotFound(invoiceId);

        RemitTypes.Milestone storage milestone = _milestones[invoiceId][milestoneIndex];
        if (milestone.status != RemitTypes.MilestoneStatus.Submitted) revert RemitErrors.EscrowFrozen(invoiceId);

        uint96 milestoneAmount = milestone.amount;
        address payee = escrow.payee;

        // --- Effects ---
        milestone.status = RemitTypes.MilestoneStatus.Released;
        escrow.milestoneReleased += milestoneAmount;

        // Check if all milestones are released
        bool allReleased = true;
        for (uint256 i; i < escrow.milestoneCount; ++i) {
            if (_milestones[invoiceId][i].status != RemitTypes.MilestoneStatus.Released) {
                allReleased = false;
                break;
            }
        }

        // Fee: proportional per milestone, last milestone gets remainder to avoid dust
        uint96 fee;
        if (allReleased) {
            fee = escrow.feeAmount - escrow.feesPaid;
        } else {
            fee = uint96((uint256(escrow.feeAmount) * milestoneAmount) / escrow.amount);
        }
        escrow.feesPaid += fee;
        uint96 net = milestoneAmount - fee;

        if (allReleased) {
            escrow.status = RemitTypes.EscrowStatus.Completed;
            feeCalculator.recordTransaction(escrow.payer, escrow.amount);
        }

        // --- Interactions ---
        usdc.safeTransfer(payee, net);
        usdc.safeTransfer(feeRecipient, fee);

        emit RemitEvents.MilestoneReleased(invoiceId, milestoneIndex, milestoneAmount);
        emit RemitEvents.FeeCollected(invoiceId, fee, feeRecipient);
    }

    /// @inheritdoc IRemitEscrow
    /// @dev 0.1% cancellation fee. Only callable pre-claimStart.
    function cancelEscrow(bytes32 invoiceId) external nonReentrant {
        RemitTypes.Escrow storage escrow = _getEscrow(invoiceId);

        if (escrow.payer != msg.sender) revert RemitErrors.Unauthorized(msg.sender);
        if (escrow.status != RemitTypes.EscrowStatus.Funded) revert RemitErrors.EscrowFrozen(invoiceId);
        if (escrow.claimStarted) revert RemitErrors.CancelBlockedClaimStart(invoiceId);
        if (escrow.evidenceSubmitted) revert RemitErrors.CancelBlockedEvidence(invoiceId);

        uint96 amount = escrow.amount;
        address payer = escrow.payer;

        // 0.1% cancel fee
        uint96 cancelFee = uint96((uint256(amount) * RemitTypes.CANCEL_FEE_BPS) / 10_000);
        uint96 refund = amount - cancelFee;

        // --- Effects ---
        escrow.status = RemitTypes.EscrowStatus.Cancelled;

        // --- Interactions ---
        usdc.safeTransfer(payer, refund);
        usdc.safeTransfer(feeRecipient, cancelFee);

        emit RemitEvents.EscrowCancelled(invoiceId, payer, false, cancelFee);
        emit RemitEvents.FeeCollected(invoiceId, cancelFee, feeRecipient);
    }

    /// @inheritdoc IRemitEscrow
    /// @dev No fee on mutual cancel. Both EIP-712 sigs required.
    function mutualCancel(bytes32 invoiceId, bytes calldata payerSig, bytes calldata payeeSig) external nonReentrant {
        RemitTypes.Escrow storage escrow = _getEscrow(invoiceId);

        if (escrow.status != RemitTypes.EscrowStatus.Funded && escrow.status != RemitTypes.EscrowStatus.Active) {
            revert RemitErrors.EscrowFrozen(invoiceId);
        }
        if (escrow.evidenceSubmitted) revert RemitErrors.CancelBlockedEvidence(invoiceId);

        // Verify both EIP-712 signatures
        bytes32 structHash = keccak256(abi.encode(MUTUAL_CANCEL_TYPEHASH, invoiceId, escrow.payer, escrow.payee));
        bytes32 digest = _hashTypedDataV4(structHash);

        address payerSigner = ECDSA.recover(digest, payerSig);
        address payeeSigner = ECDSA.recover(digest, payeeSig);

        if (payerSigner != escrow.payer) revert RemitErrors.InvalidSignature();
        if (payeeSigner != escrow.payee) revert RemitErrors.InvalidSignature();

        uint96 amount = escrow.amount;
        address payer = escrow.payer;

        // --- Effects ---
        escrow.status = RemitTypes.EscrowStatus.Cancelled;

        // --- Interactions ---
        usdc.safeTransfer(payer, amount);

        emit RemitEvents.EscrowCancelled(invoiceId, payer, true, 0);
    }

    /// @inheritdoc IRemitEscrow
    function claimTimeout(bytes32 invoiceId) external nonReentrant {
        RemitTypes.Escrow storage escrow = _getEscrow(invoiceId);

        if (escrow.payer != msg.sender) revert RemitErrors.Unauthorized(msg.sender);
        if (block.timestamp <= escrow.timeout) revert RemitErrors.InvalidTimeout(escrow.timeout);
        if (escrow.evidenceSubmitted) revert RemitErrors.CancelBlockedEvidence(invoiceId);
        if (escrow.status != RemitTypes.EscrowStatus.Funded && escrow.status != RemitTypes.EscrowStatus.Active) {
            revert RemitErrors.EscrowFrozen(invoiceId);
        }

        uint96 amount = escrow.amount;
        address payer = escrow.payer;

        // --- Effects ---
        escrow.status = RemitTypes.EscrowStatus.TimedOut;

        // --- Interactions ---
        usdc.safeTransfer(payer, amount);

        emit RemitEvents.EscrowTimeout(invoiceId, payer, amount);
    }

    /// @inheritdoc IRemitEscrow
    /// @dev Evidence must have been submitted for payee to claim on timeout
    function claimTimeoutPayee(bytes32 invoiceId) external nonReentrant {
        RemitTypes.Escrow storage escrow = _getEscrow(invoiceId);

        if (escrow.payee != msg.sender) revert RemitErrors.Unauthorized(msg.sender);
        if (block.timestamp <= escrow.timeout) revert RemitErrors.InvalidTimeout(escrow.timeout);
        if (!escrow.evidenceSubmitted) revert RemitErrors.CancelBlockedEvidence(invoiceId);
        if (escrow.status == RemitTypes.EscrowStatus.Completed) revert RemitErrors.EscrowFrozen(invoiceId);
        if (escrow.status != RemitTypes.EscrowStatus.Funded && escrow.status != RemitTypes.EscrowStatus.Active) {
            revert RemitErrors.EscrowFrozen(invoiceId);
        }

        uint96 amount = escrow.amount;
        uint96 fee = escrow.feeAmount;
        uint96 released = escrow.milestoneReleased;
        address payer = escrow.payer;
        address payee = escrow.payee;

        // Subtract already-released milestone amounts (raw amounts including fees)
        uint96 remaining = amount - released;
        // Proportional fee for the remaining portion
        uint96 remainingFee = uint96((uint256(fee) * remaining) / amount);
        uint96 payeeAmount = remaining - remainingFee;

        // --- Effects ---
        escrow.status = RemitTypes.EscrowStatus.Completed;
        feeCalculator.recordTransaction(payer, amount);

        // --- Interactions ---
        usdc.safeTransfer(payee, payeeAmount);
        usdc.safeTransfer(feeRecipient, remainingFee);

        emit RemitEvents.EscrowReleased(invoiceId, payee, payeeAmount, remainingFee);
        emit RemitEvents.FeeCollected(invoiceId, remainingFee, feeRecipient);
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @inheritdoc IRemitEscrow
    function getEscrow(bytes32 invoiceId) external view returns (RemitTypes.Escrow memory) {
        return _escrows[invoiceId];
    }

    /// @inheritdoc IRemitEscrow
    function getMilestones(bytes32 invoiceId) external view returns (RemitTypes.Milestone[] memory) {
        return _milestones[invoiceId];
    }

    /// @inheritdoc IRemitEscrow
    function getSplits(bytes32 invoiceId) external view returns (RemitTypes.Split[] memory) {
        return _splits[invoiceId];
    }

    /// @notice Returns the EIP-712 domain separator for this contract.
    /// @dev Exposes OZ EIP712's internal _domainSeparatorV4() for test helpers and off-chain signing.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /// @notice Authorize a relayer to call *For variants on behalf of users.
    function authorizeRelayer(address relayer) external {
        if (msg.sender != protocolAdmin) revert RemitErrors.Unauthorized(msg.sender);
        if (relayer == address(0)) revert RemitErrors.ZeroAddress();
        _authorizedRelayers[relayer] = true;
        emit RemitEvents.RelayerAuthorized(relayer);
    }

    /// @notice Revoke a relayer's authorization.
    function revokeRelayer(address relayer) external {
        if (msg.sender != protocolAdmin) revert RemitErrors.Unauthorized(msg.sender);
        _authorizedRelayers[relayer] = false;
        emit RemitEvents.RelayerRevoked(relayer);
    }

    /// @notice Check if an address is an authorized relayer.
    function isAuthorizedRelayer(address relayer) external view returns (bool) {
        return _authorizedRelayers[relayer];
    }

    /// @notice Pause all escrow operations (admin only)
    function pause() external {
        if (msg.sender != protocolAdmin) revert RemitErrors.Unauthorized(msg.sender);
        _pause();
    }

    /// @notice Unpause escrow operations (admin only)
    function unpause() external {
        if (msg.sender != protocolAdmin) revert RemitErrors.Unauthorized(msg.sender);
        _unpause();
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @dev Revert if escrow does not exist (payer == address(0) means not created)
    function _getEscrow(bytes32 invoiceId) internal view returns (RemitTypes.Escrow storage) {
        RemitTypes.Escrow storage escrow = _escrows[invoiceId];
        if (escrow.payer == address(0)) revert RemitErrors.EscrowNotFound(invoiceId);
        return escrow;
    }

    /// @dev Returns the minimum timeout duration (in seconds) required for a given USDC amount.
    function _timeoutFloor(uint256 amount) internal pure returns (uint64) {
        if (amount < RemitTypes.TIMEOUT_TIER_10) return RemitTypes.TIMEOUT_FLOOR_UNDER_10;
        if (amount < RemitTypes.TIMEOUT_TIER_100) return RemitTypes.TIMEOUT_FLOOR_10_TO_100;
        if (amount < RemitTypes.TIMEOUT_TIER_1K) return RemitTypes.TIMEOUT_FLOOR_100_TO_1K;
        return RemitTypes.TIMEOUT_FLOOR_OVER_1K;
    }

    /// @dev Revert with TimeoutBelowFloor if the given unix-timestamp timeout is below the
    ///      minimum required duration from now for the given amount.
    function _enforceTimeoutFloor(uint256 amount, uint64 timeout) internal view {
        uint64 floor = _timeoutFloor(amount);
        uint64 minTimeout = uint64(block.timestamp) + floor;
        if (timeout < minTimeout) {
            revert RemitErrors.TimeoutBelowFloor(timeout, minTimeout);
        }
    }
}
