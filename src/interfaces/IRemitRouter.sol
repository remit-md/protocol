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

    /// @notice Make a direct payment on behalf of `payer` (relayer-submitted).
    ///         The payer must have approved USDC to the Router (typically via EIP-2612 permit).
    /// @param payer Address whose USDC is spent
    /// @param to Recipient address
    /// @param amount USDC amount (6 decimals)
    /// @param memo Optional memo hash
    function payDirectFor(address payer, address to, uint96 amount, bytes32 memo) external;

    /// @notice Make a pay-per-request payment (direct payment with service endpoint metadata)
    /// @param to Recipient address (service provider)
    /// @param amount USDC amount (6 decimals)
    /// @param endpoint Service endpoint URI being called (e.g. "https://api.example.com/v1/inference")
    function payPerRequest(address to, uint96 amount, string calldata endpoint) external;

    /// @notice Make a pay-per-request payment on behalf of `payer` (relayer-submitted).
    /// @param payer Address whose USDC is spent
    /// @param to Recipient address (service provider)
    /// @param amount USDC amount (6 decimals)
    /// @param endpoint Service endpoint URI being called
    function payPerRequestFor(address payer, address to, uint96 amount, string calldata endpoint) external;

    /// @notice Authorize a relayer to call *For variants on behalf of users.
    /// @param relayer Address to authorize
    function authorizeRelayer(address relayer) external;

    /// @notice Revoke a relayer's authorization.
    /// @param relayer Address to revoke
    function revokeRelayer(address relayer) external;

    /// @notice Check if an address is an authorized relayer.
    /// @param relayer Address to check
    /// @return True if the relayer is authorized
    function isAuthorizedRelayer(address relayer) external view returns (bool);

    /// @notice Settle an x402 payment through the Router.
    ///         The agent must have signed an EIP-3009 authorization with `to = address(Router)`.
    ///         The Router pulls the full `amount` from `from`, deducts the protocol fee,
    ///         forwards the net amount to `recipient`, and sends the fee to `feeRecipient`.
    /// @param from         Payer address (must have signed the EIP-3009 authorization)
    /// @param recipient    Final payment recipient (API provider)
    /// @param amount       Total USDC amount (6 decimals)
    /// @param validAfter   EIP-3009 validity start timestamp
    /// @param validBefore  EIP-3009 expiry timestamp
    /// @param nonce        EIP-3009 nonce (replay protection)
    /// @param v            ECDSA v component of the authorization signature
    /// @param r            ECDSA r component of the authorization signature
    /// @param s            ECDSA s component of the authorization signature
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
    ) external;

    /// @notice Update contract addresses (admin only, timelocked)
    function setEscrow(address newEscrow) external;
    function setTab(address newTab) external;
    function setStream(address newStream) external;
    function setBounty(address newBounty) external;
    function setDeposit(address newDeposit) external;
    function setFeeCalculator(address newFeeCalculator) external;
    function setFeeRecipient(address newFeeRecipient) external;
}
