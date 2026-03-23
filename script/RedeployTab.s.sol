// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitTab} from "../src/RemitTab.sol";
import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";
import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {RemitRouter} from "../src/RemitRouter.sol";

/// @title RedeployTab
/// @notice V14 Campaign 2: Redeploy Tab with `For` variants (relayer auth).
///         - Deploys new RemitTab (immutable, new code with For variants)
///         - Authorizes with FeeCalculator, KeyRegistry
///         - Updates Router to point to new Tab
///         - Authorizes the server relayer on the new Tab
///
/// @dev Must be run by the 0x3267 deployer (owns Router, FeeCalc, KeyRegistry).
contract RedeployTab is Script {
    // Infrastructure (do NOT redeploy)
    address constant USDC = 0x2d846325766921935f37d5b4478196d3ef93707c;
    address constant FEE_CALC = 0xcce1b8cee59f860578bed3c05fe2a80eea04aafb;
    address constant KEY_REGISTRY = 0xf5ba0baa124885eb88ad225e81a60864d5e43074;
    address constant ROUTER = 0x3120f396ff6a9afc5a9d92e28796082f1429e024;
    address constant FEE_WALLET = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    // Server relayer
    address constant RELAYER = 0x3267B8B2D4A43F7eEd02B11a1564Faf8C9617020;

    function run() external {
        address deployer = msg.sender;
        console2.log("=== V14 C2: Redeploy Tab with For variants ===");
        console2.log("Deployer:", deployer);

        vm.startBroadcast();

        // 1. Deploy new Tab (constructor: usdc, feeCalc, feeRecipient, protocolAdmin, keyRegistry)
        address newTab = address(new RemitTab(USDC, FEE_CALC, FEE_WALLET, deployer, KEY_REGISTRY));
        console2.log("New Tab:", newTab);

        // 2. Authorize with FeeCalculator
        RemitFeeCalculator(FEE_CALC).authorizeCaller(newTab);

        // 3. Authorize with KeyRegistry
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(newTab);

        // 4. Update Router to point to new Tab
        RemitRouter(ROUTER).setTab(newTab);

        // 5. Authorize server relayer on new Tab
        RemitTab(newTab).authorizeRelayer(RELAYER);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Update GitHub secret ===");
        console2.log("TAB_ADDRESS=", newTab);
        console2.log("");
        console2.log("Relayer authorized:", RELAYER);
        console2.log("Router.tab updated");
    }
}
