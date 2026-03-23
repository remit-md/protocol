// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRemitRouter} from "./interfaces/IRemitRouter.sol";
import {IRemitFeeCalculator} from "./interfaces/IRemitFeeCalculator.sol";
import {IRemitKeyRegistry} from "./interfaces/IRemitKeyRegistry.sol";
import {IUSDC} from "./interfaces/IUSDC.sol";
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

    /// @dev V3: Authorized relayers (can call *For variants on behalf of users).
    mapping(address => bool) private _authorizedRelayers;

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

    modifier onlyAuthorizedRelayer() {
        if (!_authorizedRelayers[msg.sender]) revert RemitErrors.Unauthorized(msg.sender);
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
    // IRemitRouter — payDirectFor / payPerRequestFor (relayer-submitted)
    // =========================================================================

    /// @inheritdoc IRemitRouter
    /// @dev Relayer submits on behalf of `payer`. The payer must have approved
    ///      this contract for `amount` USDC (typically via EIP-2612 permit).
    ///      Fee is calculated and volume recorded against `payer`, not msg.sender.
    function payDirectFor(address payer, address to, uint96 amount, bytes32 memo)
        external
        override
        nonReentrant
        onlyAuthorizedRelayer
    {
        if (payer == address(0)) revert RemitErrors.ZeroAddress();
        if (to == address(0)) revert RemitErrors.ZeroAddress();
        if (amount == 0) revert RemitErrors.ZeroAmount();
        if (to == payer) revert RemitErrors.SelfPayment(payer);
        if (amount < RemitTypes.MIN_AMOUNT) revert RemitErrors.BelowMinimum(amount, RemitTypes.MIN_AMOUNT);

        // Validate session key delegation against payer (not relayer)
        RemitKeyValidator._validateAndRecord(keyRegistry, payer, amount, RemitTypes.PaymentType.DIRECT);

        // Fee calculated against payer's volume tier
        uint96 fee = IRemitFeeCalculator(feeCalculator).calculateFee(payer, amount);
        uint96 netAmount = amount - fee;

        // Pull from payer (not msg.sender)
        IERC20(usdc).safeTransferFrom(payer, to, netAmount);

        if (fee > 0) {
            IERC20(usdc).safeTransferFrom(payer, feeRecipient, fee);
        }

        // Record volume for payer
        IRemitFeeCalculator(feeCalculator).recordTransaction(payer, amount);

        emit RemitEvents.DirectPayment(payer, to, amount, fee, memo);
    }

    /// @inheritdoc IRemitRouter
    /// @dev Same as payDirectFor but emits PayPerRequest for endpoint tracking.
    function payPerRequestFor(address payer, address to, uint96 amount, string calldata endpoint)
        external
        override
        nonReentrant
        onlyAuthorizedRelayer
    {
        if (payer == address(0)) revert RemitErrors.ZeroAddress();
        if (to == address(0)) revert RemitErrors.ZeroAddress();
        if (amount == 0) revert RemitErrors.ZeroAmount();
        if (to == payer) revert RemitErrors.SelfPayment(payer);
        if (amount < RemitTypes.MIN_AMOUNT) revert RemitErrors.BelowMinimum(amount, RemitTypes.MIN_AMOUNT);

        RemitKeyValidator._validateAndRecord(keyRegistry, payer, amount, RemitTypes.PaymentType.PAY_PER_REQUEST);

        uint96 fee = IRemitFeeCalculator(feeCalculator).calculateFee(payer, amount);
        uint96 netAmount = amount - fee;

        IERC20(usdc).safeTransferFrom(payer, to, netAmount);

        if (fee > 0) {
            IERC20(usdc).safeTransferFrom(payer, feeRecipient, fee);
        }

        IRemitFeeCalculator(feeCalculator).recordTransaction(payer, amount);

        emit RemitEvents.PayPerRequest(payer, to, amount, fee, endpoint);
    }

    // =========================================================================
    // IRemitRouter — settleX402 (EIP-3009 routed x402 payment)
    // =========================================================================

    /// @inheritdoc IRemitRouter
    /// @dev Security invariants:
    ///      - Conservation: from.balance decreases by `amount`; recipient gets `amount - fee`;
    ///        feeRecipient gets `fee`. Total = `amount`. No funds leak.
    ///      - Replay protection: USDC.transferWithAuthorization consumes the nonce; any re-use reverts.
    ///      - Atomic: either the full amount moves (fee split included) or the whole call reverts.
    ///      - Router holds no residual balance: transferWithAuthorization pulls to address(this),
    ///        both outbound transfers execute in the same transaction, no way to exit partially.
    ///      CEI: fee is calculated (view), then transferWithAuthorization (pull), then two transfers (push),
    ///           then volume is recorded. nonReentrant guards against re-entry from USDC callbacks
    ///           (real USDC has none; defense-in-depth for forks/mocks).
    function settleX402(
        address from,
        address recipient,
        uint96 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override nonReentrant {
        if (from == address(0)) revert RemitErrors.ZeroAddress();
        if (recipient == address(0)) revert RemitErrors.ZeroAddress();
        if (from == recipient) revert RemitErrors.SelfPayment(from);
        if (amount == 0) revert RemitErrors.ZeroAmount();
        if (amount < RemitTypes.MIN_AMOUNT) revert RemitErrors.BelowMinimum(amount, RemitTypes.MIN_AMOUNT);
        // V2: Validate session key delegation (no-op if keyRegistry not set or `from` is a master key).
        // `from` is the payer authenticated via EIP-3009 signature, not msg.sender (relayer).
        RemitKeyValidator._validateAndRecord(keyRegistry, from, amount, RemitTypes.PaymentType.PAY_PER_REQUEST);

        // Calculate fee before any transfers (Checks-Effects-Interactions: checks first).
        uint96 fee = IRemitFeeCalculator(feeCalculator).calculateFee(from, amount);
        uint96 netAmount = amount - fee;

        // Pull full amount from payer to Router via EIP-3009 authorization.
        // The agent must have signed: to = address(this) (Router), value = amount.
        // This also consumes the nonce, providing replay protection.
        IUSDC(usdc).transferWithAuthorization(from, address(this), amount, validAfter, validBefore, nonce, v, r, s);

        // Forward net amount to the final recipient.
        IERC20(usdc).safeTransfer(recipient, netAmount);

        // Forward fee to protocol fee wallet (skip zero-fee for gas efficiency).
        if (fee > 0) {
            IERC20(usdc).safeTransfer(feeRecipient, fee);
        }

        // Record volume for cliff calculation (done after transfers — no re-entrancy risk here).
        IRemitFeeCalculator(feeCalculator).recordTransaction(from, amount);

        emit RemitEvents.X402Payment(from, recipient, amount, fee, nonce);
    }

    // =========================================================================
    // IRemitRouter — setters (onlyOwner)
    // =========================================================================

    /// @inheritdoc IRemitRouter
    function setEscrow(address newEscrow) external override onlyOwner {
        if (newEscrow == address(0)) revert RemitErrors.ZeroAddress();
        escrow = newEscrow;
        emit RemitEvents.ConfigUpdated("escrow", newEscrow);
    }

    /// @inheritdoc IRemitRouter
    function setTab(address newTab) external override onlyOwner {
        if (newTab == address(0)) revert RemitErrors.ZeroAddress();
        tab = newTab;
        emit RemitEvents.ConfigUpdated("tab", newTab);
    }

    /// @inheritdoc IRemitRouter
    function setStream(address newStream) external override onlyOwner {
        if (newStream == address(0)) revert RemitErrors.ZeroAddress();
        stream = newStream;
        emit RemitEvents.ConfigUpdated("stream", newStream);
    }

    /// @inheritdoc IRemitRouter
    function setBounty(address newBounty) external override onlyOwner {
        if (newBounty == address(0)) revert RemitErrors.ZeroAddress();
        bounty = newBounty;
        emit RemitEvents.ConfigUpdated("bounty", newBounty);
    }

    /// @inheritdoc IRemitRouter
    function setDeposit(address newDeposit) external override onlyOwner {
        if (newDeposit == address(0)) revert RemitErrors.ZeroAddress();
        deposit = newDeposit;
        emit RemitEvents.ConfigUpdated("deposit", newDeposit);
    }

    /// @inheritdoc IRemitRouter
    function setFeeCalculator(address newFeeCalculator) external override onlyOwner {
        if (newFeeCalculator == address(0)) revert RemitErrors.ZeroAddress();
        feeCalculator = newFeeCalculator;
        emit RemitEvents.ConfigUpdated("feeCalculator", newFeeCalculator);
    }

    /// @inheritdoc IRemitRouter
    function setFeeRecipient(address newFeeRecipient) external override onlyOwner {
        if (newFeeRecipient == address(0)) revert RemitErrors.ZeroAddress();
        feeRecipient = newFeeRecipient;
        emit RemitEvents.ConfigUpdated("feeRecipient", newFeeRecipient);
    }

    /// @notice Set the KeyRegistry contract (V2: session key delegation). address(0) disables key management.
    /// @param newKeyRegistry The RemitKeyRegistry contract address
    function setKeyRegistry(address newKeyRegistry) external onlyOwner {
        if (newKeyRegistry == address(0)) revert RemitErrors.ZeroAddress();
        keyRegistry = IRemitKeyRegistry(newKeyRegistry);
        emit RemitEvents.ConfigUpdated("keyRegistry", newKeyRegistry);
    }

    // =========================================================================
    // Relayer authorization (V3)
    // =========================================================================

    /// @notice Authorize a relayer to call *For variants on behalf of users.
    /// @param relayer Address to authorize
    function authorizeRelayer(address relayer) external {
        if (msg.sender != protocolAdmin) revert RemitErrors.Unauthorized(msg.sender);
        if (relayer == address(0)) revert RemitErrors.ZeroAddress();
        _authorizedRelayers[relayer] = true;
        emit RemitEvents.RelayerAuthorized(relayer);
    }

    /// @notice Revoke a relayer's authorization.
    /// @param relayer Address to revoke
    function revokeRelayer(address relayer) external {
        if (msg.sender != protocolAdmin) revert RemitErrors.Unauthorized(msg.sender);
        _authorizedRelayers[relayer] = false;
        emit RemitEvents.RelayerRevoked(relayer);
    }

    /// @notice Check if an address is an authorized relayer.
    /// @param relayer Address to check
    /// @return True if the relayer is authorized
    function isAuthorizedRelayer(address relayer) external view returns (bool) {
        return _authorizedRelayers[relayer];
    }

    // =========================================================================
    // Admin helpers
    // =========================================================================

    /// @notice Transfer ownership to a new address.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert RemitErrors.ZeroAddress();
        address previous = _owner;
        _owner = newOwner;
        emit RemitEvents.OwnershipTransferred(previous, newOwner);
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
    // Storage gap (reserve 49 slots for future upgrades)
    // =========================================================================

    // solhint-disable-next-line var-name-mixedcase
    uint256[49] private __gap;
}
