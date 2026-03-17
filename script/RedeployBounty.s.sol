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
    address constant USDC = 0x142aD61B8d2edD6b3807D9266866D97C35Ee0317;
    address constant FEE_CALC = 0x853CFc2387C184E4492892475adfc19A23FF2e4F;
    address constant KEY_REGISTRY = 0x97ff63c9E24Fc074023F5d1251E544dCDaC93886;
    address constant ROUTER = 0xb3E96ebE54138d1c0caea00Ae098309C7E0138eC;
    address constant FEE_WALLET = 0xd3f721BDF92a2bB5Dd8d2FE2AFC03aFE5629B420;

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
