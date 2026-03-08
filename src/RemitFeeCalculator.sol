// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {IRemitFeeCalculator} from "./interfaces/IRemitFeeCalculator.sol";
import {RemitTypes} from "./libraries/RemitTypes.sol";
import {RemitErrors} from "./libraries/RemitErrors.sol";

/// @title RemitFeeCalculator
/// @notice Calculates protocol fees with marginal tiering based on 30-day rolling volume.
/// @dev UPGRADEABLE via UUPS proxy. This is the ONLY upgradeable contract that handles
///      fee logic. Fund-holding contracts (Escrow, Tab, Stream, Bounty) are immutable.
///
///      Fee tiers (in basis points, 10000 = 100%):
///        Standard  : 100 bps (1.00%) — rolling volume < $10,000 USDC
///        Preferred : 50 bps  (0.50%) — rolling volume >= $10,000 USDC
///
///      Marginal calculation: transactions that cross the threshold are split —
///      the portion below is charged at standard rate and the rest at preferred rate.
///
///      Volume resets on a 30-day rolling window (block.timestamp / 30 days).
///      This is a simplified approximation of calendar months; good enough for billing.
///
///      Ownership is managed via an initialize() + onlyOwner pattern (no OZ Upgradeable
///      dependency) so we only need openzeppelin/contracts (non-upgradeable package).
contract RemitFeeCalculator is IRemitFeeCalculator, UUPSUpgradeable {
    // =========================================================================
    // Storage (proxy-safe layout — slots 0+ are used by proxy context)
    // =========================================================================

    /// @dev Guard to prevent double-initialization. Set to true in constructor
    ///      to prevent direct initialization of the implementation contract.
    bool private _initialized;

    /// @dev Contract owner (can upgrade and authorize callers).
    address private _owner;

    /// @dev Monthly volume per wallet (raw, may be from a stale month — use _getCurrentVolume).
    mapping(address => uint256) public monthlyVolume;

    /// @dev The 30-day window key at which this wallet's volume was last set.
    ///      monthKey = block.timestamp / 30 days.
    mapping(address => uint256) public lastResetMonth;

    /// @dev Contracts authorized to call recordTransaction (Escrow, Tab, Stream, Bounty, Router).
    mapping(address => bool) public authorizedCallers;

    // =========================================================================
    // Constructor — disables direct initialization of implementation contract
    // =========================================================================

    constructor() {
        // Prevent calling initialize() directly on the implementation.
        // Proxies deployed via ERC1967Proxy have FRESH storage, so _initialized
        // is false in the proxy context and initialize() can be called once.
        _initialized = true;
    }

    // =========================================================================
    // Initializer — called once through the proxy during deployment
    // =========================================================================

    /// @notice Initialize the fee calculator (proxy deployment only).
    /// @param owner_ The initial owner address (protocol admin).
    function initialize(address owner_) external {
        if (_initialized) revert RemitErrors.Unauthorized(msg.sender);
        if (owner_ == address(0)) revert RemitErrors.ZeroAddress();
        _initialized = true;
        _owner = owner_;
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyOwner() {
        if (msg.sender != _owner) revert RemitErrors.Unauthorized(msg.sender);
        _;
    }

    modifier onlyAuthorized() {
        if (!authorizedCallers[msg.sender]) revert RemitErrors.Unauthorized(msg.sender);
        _;
    }

    // =========================================================================
    // IRemitFeeCalculator
    // =========================================================================

    /// @inheritdoc IRemitFeeCalculator
    function calculateFee(address wallet, uint96 amount) external view override returns (uint96 fee) {
        uint256 volume = _getCurrentVolume(wallet);

        // Already past threshold — entire transaction at preferred rate.
        if (volume >= RemitTypes.FEE_THRESHOLD) {
            return uint96((uint256(amount) * RemitTypes.FEE_RATE_PREFERRED_BPS) / 10_000);
        }

        uint256 remaining = RemitTypes.FEE_THRESHOLD - volume;

        // Entire transaction fits within standard-rate region.
        if (uint256(amount) <= remaining) {
            return uint96((uint256(amount) * RemitTypes.FEE_RATE_BPS) / 10_000);
        }

        // Marginal split: portion at standard + portion at preferred.
        uint256 standardFee = (remaining * RemitTypes.FEE_RATE_BPS) / 10_000;
        uint256 preferredFee = ((uint256(amount) - remaining) * RemitTypes.FEE_RATE_PREFERRED_BPS) / 10_000;
        return uint96(standardFee + preferredFee);
    }

    /// @inheritdoc IRemitFeeCalculator
    function getMonthlyVolume(address wallet) external view override returns (uint256 volume) {
        return _getCurrentVolume(wallet);
    }

    /// @inheritdoc IRemitFeeCalculator
    /// @dev Only callable by authorized contracts (Escrow, Tab, Stream, Bounty, Router).
    function recordTransaction(address wallet, uint96 amount) external override onlyAuthorized {
        _resetIfNewMonth(wallet);
        monthlyVolume[wallet] += amount;
    }

    /// @inheritdoc IRemitFeeCalculator
    function getFeeRate(address wallet) external view override returns (uint96 rateBps) {
        return _getCurrentVolume(wallet) >= RemitTypes.FEE_THRESHOLD
            ? RemitTypes.FEE_RATE_PREFERRED_BPS
            : RemitTypes.FEE_RATE_BPS;
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Authorize a contract to call recordTransaction.
    /// @param caller The contract address to authorize (e.g. RemitEscrow).
    function authorizeCaller(address caller) external onlyOwner {
        if (caller == address(0)) revert RemitErrors.ZeroAddress();
        authorizedCallers[caller] = true;
    }

    /// @notice Revoke a contract's authorization to call recordTransaction.
    /// @param caller The contract address to deauthorize.
    function revokeCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = false;
    }

    /// @notice Transfer ownership to a new address.
    /// @param newOwner The new owner address.
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
    // Internal
    // =========================================================================

    /// @dev Returns the wallet's effective volume for the current 30-day window.
    ///      Returns 0 if the wallet hasn't transacted in the current window.
    function _getCurrentVolume(address wallet) internal view returns (uint256) {
        uint256 currentMonth = block.timestamp / 30 days;
        if (lastResetMonth[wallet] < currentMonth) {
            return 0;
        }
        return monthlyVolume[wallet];
    }

    /// @dev Resets volume to zero if we've entered a new 30-day window.
    function _resetIfNewMonth(address wallet) internal {
        uint256 currentMonth = block.timestamp / 30 days;
        if (lastResetMonth[wallet] < currentMonth) {
            monthlyVolume[wallet] = 0;
            lastResetMonth[wallet] = currentMonth;
        }
    }

    // =========================================================================
    // Storage gap (reserve 50 slots for future upgrades)
    // =========================================================================

    // solhint-disable-next-line var-name-mixedcase
    uint256[50] private __gap;
}
