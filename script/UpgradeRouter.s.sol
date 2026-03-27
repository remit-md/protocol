// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitRouter} from "../src/RemitRouter.sol";

/// @title UpgradeRouter
/// @notice Upgrades the Router proxy to add relayer auth + payDirectFor + payPerRequestFor (V14 C0).
///
/// @dev Run with:
///      forge script script/UpgradeRouter.s.sol \
///        --broadcast --rpc-url $ALCHEMY_BASE_SEPOLIA_URL --private-key $DEPLOYER_PRIVATE_KEY
///
///      Storage layout: one new mapping added (_authorizedRelayers), gap reduced 50→49.
///      Existing storage slots unchanged - safe for UUPS upgrade.
contract UpgradeRouter is Script {
    /// @dev Current Router proxy address (Base Sepolia).
    address constant ROUTER_PROXY = 0x3120F396fF6A9aFc5a9D92e28796082F1429e024;

    function run() external {
        address deployer = msg.sender;
        console2.log("=== Router UUPS Upgrade (V14: relayer auth + For variants) ===");
        console2.log("Proxy:", ROUTER_PROXY);
        console2.log("Owner (deployer):", deployer);

        // Verify caller is the proxy owner.
        RemitRouter router = RemitRouter(ROUTER_PROXY);
        address currentOwner = router.owner();
        require(currentOwner == deployer, "Deployer is not the proxy owner");

        vm.startBroadcast();

        // 1. Deploy new implementation.
        RemitRouter newImpl = new RemitRouter();
        console2.log("New implementation:", address(newImpl));

        // 2. Upgrade proxy to new implementation (no re-initialization needed).
        router.upgradeToAndCall(address(newImpl), "");
        console2.log("Proxy upgraded successfully.");

        // 3. Authorize deployer as relayer (deployer == server signing key).
        //    protocolAdmin == deployer (set in initialize), so this call is allowed.
        router.authorizeRelayer(deployer);
        console2.log("Relayer authorized:", deployer);

        vm.stopBroadcast();

        // 4. Verify new functions are accessible.
        bool isRelayer = router.isAuthorizedRelayer(deployer);
        console2.log("isAuthorizedRelayer(deployer):", isRelayer);
        require(isRelayer, "Relayer authorization failed");

        console2.log("");
        console2.log("=== Upgrade complete ===");
        console2.log("New functions: payDirectFor, payPerRequestFor, authorizeRelayer, revokeRelayer");
    }
}
