// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RemitTypes} from "../libraries/RemitTypes.sol";

/// @title IRemitTab
/// @notice Metered payment tabs (off-chain payment channels)
/// @dev Fund-holding. IMMUTABLE. Charges happen off-chain; settlement on-chain.
interface IRemitTab {
    /// @notice Open a metered tab by locking USDC
    /// @param tabId Unique tab identifier
    /// @param provider Address of the service provider
    /// @param limit Maximum USDC to authorize (6 decimals)
    /// @param perUnit Cost per unit/call (6 decimals)
    /// @param expiry Unix timestamp when tab auto-closes
    /// @dev Caller must have approved USDC transfer. Emits TabOpened.
    function openTab(bytes32 tabId, address provider, uint96 limit, uint64 perUnit, uint64 expiry) external;

    /// @notice Close tab and settle. Provider submits signed cumulative charge.
    /// @param tabId The tab ID
    /// @param totalCharged Total amount charged (cumulative)
    /// @param callCount Number of calls/units consumed
    /// @param providerSig Provider's EIP-712 signature over (tabId, totalCharged, callCount)
    /// @dev Either party can call. Unused funds return to payer. Emits TabClosed.
    function closeTab(bytes32 tabId, uint96 totalCharged, uint32 callCount, bytes calldata providerSig) external;

    /// @notice Force-close an expired tab
    /// @param tabId The tab ID
    /// @param totalCharged Latest signed cumulative charge
    /// @param callCount Number of calls
    /// @param providerSig Provider's signature
    /// @dev Only after expiry. Emits TabClosed.
    function closeExpiredTab(bytes32 tabId, uint96 totalCharged, uint32 callCount, bytes calldata providerSig) external;

    /// @notice V2: File a partial dispute. Charges before degradationTimestamp settle to provider;
    ///         charges after are frozen for dispute resolution.
    /// @param tabId The tab ID
    /// @param degradationTimestamp Unix timestamp when service quality degraded
    /// @param undisputedAmount Total charges up to degradationTimestamp (provider-signed)
    /// @param undisputedCallCount Call count at degradation point
    /// @param undisputedSig Provider's EIP-712 sig over undisputed state
    /// @param totalCharged Full claimed total (including post-degradation)
    /// @param totalCallCount Full call count
    /// @param totalSig Provider's EIP-712 sig over full state
    /// @dev Only callable by payer. Emits TabPartialDispute.
    function filePartialDispute(
        bytes32 tabId,
        uint64 degradationTimestamp,
        uint96 undisputedAmount,
        uint32 undisputedCallCount,
        bytes calldata undisputedSig,
        uint96 totalCharged,
        uint32 totalCallCount,
        bytes calldata totalSig
    ) external;

    // === For Variants (relayer-submitted) ===

    function openTabFor(address payer, bytes32 tabId, address provider, uint96 limit, uint64 perUnit, uint64 expiry) external;
    function closeTabFor(address caller, bytes32 tabId, uint96 totalCharged, uint32 callCount, bytes calldata providerSig) external;
    function closeExpiredTabFor(address caller, bytes32 tabId, uint96 totalCharged, uint32 callCount, bytes calldata providerSig) external;
    function filePartialDisputeFor(address payer, bytes32 tabId, uint64 degradationTimestamp, uint96 undisputedAmount, uint32 undisputedCallCount, bytes calldata undisputedSig, uint96 totalCharged, uint32 totalCallCount, bytes calldata totalSig) external;
    function authorizeRelayer(address relayer) external;
    function revokeRelayer(address relayer) external;
    function isAuthorizedRelayer(address relayer) external view returns (bool);

    /// @notice V2: Resolve a partial dispute (admin only). Split disputed amount.
    /// @param tabId The tab ID
    /// @param providerAmount Disputed portion going to provider
    /// @param payerAmount Disputed portion returned to payer
    function resolvePartialDispute(bytes32 tabId, uint96 providerAmount, uint96 payerAmount) external;

    // === View Functions ===

    function getTab(bytes32 tabId) external view returns (RemitTypes.Tab memory);
}
