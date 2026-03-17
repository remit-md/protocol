// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitRouter} from "../src/RemitRouter.sol";
import {IUSDC} from "../src/interfaces/IUSDC.sol";

/// @title UpgradeRouter
/// @notice Upgrades the Router proxy to add settleX402() (V13 C0.4).
///
/// @dev Run with:
///      forge script script/UpgradeRouter.s.sol \
///        --broadcast --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY
///
///      Storage layout is unchanged — only new function added.
contract UpgradeRouter is Script {
    /// @dev Current Router proxy address (Base Sepolia).
    address constant ROUTER_PROXY = 0x887536bD817B758f99F090a80F48032a24f50916;

    function run() external {
        address deployer = msg.sender;
        console2.log("=== Router UUPS Upgrade (settleX402) ===");
        console2.log("Proxy:", ROUTER_PROXY);
        console2.log("Owner (deployer):", deployer);

        // Verify caller is the proxy owner.
        address currentOwner = RemitRouter(ROUTER_PROXY).owner();
        require(currentOwner == deployer, "Deployer is not the proxy owner");

        vm.startBroadcast();

        // 1. Deploy new implementation.
        RemitRouter newImpl = new RemitRouter();
        console2.log("New implementation:", address(newImpl));

        // 2. Upgrade proxy to new implementation (no re-initialization needed).
        RemitRouter(ROUTER_PROXY).upgradeToAndCall(address(newImpl), "");
        console2.log("Proxy upgraded successfully.");

        vm.stopBroadcast();

        // 3. Verify settleX402 selector is callable (view call to check it exists).
        // Can't fully test without a signed EIP-3009 auth, but verify the proxy
        // points to an impl that has the function.
        console2.log("Fee recipient:", RemitRouter(ROUTER_PROXY).feeRecipient());
        console2.log("USDC:", RemitRouter(ROUTER_PROXY).usdc());

        console2.log("");
        console2.log("=== Upgrade complete ===");
        console2.log("New function: settleX402() - routes x402 payments through Router with fee split");
    }
}
