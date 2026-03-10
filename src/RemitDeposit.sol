// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRemitDeposit} from "./interfaces/IRemitDeposit.sol";
import {IRemitKeyRegistry} from "./interfaces/IRemitKeyRegistry.sol";
import {RemitTypes} from "./libraries/RemitTypes.sol";
import {RemitErrors} from "./libraries/RemitErrors.sol";
import {RemitEvents} from "./libraries/RemitEvents.sol";
import {RemitKeyValidator} from "./libraries/RemitKeyValidator.sol";

/// @title RemitDeposit
/// @notice Refundable USDC deposits / collateral for AI agent service agreements
/// @dev Fund-holding contract. IMMUTABLE — no proxy, no upgrade path.
///      Depositor locks USDC as collateral with a provider and expiry.
///      Provider returns (full refund) or forfeits (provider keeps funds).
///      Depositor can claim after expiry if neither party has settled.
///      No fee on deposits (collateral is returned or forfeited wholesale).
///      CEI pattern enforced. ReentrancyGuard on all fund-moving functions.
contract RemitDeposit is IRemitDeposit, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Immutable state
    // =========================================================================

    IERC20 public immutable usdc;
    /// @dev V2: Session key registry. address(0) = key management not enabled.
    IRemitKeyRegistry public immutable keyRegistry;

    // =========================================================================
    // Storage
    // =========================================================================

    mapping(bytes32 => RemitTypes.Deposit) private _deposits;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _usdc USDC token address
    /// @param _keyRegistry V2: Session key registry (address(0) to disable)
    constructor(address _usdc, address _keyRegistry) {
        if (_usdc == address(0)) revert RemitErrors.ZeroAddress();
        usdc = IERC20(_usdc);
        keyRegistry = IRemitKeyRegistry(_keyRegistry);
    }

    // =========================================================================
    // External Functions
    // =========================================================================

    /// @inheritdoc IRemitDeposit
    /// @dev CEI: validate → update state → transfer USDC in
    function lockDeposit(bytes32 depositId, address provider, uint96 amount, uint64 expiry) external nonReentrant {
        // --- Checks ---
        if (_deposits[depositId].depositor != address(0)) revert RemitErrors.EscrowAlreadyFunded(depositId);
        if (provider == address(0)) revert RemitErrors.ZeroAddress();
        if (provider == msg.sender) revert RemitErrors.SelfPayment(msg.sender);
        if (amount < RemitTypes.MIN_AMOUNT) revert RemitErrors.BelowMinimum(amount, RemitTypes.MIN_AMOUNT);
        if (expiry <= block.timestamp) revert RemitErrors.InvalidTimeout(expiry);
        // V2: Validate session key delegation
        RemitKeyValidator._validateAndRecord(keyRegistry, msg.sender, amount, RemitTypes.PaymentType.DEPOSIT);

        // --- Effects ---
        _deposits[depositId] = RemitTypes.Deposit({
            depositor: msg.sender,
            amount: amount,
            provider: provider,
            expiry: expiry,
            status: RemitTypes.DepositStatus.Locked
        });

        // --- Interactions ---
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit RemitEvents.DepositLocked(depositId, msg.sender, provider, amount, expiry);
    }

    /// @inheritdoc IRemitDeposit
    /// @dev Only provider. Returns full amount to depositor.
    ///      CEI: validate → set Returned → transfer to depositor
    function returnDeposit(bytes32 depositId) external nonReentrant {
        RemitTypes.Deposit storage dep = _getDeposit(depositId);

        // --- Checks ---
        if (msg.sender != dep.provider) revert RemitErrors.Unauthorized(msg.sender);
        if (dep.status != RemitTypes.DepositStatus.Locked) revert RemitErrors.AlreadyClosed(depositId);

        address depositor = dep.depositor;
        uint96 amount = dep.amount;

        // --- Effects ---
        dep.status = RemitTypes.DepositStatus.Returned;

        // --- Interactions ---
        usdc.safeTransfer(depositor, amount);

        emit RemitEvents.DepositReturned(depositId, depositor, amount);
    }

    /// @inheritdoc IRemitDeposit
    /// @dev Only provider. Provider claims the deposit (collateral forfeited).
    ///      CEI: validate → set Forfeited → transfer to provider
    function forfeitDeposit(bytes32 depositId) external nonReentrant {
        RemitTypes.Deposit storage dep = _getDeposit(depositId);

        // --- Checks ---
        if (msg.sender != dep.provider) revert RemitErrors.Unauthorized(msg.sender);
        if (dep.status != RemitTypes.DepositStatus.Locked) revert RemitErrors.AlreadyClosed(depositId);

        address provider = dep.provider;
        uint96 amount = dep.amount;

        // --- Effects ---
        dep.status = RemitTypes.DepositStatus.Forfeited;

        // --- Interactions ---
        usdc.safeTransfer(provider, amount);

        emit RemitEvents.DepositForfeited(depositId, provider, amount);
    }

    /// @inheritdoc IRemitDeposit
    /// @dev Only depositor, only after expiry. Reclaims funds if provider never settled.
    ///      CEI: validate → set Returned → transfer to depositor
    function claimExpiredDeposit(bytes32 depositId) external nonReentrant {
        RemitTypes.Deposit storage dep = _getDeposit(depositId);

        // --- Checks ---
        if (msg.sender != dep.depositor) revert RemitErrors.Unauthorized(msg.sender);
        if (dep.status != RemitTypes.DepositStatus.Locked) revert RemitErrors.AlreadyClosed(depositId);
        if (block.timestamp <= dep.expiry) revert RemitErrors.InvalidTimeout(dep.expiry);

        address depositor = dep.depositor;
        uint96 amount = dep.amount;

        // --- Effects ---
        dep.status = RemitTypes.DepositStatus.Returned;

        // --- Interactions ---
        usdc.safeTransfer(depositor, amount);

        emit RemitEvents.DepositReturned(depositId, depositor, amount);
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @inheritdoc IRemitDeposit
    function getDeposit(bytes32 depositId) external view returns (RemitTypes.Deposit memory) {
        return _deposits[depositId];
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    function _getDeposit(bytes32 depositId) internal view returns (RemitTypes.Deposit storage) {
        RemitTypes.Deposit storage dep = _deposits[depositId];
        if (dep.depositor == address(0)) revert RemitErrors.DepositNotFound(depositId);
        return dep;
    }
}
