// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRemitRouter
/// @notice Routes to current contract versions. Entry point for agents.
/// @dev Peripheral contract. UPGRADEABLE (UUPS + timelock).
interface IRemitRouter {
    /// @notice Get the current escrow contract address
    function escrow() external view returns (address);

    /// @notice Get the current tab contract address
    function tab() external view returns (address);

    /// @notice Get the current stream contract address
    function stream() external view returns (address);

    /// @notice Get the current bounty contract address
    function bounty() external view returns (address);

    /// @notice Get the current deposit contract address
    function deposit() external view returns (address);

    /// @notice Get the current fee calculator address
    function feeCalculator() external view returns (address);

    /// @notice Get the USDC token address for this chain
    function usdc() external view returns (address);

    /// @notice Get the protocol admin (dispute resolution)
    function protocolAdmin() external view returns (address);

    /// @notice Get the fee recipient address
    function feeRecipient() external view returns (address);

    /// @notice Make a direct payment (convenience function routed through Router)
    /// @param to Recipient address
    /// @param amount USDC amount (6 decimals)
    /// @param memo Optional memo hash
    function payDirect(address to, uint96 amount, bytes32 memo) external;

    /// @notice Update contract addresses (admin only, timelocked)
    function setEscrow(address newEscrow) external;
    function setTab(address newTab) external;
    function setStream(address newStream) external;
    function setBounty(address newBounty) external;
    function setDeposit(address newDeposit) external;
    function setFeeCalculator(address newFeeCalculator) external;
}
