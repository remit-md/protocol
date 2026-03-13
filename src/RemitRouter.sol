// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRemitRouter} from "./interfaces/IRemitRouter.sol";
import {IRemitFeeCalculator} from "./interfaces/IRemitFeeCalculator.sol";
import {IRemitKeyRegistry} from "./interfaces/IRemitKeyRegistry.sol";
import {RemitTypes} from "./libraries/RemitTypes.sol";
import {RemitErrors} from "./libraries/RemitErrors.sol";
import {RemitEvents} from "./libraries/RemitEvents.sol";
import {RemitKeyValidator} from "./libraries/RemitKeyValidator.sol";

/// @title RemitRouter
/// @notice Entry point for AI agents. Stores current contract addresses and provides
///         payDirect — a convenience function for simple payments without escrow.
/// @dev UPGRADEABLE via UUPS proxy. Does NOT hold funds — all funds flow through
///      the individual protocol contracts (Escrow, Tab, Stream, Bounty, Deposit).
///      Updating contract addresses here doesn't affect in-flight payments (those
///      are locked in the individual contracts until settlement).
///
///      ReentrancyGuard is included as defense-in-depth even though the router
///      holds no funds.
contract RemitRouter is IRemitRouter, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using RemitKeyValidator for IRemitKeyRegistry;

    // =========================================================================
    // Storage (proxy-safe layout)
    // =========================================================================

    /// @dev Guard to prevent double-initialization (constructor sets to true).
    bool private _initialized;

    /// @dev Contract owner (can upgrade and update contract addresses).
    address private _owner;

    // Contract registry
    address public override escrow;
    address public override tab;
    address public override stream;
    address public override bounty;
    address public override deposit;
    address public override feeCalculator;
    address public override usdc;
    address public override protocolAdmin;
    address public override feeRecipient;

    /// @dev V2: Session key registry. address(0) = key management not enabled.
    IRemitKeyRegistry public keyRegistry;

    // =========================================================================
    // Constructor — disables direct initialization of implementation contract
    // =========================================================================

    constructor() {
        _initialized = true;
    }

    // =========================================================================
    // Initializer
    // =========================================================================

    /// @notice Configuration for initializing the router.
    struct RouterConfig {
        address owner;
        address usdc;
        address feeCalculator;
        address protocolAdmin;
        address feeRecipient;
    }

    /// @notice Initialize the router (proxy deployment only).
    /// @param cfg Configuration struct with all required addresses.
    function initialize(RouterConfig calldata cfg) external {
        if (_initialized) revert RemitErrors.Unauthorized(msg.sender);
        if (cfg.owner == address(0)) revert RemitErrors.ZeroAddress();
        if (cfg.usdc == address(0)) revert RemitErrors.ZeroAddress();
        if (cfg.feeCalculator == address(0)) revert RemitErrors.ZeroAddress();
        if (cfg.protocolAdmin == address(0)) revert RemitErrors.ZeroAddress();
        if (cfg.feeRecipient == address(0)) revert RemitErrors.ZeroAddress();
        _initialized = true;
        _owner = cfg.owner;
        usdc = cfg.usdc;
        feeCalculator = cfg.feeCalculator;
        protocolAdmin = cfg.protocolAdmin;
        feeRecipient = cfg.feeRecipient;
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyOwner() {
        if (msg.sender != _owner) revert RemitErrors.Unauthorized(msg.sender);
        _;
    }

    // =========================================================================
    // IRemitRouter — payDirect
    // =========================================================================

    /// @inheritdoc IRemitRouter
    /// @dev Caller must approve this contract to spend `amount` USDC beforehand.
    ///      CEI: fee is calculated (view), then transfers happen, then volume is recorded.
    function payDirect(address to, uint96 amount, bytes32 memo) external override nonReentrant {
        if (to == address(0)) revert RemitErrors.ZeroAddress();
        if (amount == 0) revert RemitErrors.ZeroAmount();
        if (to == msg.sender) revert RemitErrors.SelfPayment(msg.sender);
        if (amount < RemitTypes.MIN_AMOUNT) revert RemitErrors.BelowMinimum(amount, RemitTypes.MIN_AMOUNT);

        // V2: Validate session key delegation and record spend
        RemitKeyValidator._validateAndRecord(keyRegistry, msg.sender, amount, RemitTypes.PaymentType.DIRECT);

        uint96 fee = IRemitFeeCalculator(feeCalculator).calculateFee(msg.sender, amount);
        uint96 netAmount = amount - fee;

        // Transfer net amount to recipient.
        IERC20(usdc).safeTransferFrom(msg.sender, to, netAmount);

        // Transfer fee to protocol (skip zero-fee transfers for gas efficiency).
        if (fee > 0) {
            IERC20(usdc).safeTransferFrom(msg.sender, feeRecipient, fee);
        }

        // Record volume after successful transfers.
        IRemitFeeCalculator(feeCalculator).recordTransaction(msg.sender, amount);

        emit RemitEvents.DirectPayment(msg.sender, to, amount, fee, memo);
    }

    /// @inheritdoc IRemitRouter
    /// @dev Same payment logic as payDirect but emits PayPerRequest for Ponder indexing of endpoint calls.
    ///      Caller must approve this contract to spend `amount` USDC beforehand.
    function payPerRequest(address to, uint96 amount, string calldata endpoint) external override nonReentrant {
        if (to == address(0)) revert RemitErrors.ZeroAddress();
        if (amount == 0) revert RemitErrors.ZeroAmount();
        if (to == msg.sender) revert RemitErrors.SelfPayment(msg.sender);
        if (amount < RemitTypes.MIN_AMOUNT) revert RemitErrors.BelowMinimum(amount, RemitTypes.MIN_AMOUNT);

        // V2: Validate session key delegation and record spend
        RemitKeyValidator._validateAndRecord(keyRegistry, msg.sender, amount, RemitTypes.PaymentType.PAY_PER_REQUEST);

        uint96 fee = IRemitFeeCalculator(feeCalculator).calculateFee(msg.sender, amount);
        uint96 netAmount = amount - fee;

        IERC20(usdc).safeTransferFrom(msg.sender, to, netAmount);

        if (fee > 0) {
            IERC20(usdc).safeTransferFrom(msg.sender, feeRecipient, fee);
        }

        IRemitFeeCalculator(feeCalculator).recordTransaction(msg.sender, amount);

        emit RemitEvents.PayPerRequest(msg.sender, to, amount, fee, endpoint);
    }

    // =========================================================================
    // IRemitRouter — setters (onlyOwner)
    // =========================================================================

    /// @inheritdoc IRemitRouter
    function setEscrow(address newEscrow) external override onlyOwner {
        if (newEscrow == address(0)) revert RemitErrors.ZeroAddress();
        escrow = newEscrow;
    }

    /// @inheritdoc IRemitRouter
    function setTab(address newTab) external override onlyOwner {
        if (newTab == address(0)) revert RemitErrors.ZeroAddress();
        tab = newTab;
    }

    /// @inheritdoc IRemitRouter
    function setStream(address newStream) external override onlyOwner {
        if (newStream == address(0)) revert RemitErrors.ZeroAddress();
        stream = newStream;
    }

    /// @inheritdoc IRemitRouter
    function setBounty(address newBounty) external override onlyOwner {
        if (newBounty == address(0)) revert RemitErrors.ZeroAddress();
        bounty = newBounty;
    }

    /// @inheritdoc IRemitRouter
    function setDeposit(address newDeposit) external override onlyOwner {
        if (newDeposit == address(0)) revert RemitErrors.ZeroAddress();
        deposit = newDeposit;
    }

    /// @inheritdoc IRemitRouter
    function setFeeCalculator(address newFeeCalculator) external override onlyOwner {
        if (newFeeCalculator == address(0)) revert RemitErrors.ZeroAddress();
        feeCalculator = newFeeCalculator;
    }

    /// @inheritdoc IRemitRouter
    function setFeeRecipient(address newFeeRecipient) external override onlyOwner {
        if (newFeeRecipient == address(0)) revert RemitErrors.ZeroAddress();
        feeRecipient = newFeeRecipient;
    }

    /// @notice Set the KeyRegistry contract (V2: session key delegation). address(0) disables key management.
    /// @param newKeyRegistry The RemitKeyRegistry contract address
    function setKeyRegistry(address newKeyRegistry) external onlyOwner {
        keyRegistry = IRemitKeyRegistry(newKeyRegistry);
    }

    // =========================================================================
    // Admin helpers
    // =========================================================================

    /// @notice Transfer ownership to a new address.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert RemitErrors.ZeroAddress();
        _owner = newOwner;
    }

    /// @notice Get the current owner.
    function owner() external view returns (address) {
        return _owner;
    }

    // =========================================================================
    // UUPSUpgradeable
    // =========================================================================

    /// @dev Only the owner can authorize an upgrade.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // =========================================================================
    // Storage gap (reserve 50 slots for future upgrades)
    // =========================================================================

    // solhint-disable-next-line var-name-mixedcase
    uint256[50] private __gap;
}
