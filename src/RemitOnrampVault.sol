// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title RemitOnrampVault
/// @notice Minimal per-operator vault for fiat on-ramp USDC deposits.
///         Coinbase Onramp sends USDC here; sweep() splits 99% to operator, 1% to protocol.
/// @dev Deployed as EIP-1167 clone via OnrampVaultFactory.
///      Fund-holding contract. IMMUTABLE — no proxy, no upgrade path.
///      CEI pattern enforced. ReentrancyGuard on sweep().
///
///      Each operator gets one vault (deterministic CREATE2 address).
///      The vault holds USDC until sweep() is called. sweep() is permissionless —
///      funds can ONLY flow to the operator and feeRecipient set at initialization.
contract RemitOnrampVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Storage (set once via initialize, then immutable)
    // =========================================================================

    /// @dev Clone initialization guard. Set to true in implementation constructor
    ///      and in clone initialize(). Prevents double-initialization.
    bool private _initialized;

    /// @dev Operator wallet address — receives 99% of swept funds.
    address public operator;

    /// @dev USDC token contract.
    IERC20 public usdc;

    /// @dev Protocol fee recipient — receives 1% of swept funds.
    address public feeRecipient;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @dev On-ramp fee rate: 100 basis points = 1%.
    uint96 public constant FEE_BPS = 100;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when vault USDC is swept to operator and fee recipient.
    /// @param operator The operator wallet that received net funds.
    /// @param operatorAmount Amount sent to operator (99%).
    /// @param feeAmount Amount sent to protocol fee recipient (1%).
    event Swept(address indexed operator, uint256 operatorAmount, uint256 feeAmount);

    // =========================================================================
    // Errors
    // =========================================================================

    error AlreadyInitialized();
    error ZeroAddress();
    error NothingToSweep();

    // =========================================================================
    // Constructor — disables initialization on implementation contract
    // =========================================================================

    constructor() {
        _initialized = true;
    }

    // =========================================================================
    // Initializer — called once by factory during clone deployment
    // =========================================================================

    /// @notice Initialize this vault clone. Can only be called once.
    /// @param _operator Operator wallet (receives 99% on sweep).
    /// @param _usdc USDC token address.
    /// @param _feeRecipient Protocol fee recipient (receives 1% on sweep).
    function initialize(address _operator, address _usdc, address _feeRecipient) external {
        if (_initialized) revert AlreadyInitialized();
        if (_operator == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();

        _initialized = true;
        operator = _operator;
        usdc = IERC20(_usdc);
        feeRecipient = _feeRecipient;
    }

    // =========================================================================
    // Sweep
    // =========================================================================

    /// @notice Sweep entire USDC balance: 99% to operator, 1% to protocol.
    /// @dev Permissionless — anyone can call. Safe because funds only go to
    ///      operator and feeRecipient (both set at init, immutable).
    ///      CEI: check balance → compute split → transfer out.
    function sweep() external nonReentrant {
        uint256 balance = usdc.balanceOf(address(this));

        // --- Checks ---
        if (balance == 0) revert NothingToSweep();

        // --- Effects (compute split) ---
        uint256 fee = (balance * FEE_BPS) / 10_000;
        uint256 operatorAmount = balance - fee;

        // --- Interactions ---
        if (operatorAmount > 0) {
            usdc.safeTransfer(operator, operatorAmount);
        }
        if (fee > 0) {
            usdc.safeTransfer(feeRecipient, fee);
        }

        emit Swept(operator, operatorAmount, fee);
    }

    // =========================================================================
    // View
    // =========================================================================

    /// @notice Returns the USDC balance waiting to be swept.
    function pendingBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}
