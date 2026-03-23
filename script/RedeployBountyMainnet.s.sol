// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitBounty} from "../src/RemitBounty.sol";
import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";
import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {RemitRouter} from "../src/RemitRouter.sol";

/// @title RedeployBountyMainnet
/// @notice Redeploy RemitBounty on Base mainnet after dispute system removal.
///         Authorizes the deployer as relayer (deployer = server signing key on production).
///         Updates Router, FeeCalculator, and KeyRegistry to point to new Bounty.
contract RedeployBountyMainnet is Script {
    // Base mainnet USDC (Circle official)
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    // FeeCalculator proxy
    address constant FEE_CALC = 0x463695aA6BAF2473cdE1273CEdFB4a9e8e86b9b7;
    // KeyRegistry
    address constant KEY_REGISTRY = 0xB08B61453EbDeB3BA341458bF067f29F93F7BF0F;
    // Router proxy
    address constant ROUTER = 0xAf2e211BC585D3Ab37e9BD546Fb25747a09254D2;

    function run() external {
        address deployer = msg.sender;
        address feeRecipient = vm.envOr("FEE_WALLET", deployer);

        console2.log("=== Redeploy Bounty (Mainnet, dispute removal) ===");
        console2.log("Deployer / Relayer:", deployer);
        console2.log("Fee Wallet:", feeRecipient);

        vm.startBroadcast();

        // 1. Deploy new Bounty (dispute system removed)
        RemitBounty newBounty = new RemitBounty(USDC, FEE_CALC, feeRecipient, deployer, KEY_REGISTRY);
        console2.log("New Bounty:", address(newBounty));

        // 2. Authorize deployer as relayer (deployer = server signing key on production)
        newBounty.authorizeRelayer(deployer);
        console2.log("Relayer authorized:", deployer);

        // 3. Authorize with FeeCalculator
        RemitFeeCalculator(FEE_CALC).authorizeCaller(address(newBounty));
        console2.log("FeeCalc authorized");

        // 4. Authorize with KeyRegistry
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(address(newBounty));
        console2.log("KeyRegistry authorized");

        // 5. Update Router to point to new Bounty
        RemitRouter(ROUTER).setBounty(address(newBounty));
        console2.log("Router updated");

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Update server .env ===");
        console2.log("BOUNTY_ADDRESS=", address(newBounty));
    }
}
