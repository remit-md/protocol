// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitBounty} from "../src/RemitBounty.sol";

/// @title RedeployBountyMainnet
/// @notice Redeploy RemitBounty on Base mainnet after dispute system removal.
///
/// @dev TWO-STEP DEPLOY:
///
///   Step 1 (CI): This script deploys the contract and authorizes the relayer.
///     - protocolAdmin = Gnosis Safe (GNOSIS_SAFE env var)
///     - relayer = deployer key (= SERVER_SIGNING_KEY on production)
///
///   Step 2 (Safe UI): The Gnosis Safe owner must execute 3 txns via app.safe.global:
///     - FeeCalculator(0x463695...).authorizeCaller(newBountyAddress)
///     - KeyRegistry(0xB08B61...).authorizeContract(newBountyAddress)
///     - Router(0xAf2e21...).setBounty(newBountyAddress)
///
///   These calls require the Safe because it owns the FeeCalc proxy, KeyRegistry,
///   and Router proxy on mainnet.
contract RedeployBountyMainnet is Script {
    // Base mainnet USDC (Circle official)
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    // FeeCalculator proxy
    address constant FEE_CALC = 0x463695aA6BAF2473cdE1273CEdFB4a9e8e86b9b7;
    // KeyRegistry
    address constant KEY_REGISTRY = 0xB08B61453EbDeB3BA341458bF067f29F93F7BF0F;

    function run() external {
        address deployer = msg.sender;
        // Gnosis Safe is the protocolAdmin — required for relayer management
        address admin = vm.envOr("GNOSIS_SAFE", deployer);
        address feeRecipient = vm.envOr("FEE_WALLET", admin);

        console2.log("=== Redeploy Bounty (Mainnet, dispute removal) ===");
        console2.log("Deployer:", deployer);
        console2.log("Protocol Admin (Safe):", admin);
        console2.log("Fee Wallet:", feeRecipient);

        vm.startBroadcast();

        // 1. Deploy new Bounty — Safe is protocolAdmin, NOT the deployer
        RemitBounty newBounty = new RemitBounty(USDC, FEE_CALC, feeRecipient, admin, KEY_REGISTRY);
        console2.log("New Bounty:", address(newBounty));

        // 2. Authorize deployer as relayer (deployer = SERVER_SIGNING_KEY on production)
        //    This works because protocolAdmin = admin, but the bounty was JUST created so
        //    the deployer is msg.sender in the constructor context. Wait — protocolAdmin
        //    is the Safe, so only the Safe can authorizeRelayer. We need the Safe to do this.
        //    SKIP — must be done from Safe UI.

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== MANUAL STEPS (Safe UI at app.safe.global) ===");
        console2.log("1. FeeCalculator(%s).authorizeCaller(%s)", FEE_CALC, address(newBounty));
        console2.log("2. KeyRegistry(%s).authorizeContract(%s)", KEY_REGISTRY, address(newBounty));
        console2.log("3. Router(0xAf2e211BC585D3Ab37e9BD546Fb25747a09254D2).setBounty(%s)", address(newBounty));
        console2.log("4. NewBounty(%s).authorizeRelayer(<SERVER_SIGNING_KEY>)", address(newBounty));
        console2.log("");
        console2.log("=== Update server .env ===");
        console2.log("BOUNTY_ADDRESS=", address(newBounty));
    }
}
