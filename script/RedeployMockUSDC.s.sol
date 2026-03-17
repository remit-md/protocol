// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockUSDC} from "../src/test/MockUSDC.sol";

/// @title RedeployMockUSDC
/// @notice Redeploys MockUSDC with EIP-2612 permit support.
///         After deploying, update USDC_ADDRESS in the server .env and restart.
///
/// @dev Run with:
///      forge script script/RedeployMockUSDC.s.sol \
///        --broadcast \
///        --rpc-url $ALCHEMY_BASE_SEPOLIA_URL \
///        --private-key $DEPLOYER_PRIVATE_KEY
contract RedeployMockUSDC is Script {
    function run() external {
        address deployer = msg.sender;

        console2.log("=== Redeploy MockUSDC (with EIP-2612 permit) ===");
        console2.log("Deployer:", deployer);

        vm.startBroadcast();
        MockUSDC usdc = new MockUSDC();
        // Mint $1M USDC to deployer for faucet seeding.
        usdc.mint(deployer, 1_000_000e6);
        vm.stopBroadcast();

        console2.log("New MockUSDC:", address(usdc));
        console2.log("");
        console2.log("Update USDC_ADDRESS in server .env to:", address(usdc));
    }
}
