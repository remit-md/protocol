// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitStream} from "../src/RemitStream.sol";
import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";
import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {RemitRouter} from "../src/RemitRouter.sol";

/// @title RedeployStream
/// @notice V14 Campaign 3: Redeploy Stream with `For` variants (relayer auth).
///         - Deploys new RemitStream (immutable, new code with For variants + protocolAdmin)
///         - Authorizes with FeeCalculator, KeyRegistry
///         - Updates Router to point to new Stream
///         - Authorizes the server relayer on the new Stream
///
/// @dev Must be run by the 0x3267 deployer (owns Router, FeeCalc, KeyRegistry).
contract RedeployStream is Script {
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
        console2.log("=== V14 C3: Redeploy Stream with For variants ===");
        console2.log("Deployer:", deployer);

        vm.startBroadcast();

        // 1. Deploy new Stream (constructor: usdc, feeCalc, feeRecipient, protocolAdmin, keyRegistry)
        address newStream = address(new RemitStream(USDC, FEE_CALC, FEE_WALLET, deployer, KEY_REGISTRY));
        console2.log("New Stream:", newStream);

        // 2. Authorize with FeeCalculator
        RemitFeeCalculator(FEE_CALC).authorizeCaller(newStream);

        // 3. Authorize with KeyRegistry
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(newStream);

        // 4. Update Router to point to new Stream
        RemitRouter(ROUTER).setStream(newStream);

        // 5. Authorize server relayer on new Stream
        RemitStream(newStream).authorizeRelayer(RELAYER);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Update GitHub secret ===");
        console2.log("STREAM_ADDRESS=", newStream);
        console2.log("");
        console2.log("Relayer authorized:", RELAYER);
        console2.log("Router.stream updated");
    }
}
