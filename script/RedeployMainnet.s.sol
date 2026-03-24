// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RemitEscrow} from "../src/RemitEscrow.sol";
import {RemitTab} from "../src/RemitTab.sol";
import {RemitStream} from "../src/RemitStream.sol";
import {RemitDeposit} from "../src/RemitDeposit.sol";
import {RemitRouter} from "../src/RemitRouter.sol";

/// @title RedeployMainnet
/// @notice Redeploy Escrow, Tab, Stream, Deposit on Base mainnet and upgrade
///         the Router proxy to the latest implementation.
///
/// @dev TWO-STEP DEPLOY:
///
///   Step 1 (CI): This script deploys 4 new immutable contracts + 1 new Router
///     implementation. It does NOT wire anything — the Safe owns FeeCalc,
///     KeyRegistry, and Router, so only the Safe can do the wiring.
///
///   Step 2 (MetaMask): Open authorize-redeploy-mainnet.html, connect the Safe
///     owner wallet, and confirm the wiring transactions.
///
///   Why redeploy:
///     - Escrow: claimTimeoutPayee fix, fee dust fix, submitEvidence bounds,
///               dispute system removed, constructor changed (5 params)
///     - Tab: dispute system removed
///     - Stream: settle() reverts StreamHealthy, settleX402 session key + self-pay
///     - Deposit: authorizeRelayer rejects address(0)
///     - Router: settleX402 session key validation + self-payment check (UUPS upgrade)
contract RedeployMainnet is Script {
    // ── Infrastructure (do NOT redeploy) ────────────────────────────────
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant FEE_CALC = 0x463695aA6BAF2473cdE1273CEdFB4a9e8e86b9b7;
    address constant KEY_REGISTRY = 0xB08B61453EbDeB3BA341458bF067f29F93F7BF0F;
    address constant ROUTER_PROXY = 0xAf2e211BC585D3Ab37e9BD546Fb25747a09254D2;

    // ── Already redeployed (2026-03-23, dispute removal) ────────────────
    address constant BOUNTY = 0x6cf0570078c831440866ad60dd4ff43ef676f5bb;

    function run() external {
        address deployer = msg.sender;
        address admin = vm.envOr("GNOSIS_SAFE", deployer);
        address feeRecipient = vm.envOr("FEE_WALLET", admin);

        console2.log("=== Redeploy Mainnet (Escrow, Tab, Stream, Deposit + Router upgrade) ===");
        console2.log("Deployer:", deployer);
        console2.log("Protocol Admin (Safe):", admin);
        console2.log("Fee Wallet:", feeRecipient);
        console2.log("");

        vm.startBroadcast();

        // 1. Deploy new immutable contracts — Safe is protocolAdmin
        //    Constructor arg order varies per contract — verified against source.
        address newEscrow = address(
            new RemitEscrow(USDC, FEE_CALC, admin, feeRecipient, KEY_REGISTRY)
        );
        address newTab = address(
            new RemitTab(USDC, FEE_CALC, feeRecipient, admin, KEY_REGISTRY)
        );
        address newStream = address(
            new RemitStream(USDC, FEE_CALC, feeRecipient, admin, KEY_REGISTRY)
        );
        address newDeposit = address(new RemitDeposit(USDC, KEY_REGISTRY, admin));

        console2.log("New Escrow: ", newEscrow);
        console2.log("New Tab:    ", newTab);
        console2.log("New Stream: ", newStream);
        console2.log("New Deposit:", newDeposit);

        // 2. Deploy new Router implementation (for UUPS upgrade)
        address newRouterImpl = address(new RemitRouter());
        console2.log("New Router impl:", newRouterImpl);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== MANUAL STEPS (authorize-redeploy-mainnet.html via MetaMask) ===");
        console2.log("");
        console2.log("--- FeeCalculator.authorizeCaller ---");
        console2.log("  Escrow:  ", newEscrow);
        console2.log("  Tab:     ", newTab);
        console2.log("  Stream:  ", newStream);
        console2.log("");
        console2.log("--- KeyRegistry.authorizeContract ---");
        console2.log("  Escrow:  ", newEscrow);
        console2.log("  Tab:     ", newTab);
        console2.log("  Stream:  ", newStream);
        console2.log("  Deposit: ", newDeposit);
        console2.log("");
        console2.log("--- Router.set* ---");
        console2.log("  setEscrow: ", newEscrow);
        console2.log("  setTab:    ", newTab);
        console2.log("  setStream: ", newStream);
        console2.log("  setDeposit:", newDeposit);
        console2.log("");
        console2.log("--- Router.upgradeToAndCall ---");
        console2.log("  newImpl:", newRouterImpl);
        console2.log("");
        console2.log("--- authorizeRelayer on new contracts ---");
        console2.log("  Escrow:  ", newEscrow);
        console2.log("  Tab:     ", newTab);
        console2.log("  Stream:  ", newStream);
        console2.log("  Deposit: ", newDeposit);
        console2.log("");
        console2.log("=== Update server .env ===");
        console2.log("ESCROW_ADDRESS=", newEscrow);
        console2.log("TAB_ADDRESS=", newTab);
        console2.log("STREAM_ADDRESS=", newStream);
        console2.log("DEPOSIT_ADDRESS=", newDeposit);
    }
}
