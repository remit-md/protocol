// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRemitFeeCalculator
/// @notice Calculates protocol fees based on wallet tier
/// @dev Peripheral contract. UPGRADEABLE (UUPS + timelock).
interface IRemitFeeCalculator {
    /// @notice Calculate fee for a transaction
    /// @param wallet The payer wallet address
    /// @param amount Transaction amount (6 decimals)
    /// @return fee The fee amount (6 decimals)
    function calculateFee(address wallet, uint96 amount) external view returns (uint96 fee);

    /// @notice Get current monthly volume for a wallet
    /// @param wallet The wallet address
    /// @return volume Monthly volume in USDC (6 decimals)
    function getMonthlyVolume(address wallet) external view returns (uint256 volume);

    /// @notice Record a transaction for volume tracking
    /// @param wallet The payer wallet
    /// @param amount Transaction amount
    /// @dev Called by fund-holding contracts after settlement.
    function recordTransaction(address wallet, uint96 amount) external;

    /// @notice Get fee rate for a wallet (in basis points)
    /// @param wallet The wallet address
    /// @return rateBps Fee rate (100 = 1%, 50 = 0.5%)
    function getFeeRate(address wallet) external view returns (uint96 rateBps);
}
