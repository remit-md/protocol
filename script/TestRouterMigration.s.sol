// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitTab} from "../src/RemitTab.sol";
import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";
import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {RemitRouter} from "../src/RemitRouter.sol";

/// @title TestRouterMigration
/// @notice P2.3: Validates the Router migration playbook on Sepolia.
///
///         Proves that the incident response migration pattern works:
///         1. Deploy a duplicate Tab contract (same bytecode, same constructor args)
///         2. Authorize it with FeeCalculator + KeyRegistry
///         3. Update Router to point to the new Tab
///         4. Verify Router.tab() returns the new address
///         5. Revert Router back to the original Tab
///         6. Verify Router.tab() returns the original address
///
///         This validates that:
///         - The Router owner can swap contract addresses at will
///         - The authorization flow (FeeCalc + KeyRegistry + relayer) works
///         - The revert (incident recovery) works
///         - Old contract instances are unaffected by Router pointer changes
///
/// @dev Must be run by the 0x3267 deployer (owns Router proxy).
///      Run via deploy-testnet.yml workflow with --broadcast.
contract TestRouterMigration is Script {
    // Infrastructure (do NOT redeploy)
    address constant USDC = 0x2d846325766921935f37d5b4478196d3ef93707c;
    address constant FEE_CALC = 0xcce1b8cee59f860578bed3c05fe2a80eea04aafb;
    address constant KEY_REGISTRY = 0xf5ba0baa124885eb88ad225e81a60864d5e43074;
    address constant ROUTER = 0x3120f396ff6a9afc5a9d92e28796082f1429e024;
    address constant FEE_WALLET = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    // Server relayer
    address constant RELAYER = 0x3267B8B2D4A43F7eEd02B11a1564Faf8C9617020;

    // Current Tab (should match Router.tab())
    address constant CURRENT_TAB = 0x9415f510d8c6199e0f66bde927d7d88de391f5e8;

    function run() external {
        address deployer = msg.sender;
        RemitRouter router = RemitRouter(ROUTER);

        console2.log("=== P2.3: Router Migration Test ===");
        console2.log("Deployer:", deployer);
        console2.log("");

        // ---------------------------------------------------------------
        // Pre-flight: verify current state
        // ---------------------------------------------------------------
        address oldTab = router.tab();
        console2.log("Current Router.tab():", oldTab);
        require(oldTab == CURRENT_TAB, "Pre-flight: Router.tab() does not match expected CURRENT_TAB");
        console2.log("Pre-flight check PASSED: Router.tab() matches expected address");
        console2.log("");

        // ---------------------------------------------------------------
        // Step 1: Deploy duplicate Tab + authorize + update Router
        // ---------------------------------------------------------------
        vm.startBroadcast();

        // Deploy new Tab with identical constructor args
        // Constructor: (usdc, feeCalc, feeRecipient, protocolAdmin, keyRegistry)
        address newTab = address(new RemitTab(USDC, FEE_CALC, FEE_WALLET, deployer, KEY_REGISTRY));
        console2.log("New Tab deployed:", newTab);

        // Authorize with FeeCalculator (so it can calculate fees)
        RemitFeeCalculator(FEE_CALC).authorizeCaller(newTab);
        console2.log("FeeCalculator: authorized new Tab");

        // Authorize with KeyRegistry (so session keys work)
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(newTab);
        console2.log("KeyRegistry: authorized new Tab");

        // Authorize server relayer on new Tab
        RemitTab(newTab).authorizeRelayer(RELAYER);
        console2.log("Relayer authorized on new Tab");

        // Update Router to point to new Tab
        router.setTab(newTab);
        console2.log("Router.setTab(newTab) called");

        vm.stopBroadcast();

        // ---------------------------------------------------------------
        // Step 2: Verify migration
        // ---------------------------------------------------------------
        address tabAfterMigration = router.tab();
        console2.log("");
        console2.log("Router.tab() after migration:", tabAfterMigration);
        require(tabAfterMigration == newTab, "FAIL: Router.tab() should be newTab after migration");
        console2.log("MIGRATION CHECK PASSED: Router points to new Tab");

        // Verify old Tab still exists and has code
        uint256 oldTabCodeSize;
        assembly {
            oldTabCodeSize := extcodesize(oldTab)
        }
        require(oldTabCodeSize > 0, "FAIL: Old Tab contract should still have code");
        console2.log("OLD CONTRACT CHECK PASSED: Old Tab still has code (", oldTabCodeSize, "bytes)");

        // ---------------------------------------------------------------
        // Step 3: Revert Router back to original Tab (cleanup)
        // ---------------------------------------------------------------
        console2.log("");
        console2.log("Reverting Router to original Tab...");

        vm.startBroadcast();
        router.setTab(oldTab);
        vm.stopBroadcast();

        // ---------------------------------------------------------------
        // Step 4: Verify revert
        // ---------------------------------------------------------------
        address tabAfterRevert = router.tab();
        console2.log("Router.tab() after revert:", tabAfterRevert);
        require(tabAfterRevert == oldTab, "FAIL: Router.tab() should be oldTab after revert");
        console2.log("REVERT CHECK PASSED: Router points back to original Tab");

        // ---------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------
        console2.log("");
        console2.log("=== ALL CHECKS PASSED ===");
        console2.log("1. Deployed duplicate Tab at:", newTab);
        console2.log("2. Authorized with FeeCalc + KeyRegistry + Relayer");
        console2.log("3. Router.setTab(newTab) succeeded -- migration works");
        console2.log("4. Old Tab contract unaffected (still has code)");
        console2.log("5. Router.setTab(oldTab) succeeded -- revert works");
        console2.log("6. Router restored to original state");
        console2.log("");
        console2.log("Incident response playbook VALIDATED:");
        console2.log("  - Deploy new contract");
        console2.log("  - Authorize + wire via Router");
        console2.log("  - Old contract stays alive for in-flight settlements");
        console2.log("  - Revert is a single setTab() call");
    }
}
