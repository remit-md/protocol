// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitBounty} from "../src/RemitBounty.sol";
import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";
import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {RemitRouter} from "../src/RemitRouter.sol";

/// @title RedeployBounty
/// @notice Redeploy RemitBounty with For-variant relayer support.
///         Authorizes the deployer as relayer (deployer = server signing key on production).
///
/// @dev Run with:
///      source .env.testnet && forge script script/RedeployBounty.s.sol \
///        --broadcast --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY
contract RedeployBounty is Script {
    address constant USDC = 0x2d846325766921935f37d5b4478196d3ef93707c;
    address constant FEE_CALC = 0xcce1b8cee59f860578bed3c05fe2a80eea04aafb;
    address constant KEY_REGISTRY = 0xf5ba0baa124885eb88ad225e81a60864d5e43074;
    address constant ROUTER = 0x3120f396ff6a9afc5a9d92e28796082f1429e024;
    address constant FEE_WALLET = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    function run() external {
        address deployer = msg.sender;
        console2.log("=== Redeploy Bounty with relayer support ===");
        console2.log("Deployer / Relayer:", deployer);

        vm.startBroadcast();

        // 1. Deploy new Bounty with For-variants
        RemitBounty newBounty = new RemitBounty(USDC, FEE_CALC, FEE_WALLET, deployer, KEY_REGISTRY);
        console2.log("New Bounty:", address(newBounty));

        // 2. Authorize deployer as relayer (deployer = server signing key on production)
        newBounty.authorizeRelayer(deployer);
        console2.log("Relayer authorized:", deployer);

        // 3. Authorize with FeeCalculator
        RemitFeeCalculator(FEE_CALC).authorizeCaller(address(newBounty));

        // 4. Authorize with KeyRegistry
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(address(newBounty));

        // 5. Update Router to point to new Bounty
        RemitRouter(ROUTER).setBounty(address(newBounty));

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Update server .env ===");
        console2.log("BOUNTY_ADDRESS=", address(newBounty));
    }
}
