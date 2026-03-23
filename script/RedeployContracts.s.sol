// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitEscrow} from "../src/RemitEscrow.sol";
import {RemitTab} from "../src/RemitTab.sol";
import {RemitStream} from "../src/RemitStream.sol";
import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";
import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {RemitRouter} from "../src/RemitRouter.sol";
import {RemitOnrampVault} from "../src/RemitOnrampVault.sol";
import {OnrampVaultFactory} from "../src/OnrampVaultFactory.sol";

/// @title RedeployContracts
/// @notice Fix feeRecipient on contracts that were deployed with the deployer
///         address instead of the dedicated fee wallet.
///
///         Redeploys: Escrow, Tab, Stream, OnrampVaultFactory (immutable feeRecipient).
///         Updates:   Router via setFeeRecipient() (UUPS proxy, has setter).
///         Skips:     Bounty (already correct), Deposit (no fee), FeeCalculator (no recipient).
///
/// @dev Must be run by the 0x3267 deployer (owns Router, FeeCalc, KeyRegistry).
///
///      forge script script/RedeployContracts.s.sol \
///        --broadcast \
///        --rpc-url $ALCHEMY_BASE_SEPOLIA_URL \
///        --private-key $DEPLOYER_PRIVATE_KEY
contract RedeployContracts is Script {
    // ---- Infrastructure (do NOT redeploy — proxies or shared contracts) ----
    address constant USDC = 0x2D846325766921935f37d5b4478196d3EF93707C;
    address constant FEE_CALC = 0xCCe1B8cEE59f860578Bed3C05FE2A80EEa04aAfB;
    address constant KEY_REGISTRY = 0xF5Ba0BAA124885EB88aD225e81A60864d5E43074;
    address constant ROUTER = 0x3120F396fF6A9aFc5a9D92e28796082F1429e024;

    // ---- Contracts that are already correct (skip) ----
    address constant BOUNTY = 0xB3868471c3034280ccE3a56DD37C6154c3Bb0B32;

    // ---- Dedicated fee wallet (only receives fees, never sends) ----
    address constant FEE_WALLET = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    function run() external {
        address deployer = msg.sender;
        console2.log("=== Fix feeRecipient: deployer -> fee wallet ===");
        console2.log("Deployer / Admin:", deployer);
        console2.log("Fee Wallet:      ", FEE_WALLET);
        console2.log("");

        vm.startBroadcast();

        // 1. Redeploy fund-holding contracts with correct feeRecipient
        //    Constructor arg order matters — verified against source:
        //      Escrow:  (usdc, feeCalc, protocolAdmin, feeRecipient, keyRegistry)
        //      Tab:     (usdc, feeCalc, feeRecipient, protocolAdmin, keyRegistry)
        //      Stream:  (usdc, feeCalc, feeRecipient, protocolAdmin, keyRegistry)
        address newEscrow = address(new RemitEscrow(USDC, FEE_CALC, deployer, FEE_WALLET, KEY_REGISTRY));
        address newTab = address(new RemitTab(USDC, FEE_CALC, FEE_WALLET, deployer, KEY_REGISTRY));
        address newStream = address(new RemitStream(USDC, FEE_CALC, FEE_WALLET, deployer, KEY_REGISTRY));

        console2.log("New Escrow: ", newEscrow);
        console2.log("New Tab:    ", newTab);
        console2.log("New Stream: ", newStream);

        // 2. Redeploy OnrampVaultFactory (also has immutable feeRecipient)
        RemitOnrampVault vaultImpl = new RemitOnrampVault();
        address newFactory = address(new OnrampVaultFactory(address(vaultImpl), USDC, FEE_WALLET));
        console2.log("New VaultImpl:   ", address(vaultImpl));
        console2.log("New VaultFactory:", newFactory);

        // 3. Authorize new contracts with FeeCalculator
        RemitFeeCalculator(FEE_CALC).authorizeCaller(newEscrow);
        RemitFeeCalculator(FEE_CALC).authorizeCaller(newTab);
        RemitFeeCalculator(FEE_CALC).authorizeCaller(newStream);

        // 4. Authorize with KeyRegistry
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(newEscrow);
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(newTab);
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(newStream);

        // 5. Update Router: point to new contracts + fix feeRecipient
        RemitRouter(ROUTER).setEscrow(newEscrow);
        RemitRouter(ROUTER).setTab(newTab);
        RemitRouter(ROUTER).setStream(newStream);
        RemitRouter(ROUTER).setFeeRecipient(FEE_WALLET);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Update server .env ===");
        console2.log("ESCROW_ADDRESS=", newEscrow);
        console2.log("TAB_ADDRESS=", newTab);
        console2.log("STREAM_ADDRESS=", newStream);
        console2.log("ONRAMP_VAULT_FACTORY_ADDRESS=", newFactory);
        console2.log("");
        console2.log("=== Unchanged ===");
        console2.log("BOUNTY_ADDRESS=", BOUNTY);
        console2.log("FEE_WALLET=", FEE_WALLET);
        console2.log("");
        console2.log("Then: approve USDC allowance for relayer on new Escrow, Tab, Stream");
    }
}
