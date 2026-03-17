// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IRemitTab} from "./interfaces/IRemitTab.sol";
import {IRemitFeeCalculator} from "./interfaces/IRemitFeeCalculator.sol";
import {IRemitKeyRegistry} from "./interfaces/IRemitKeyRegistry.sol";
import {RemitTypes} from "./libraries/RemitTypes.sol";
import {RemitErrors} from "./libraries/RemitErrors.sol";
import {RemitEvents} from "./libraries/RemitEvents.sol";
import {RemitKeyValidator} from "./libraries/RemitKeyValidator.sol";

/// @title RemitTab
/// @notice Metered payment tabs for AI agent services (off-chain payment channels)
/// @dev Fund-holding contract. IMMUTABLE — no proxy, no upgrade path.
///      Payer locks USDC once (openTab). Provider charges off-chain (zero gas per call).
///      At settlement, provider submits signed cumulative state; contract verifies and settles.
///      CEI pattern enforced. ReentrancyGuard on all fund-moving functions.
contract RemitTab is IRemitTab, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @dev EIP-712 typehash for provider charge attestations
    /// Provider signs the final cumulative state off-chain; only this is verified on-chain.
    bytes32 public constant TAB_CHARGE_TYPEHASH =
        keccak256("TabCharge(bytes32 tabId,uint96 totalCharged,uint32 callCount)");

    // =========================================================================
    // Immutable state
    // =========================================================================

    IERC20 public immutable usdc;
    IRemitFeeCalculator public immutable feeCalculator;
    address public immutable feeRecipient;
    address public immutable protocolAdmin;
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

    mapping(bytes32 => RemitTypes.Tab) private _tabs;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _usdc USDC token address
    /// @param _feeCalculator Fee calculator contract address
    /// @param _feeRecipient Address that receives protocol fees
    /// @param _protocolAdmin Admin address for partial dispute resolution
    /// @param _keyRegistry V2: Session key registry (address(0) to disable)
    constructor(
        address _usdc,
        address _feeCalculator,
        address _feeRecipient,
        address _protocolAdmin,
        address _keyRegistry
    ) EIP712("RemitTab", "1") {
        if (_usdc == address(0)) revert RemitErrors.ZeroAddress();
        if (_feeCalculator == address(0)) revert RemitErrors.ZeroAddress();
        if (_feeRecipient == address(0)) revert RemitErrors.ZeroAddress();
        if (_protocolAdmin == address(0)) revert RemitErrors.ZeroAddress();

        usdc = IERC20(_usdc);
        feeCalculator = IRemitFeeCalculator(_feeCalculator);
        feeRecipient = _feeRecipient;
        protocolAdmin = _protocolAdmin;
        keyRegistry = IRemitKeyRegistry(_keyRegistry);
    }

    // =========================================================================
    // External Functions
    // =========================================================================

    /// @inheritdoc IRemitTab
    /// @dev CEI: validate → update state → transfer USDC in
    function openTab(bytes32 tabId, address provider, uint96 limit, uint64 perUnit, uint64 expiry)
        external
        nonReentrant
    {
        // --- Checks ---
        if (_tabs[tabId].payer != address(0)) revert RemitErrors.EscrowAlreadyFunded(tabId);
        if (provider == address(0)) revert RemitErrors.ZeroAddress();
        if (provider == msg.sender) revert RemitErrors.SelfPayment(msg.sender);
        if (limit < RemitTypes.MIN_AMOUNT) revert RemitErrors.BelowMinimum(limit, RemitTypes.MIN_AMOUNT);
        if (expiry <= block.timestamp) revert RemitErrors.InvalidTimeout(expiry);
        // V2: Validate session key delegation
        RemitKeyValidator._validateAndRecord(keyRegistry, msg.sender, limit, RemitTypes.PaymentType.TAB);

        // --- Effects ---
        _tabs[tabId] = RemitTypes.Tab({
            payer: msg.sender,
            limit: limit,
            provider: provider,
            totalCharged: 0,
            perUnit: perUnit,
            expiry: expiry,
            status: RemitTypes.TabStatus.Open,
            degradationTimestamp: 0,
            disputedAmount: 0
        });

        // --- Interactions ---
        usdc.safeTransferFrom(msg.sender, address(this), limit);

        emit RemitEvents.TabOpened(tabId, msg.sender, provider, limit, perUnit, expiry);
    }

    /// @inheritdoc IRemitTab
    /// @dev Either payer or provider can close. Provider must submit latest signed charge state.
    ///      CEI: validate + verify sig → update state → transfer USDC out
    function closeTab(bytes32 tabId, uint96 totalCharged, uint32 callCount, bytes calldata providerSig)
        external
        nonReentrant
    {
        RemitTypes.Tab storage tab = _getTab(tabId);

        // --- Checks ---
        if (tab.status != RemitTypes.TabStatus.Open) revert RemitErrors.TabDepleted(tabId);
        if (msg.sender != tab.payer && msg.sender != tab.provider) revert RemitErrors.Unauthorized(msg.sender);
        if (totalCharged > tab.limit) revert RemitErrors.InsufficientBalance(tab.limit, totalCharged);

        // Verify provider's EIP-712 signature over cumulative charge state
        _verifyProviderSig(tabId, totalCharged, callCount, tab.provider, providerSig);

        _settleTab(tabId, tab, totalCharged);
    }

    /// @inheritdoc IRemitTab
    /// @dev Force-close only after expiry. Either payer or provider can call.
    function closeExpiredTab(bytes32 tabId, uint96 totalCharged, uint32 callCount, bytes calldata providerSig)
        external
        nonReentrant
    {
        RemitTypes.Tab storage tab = _getTab(tabId);

        // --- Checks ---
        if (tab.status != RemitTypes.TabStatus.Open) revert RemitErrors.TabDepleted(tabId);
        if (block.timestamp <= tab.expiry) revert RemitErrors.InvalidTimeout(tab.expiry);
        if (msg.sender != tab.payer && msg.sender != tab.provider) revert RemitErrors.Unauthorized(msg.sender);
        if (totalCharged > tab.limit) revert RemitErrors.InsufficientBalance(tab.limit, totalCharged);

        // Verify provider's EIP-712 signature over cumulative charge state
        // If totalCharged == 0, allow closing without signature (provider charged nothing)
        if (totalCharged > 0) {
            _verifyProviderSig(tabId, totalCharged, callCount, tab.provider, providerSig);
        }

        _settleTab(tabId, tab, totalCharged);
    }

    // =========================================================================
    // For Variants (relayer-submitted, agent pays)
    // =========================================================================

    /// @notice Open a tab on behalf of `payer` (relayer-submitted).
    /// @dev Same logic as openTab but payer is an explicit parameter.
    ///      Requires caller to be an authorized relayer.
    function openTabFor(address payer, bytes32 tabId, address provider, uint96 limit, uint64 perUnit, uint64 expiry)
        external
        nonReentrant
        onlyAuthorizedRelayer
    {
        if (payer == address(0)) revert RemitErrors.ZeroAddress();
        if (_tabs[tabId].payer != address(0)) revert RemitErrors.EscrowAlreadyFunded(tabId);
        if (provider == address(0)) revert RemitErrors.ZeroAddress();
        if (provider == payer) revert RemitErrors.SelfPayment(payer);
        if (limit < RemitTypes.MIN_AMOUNT) revert RemitErrors.BelowMinimum(limit, RemitTypes.MIN_AMOUNT);
        if (expiry <= block.timestamp) revert RemitErrors.InvalidTimeout(expiry);
        RemitKeyValidator._validateAndRecord(keyRegistry, payer, limit, RemitTypes.PaymentType.TAB);

        _tabs[tabId] = RemitTypes.Tab({
            payer: payer,
            limit: limit,
            provider: provider,
            totalCharged: 0,
            perUnit: perUnit,
            expiry: expiry,
            status: RemitTypes.TabStatus.Open,
            degradationTimestamp: 0,
            disputedAmount: 0
        });

        usdc.safeTransferFrom(payer, address(this), limit);
        emit RemitEvents.TabOpened(tabId, payer, provider, limit, perUnit, expiry);
    }

    /// @notice Close tab on behalf of `caller` (relayer-submitted).
    /// @dev caller must be the tab's payer or provider.
    function closeTabFor(
        address caller,
        bytes32 tabId,
        uint96 totalCharged,
        uint32 callCount,
        bytes calldata providerSig
    ) external nonReentrant onlyAuthorizedRelayer {
        RemitTypes.Tab storage tab = _getTab(tabId);

        if (tab.status != RemitTypes.TabStatus.Open) revert RemitErrors.TabDepleted(tabId);
        if (caller != tab.payer && caller != tab.provider) revert RemitErrors.Unauthorized(caller);
        if (totalCharged > tab.limit) revert RemitErrors.InsufficientBalance(tab.limit, totalCharged);

        _verifyProviderSig(tabId, totalCharged, callCount, tab.provider, providerSig);
        _settleTab(tabId, tab, totalCharged);
    }

    /// @notice Force-close an expired tab on behalf of `caller` (relayer-submitted).
    function closeExpiredTabFor(
        address caller,
        bytes32 tabId,
        uint96 totalCharged,
        uint32 callCount,
        bytes calldata providerSig
    ) external nonReentrant onlyAuthorizedRelayer {
        RemitTypes.Tab storage tab = _getTab(tabId);

        if (tab.status != RemitTypes.TabStatus.Open) revert RemitErrors.TabDepleted(tabId);
        if (block.timestamp <= tab.expiry) revert RemitErrors.InvalidTimeout(tab.expiry);
        if (caller != tab.payer && caller != tab.provider) revert RemitErrors.Unauthorized(caller);
        if (totalCharged > tab.limit) revert RemitErrors.InsufficientBalance(tab.limit, totalCharged);

        if (totalCharged > 0) {
            _verifyProviderSig(tabId, totalCharged, callCount, tab.provider, providerSig);
        }

        _settleTab(tabId, tab, totalCharged);
    }

    /// @notice File a partial dispute on behalf of `payer` (relayer-submitted).
    function filePartialDisputeFor(
        address payer,
        bytes32 tabId,
        uint64 degradationTimestamp,
        uint96 undisputedAmount,
        uint32 undisputedCallCount,
        bytes calldata undisputedSig,
        uint96 totalCharged,
        uint32 totalCallCount,
        bytes calldata totalSig
    ) external nonReentrant onlyAuthorizedRelayer {
        RemitTypes.Tab storage tab = _getTab(tabId);

        if (payer != tab.payer) revert RemitErrors.Unauthorized(payer);
        if (tab.status != RemitTypes.TabStatus.Open) revert RemitErrors.TabDepleted(tabId);
        if (degradationTimestamp == 0 || degradationTimestamp > block.timestamp) {
            revert RemitErrors.InvalidTimeout(degradationTimestamp);
        }
        if (undisputedAmount > totalCharged) revert RemitErrors.InsufficientBalance(totalCharged, undisputedAmount);
        if (totalCharged > tab.limit) revert RemitErrors.InsufficientBalance(tab.limit, totalCharged);
        if (totalCharged == undisputedAmount) revert RemitErrors.ZeroAmount();

        _verifyProviderSig(tabId, undisputedAmount, undisputedCallCount, tab.provider, undisputedSig);
        _verifyProviderSig(tabId, totalCharged, totalCallCount, tab.provider, totalSig);

        _applyPartialDispute(tabId, tab, degradationTimestamp, undisputedAmount, totalCharged);
    }

    // =========================================================================
    // Relayer Management
    // =========================================================================

    /// @notice Authorize a relayer address. Only callable by protocolAdmin.
    function authorizeRelayer(address relayer) external {
        if (msg.sender != protocolAdmin) revert RemitErrors.Unauthorized(msg.sender);
        _authorizedRelayers[relayer] = true;
    }

    /// @notice Revoke a relayer address. Only callable by protocolAdmin.
    function revokeRelayer(address relayer) external {
        if (msg.sender != protocolAdmin) revert RemitErrors.Unauthorized(msg.sender);
        _authorizedRelayers[relayer] = false;
    }

    /// @notice Check if an address is an authorized relayer.
    function isAuthorizedRelayer(address relayer) external view returns (bool) {
        return _authorizedRelayers[relayer];
    }

    /// @inheritdoc IRemitTab
    /// @dev Charges before degradationTimestamp settle to provider immediately; charges after are frozen.
    ///      Requires two provider-signed states: the undisputed cumulative state and the full state.
    ///      CEI: validate + verify sigs → effects (status, storage) → interactions (transfers)
    function filePartialDispute(
        bytes32 tabId,
        uint64 degradationTimestamp,
        uint96 undisputedAmount,
        uint32 undisputedCallCount,
        bytes calldata undisputedSig,
        uint96 totalCharged,
        uint32 totalCallCount,
        bytes calldata totalSig
    ) external nonReentrant {
        RemitTypes.Tab storage tab = _getTab(tabId);

        // --- Checks ---
        if (msg.sender != tab.payer) revert RemitErrors.Unauthorized(msg.sender);
        if (tab.status != RemitTypes.TabStatus.Open) revert RemitErrors.TabDepleted(tabId);
        if (degradationTimestamp == 0 || degradationTimestamp > block.timestamp) {
            revert RemitErrors.InvalidTimeout(degradationTimestamp);
        }
        if (undisputedAmount > totalCharged) revert RemitErrors.InsufficientBalance(totalCharged, undisputedAmount);
        if (totalCharged > tab.limit) revert RemitErrors.InsufficientBalance(tab.limit, totalCharged);
        if (totalCharged == undisputedAmount) revert RemitErrors.ZeroAmount();

        // Verify both signed states from provider
        _verifyProviderSig(tabId, undisputedAmount, undisputedCallCount, tab.provider, undisputedSig);
        _verifyProviderSig(tabId, totalCharged, totalCallCount, tab.provider, totalSig);

        // Delegate effects + interactions to helper to stay under stack limit
        _applyPartialDispute(tabId, tab, degradationTimestamp, undisputedAmount, totalCharged);
    }

    /// @inheritdoc IRemitTab
    /// @dev Admin-only. Splits the frozen disputed amount between payer and provider.
    ///      CEI: validate → update state → transfer funds
    function resolvePartialDispute(bytes32 tabId, uint96 providerAmount, uint96 payerAmount) external nonReentrant {
        if (msg.sender != protocolAdmin) revert RemitErrors.Unauthorized(msg.sender);

        RemitTypes.Tab storage tab = _getTab(tabId);

        if (tab.status != RemitTypes.TabStatus.PartiallyDisputed) revert RemitErrors.TabDepleted(tabId);

        uint96 disputed = tab.disputedAmount;
        if (providerAmount + payerAmount != disputed) {
            revert RemitErrors.InsufficientBalance(disputed, providerAmount + payerAmount);
        }

        address payer = tab.payer;
        address provider = tab.provider;

        // --- Effects ---
        tab.status = RemitTypes.TabStatus.Closed;
        tab.disputedAmount = 0;

        // --- Interactions ---
        if (providerAmount > 0) usdc.safeTransfer(provider, providerAmount);
        if (payerAmount > 0) usdc.safeTransfer(payer, payerAmount);

        emit RemitEvents.DisputeResolved(tabId, payerAmount, providerAmount);
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @inheritdoc IRemitTab
    function getTab(bytes32 tabId) external view returns (RemitTypes.Tab memory) {
        return _tabs[tabId];
    }

    /// @notice Returns the EIP-712 domain separator for this contract.
    /// @dev Exposes OZ EIP712's internal _domainSeparatorV4() for test helpers and off-chain signing.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @dev Revert if tab does not exist
    function _getTab(bytes32 tabId) internal view returns (RemitTypes.Tab storage) {
        RemitTypes.Tab storage tab = _tabs[tabId];
        if (tab.payer == address(0)) revert RemitErrors.TabNotFound(tabId);
        return tab;
    }

    /// @dev Verify EIP-712 signature from the provider over (tabId, totalCharged, callCount)
    function _verifyProviderSig(
        bytes32 tabId,
        uint96 totalCharged,
        uint32 callCount,
        address provider,
        bytes calldata sig
    ) internal view {
        bytes32 structHash = keccak256(abi.encode(TAB_CHARGE_TYPEHASH, tabId, totalCharged, callCount));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, sig);
        if (signer != provider) revert RemitErrors.InvalidSignature();
    }

    /// @dev V2: Apply partial dispute: settle undisputed portion, freeze disputed amount.
    ///      Split from filePartialDispute to stay under stack-depth limit.
    function _applyPartialDispute(
        bytes32 tabId,
        RemitTypes.Tab storage tab,
        uint64 degradationTimestamp,
        uint96 undisputedAmount,
        uint96 totalCharged
    ) internal {
        uint96 disputedAmount = totalCharged - undisputedAmount;
        uint96 undisputedFee = 0;
        uint96 providerUndisputed = undisputedAmount;
        if (undisputedAmount > 0) {
            undisputedFee = feeCalculator.calculateFee(tab.payer, undisputedAmount);
            if (undisputedFee > undisputedAmount) undisputedFee = undisputedAmount;
            providerUndisputed = undisputedAmount - undisputedFee;
            feeCalculator.recordTransaction(tab.payer, undisputedAmount);
        }
        uint96 refund = tab.limit - totalCharged;

        address payer = tab.payer;
        address provider = tab.provider;

        // --- Effects ---
        tab.status = RemitTypes.TabStatus.PartiallyDisputed;
        tab.totalCharged = totalCharged;
        tab.degradationTimestamp = degradationTimestamp;
        tab.disputedAmount = disputedAmount;

        // --- Interactions ---
        if (providerUndisputed > 0) usdc.safeTransfer(provider, providerUndisputed);
        if (undisputedFee > 0) usdc.safeTransfer(feeRecipient, undisputedFee);
        if (refund > 0) usdc.safeTransfer(payer, refund);

        emit RemitEvents.TabPartialDispute(tabId, payer, degradationTimestamp, disputedAmount, undisputedAmount);
    }

    /// @dev Settle: compute fee, pay provider, refund payer, update state.
    ///      CEI: all state mutations before USDC transfers.
    function _settleTab(bytes32 tabId, RemitTypes.Tab storage tab, uint96 totalCharged) internal {
        uint96 limit = tab.limit;
        address payer = tab.payer;
        address provider = tab.provider;

        uint96 fee;
        uint96 providerPayout;
        uint96 refund;

        if (totalCharged > 0) {
            fee = feeCalculator.calculateFee(payer, totalCharged);
            providerPayout = totalCharged - fee;
        }
        refund = limit - totalCharged;

        // --- Effects ---
        tab.status = RemitTypes.TabStatus.Closed;
        tab.totalCharged = totalCharged;

        if (totalCharged > 0) {
            feeCalculator.recordTransaction(payer, totalCharged);
        }

        // --- Interactions ---
        if (providerPayout > 0) {
            usdc.safeTransfer(provider, providerPayout);
        }
        if (fee > 0) {
            usdc.safeTransfer(feeRecipient, fee);
        }
        if (refund > 0) {
            usdc.safeTransfer(payer, refund);
        }

        emit RemitEvents.TabClosed(tabId, totalCharged, refund, fee);
    }
}
