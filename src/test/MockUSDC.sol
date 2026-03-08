// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Minimal ERC-20 for local testing. NOT for production use.
/// @dev Anyone can mint — local Anvil only.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint USDC to any address (no access control — test only)
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
