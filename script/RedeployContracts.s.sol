// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitEscrow} from "../src/RemitEscrow.sol";
import {RemitTab} from "../src/RemitTab.sol";
import {RemitStream} from "../src/RemitStream.sol";
import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";
import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {RemitArbitration} from "../src/RemitArbitration.sol";
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
/// @dev Must be run by the 0x3267 deployer (owns Router, FeeCalc, KeyRegistry, Arbitration).
///
///      forge script script/RedeployContracts.s.sol \
///        --broadcast \
///        --rpc-url $ALCHEMY_BASE_SEPOLIA_URL \
///        --private-key $DEPLOYER_PRIVATE_KEY
contract RedeployContracts is Script {
    // ---- Infrastructure (do NOT redeploy — proxies or shared contracts) ----
    address constant USDC = 0x2d846325766921935f37d5b4478196d3ef93707c;
    address constant FEE_CALC = 0xcce1b8cee59f860578bed3c05fe2a80eea04aafb;
    address constant KEY_REGISTRY = 0xf5ba0baa124885eb88ad225e81a60864d5e43074;
    address constant ARBITRATION = 0x4b88c779c970314216b97ca94cb6d380db57ce91;
    address constant ROUTER = 0x3120f396ff6a9afc5a9d92e28796082f1429e024;

    // ---- Contracts that are already correct (skip) ----
    address constant BOUNTY = 0xb3868471c3034280cce3a56dd37c6154c3bb0b32;

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
        //      Escrow:  (usdc, feeCalc, protocolAdmin, feeRecipient, keyRegistry, arbitration)
        //      Tab:     (usdc, feeCalc, feeRecipient, protocolAdmin, keyRegistry)
        //      Stream:  (usdc, feeCalc, feeRecipient, protocolAdmin, keyRegistry)
        address newEscrow = address(new RemitEscrow(USDC, FEE_CALC, deployer, FEE_WALLET, KEY_REGISTRY, ARBITRATION));
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

        // 5. Authorize Escrow with Arbitration
        RemitArbitration(ARBITRATION).authorizeEscrow(newEscrow);

        // 6. Update Router: point to new contracts + fix feeRecipient
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
