// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {IRemitFeeCalculator} from "./interfaces/IRemitFeeCalculator.sol";
import {RemitTypes} from "./libraries/RemitTypes.sol";
import {RemitErrors} from "./libraries/RemitErrors.sol";

/// @title RemitFeeCalculator
/// @notice Calculates protocol fees with cliff-based tiering and calendar month volume reset.
/// @dev UPGRADEABLE via UUPS proxy. This is the ONLY upgradeable contract that handles
///      fee logic. Fund-holding contracts (Escrow, Tab, Stream, Bounty) are immutable.
///
///      Fee tiers (in basis points, 10000 = 100%):
///        Standard  : 100 bps (1.00%) — monthly spend volume < $10,000 USDC
///        Preferred : 50 bps  (0.50%) — monthly spend volume >= $10,000 USDC
///
///      Cliff: once a wallet's cumulative spend crosses $10,000 in a calendar month,
///      ALL subsequent transactions that month are charged at 50 bps. No marginal split.
///
///      Volume resets on the 1st of every calendar month (UTC).
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

    /// @dev Calendar month key at which this wallet's volume was last set.
    ///      monthKey = year * 12 + month (e.g. 24315 for March 2026).
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
    /// @dev Cliff-based: once monthly volume >= $10k, preferred rate applies to the ENTIRE
    ///      transaction. No marginal split — the transaction that pushes you past $10k is
    ///      still charged at standard rate; the NEXT transaction gets preferred.
    function calculateFee(address wallet, uint96 amount) external view override returns (uint96 fee) {
        if (_getCurrentVolume(wallet) >= RemitTypes.FEE_THRESHOLD) {
            return uint96((uint256(amount) * RemitTypes.FEE_RATE_PREFERRED_BPS) / 10_000);
        }
        return uint96((uint256(amount) * RemitTypes.FEE_RATE_BPS) / 10_000);
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

    /// @dev Returns the wallet's effective volume for the current calendar month.
    ///      Returns 0 if the wallet hasn't transacted in the current month.
    function _getCurrentVolume(address wallet) internal view returns (uint256) {
        if (lastResetMonth[wallet] < _getMonthKey(block.timestamp)) {
            return 0;
        }
        return monthlyVolume[wallet];
    }

    /// @dev Resets volume to zero if we've entered a new calendar month.
    function _resetIfNewMonth(address wallet) internal {
        uint256 currentMonth = _getMonthKey(block.timestamp);
        if (lastResetMonth[wallet] < currentMonth) {
            monthlyVolume[wallet] = 0;
            lastResetMonth[wallet] = currentMonth;
        }
    }

    /// @dev Returns a unique key for the calendar month containing `timestamp`.
    ///      Uses the Hinnant civil date algorithm (same as C++ std::chrono).
    ///      Result = year * 12 + month (e.g. 24315 for March 2026). Gas: ~200.
    function _getMonthKey(uint256 timestamp) internal pure returns (uint256) {
        uint256 z = timestamp / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        uint256 y = yoe + era * 400;
        if (m <= 2) y += 1;
        return y * 12 + m;
    }

    // =========================================================================
    // Storage gap (reserve 50 slots for future upgrades)
    // =========================================================================

    // solhint-disable-next-line var-name-mixedcase
    uint256[50] private __gap;
}
