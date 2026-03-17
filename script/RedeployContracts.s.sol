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
    address constant USDC = 0x142aD61B8d2edD6b3807D9266866D97C35Ee0317;
    address constant FEE_CALC = 0x853CFc2387C184E4492892475adfc19A23FF2e4F;
    address constant KEY_REGISTRY = 0x97ff63c9E24Fc074023F5d1251E544dCDaC93886;
    address constant ARBITRATION = 0x3b2C97AafCdFBD5F6C9cF86dDa684Faa248008B1;
    address constant ROUTER = 0xb3E96ebE54138d1c0caea00Ae098309C7E0138eC;

    // ---- Contracts that are already correct (skip) ----
    address constant BOUNTY = 0x2D08DD3093De3F22f85300330671122300F1e01b;

    // ---- Dedicated fee wallet (only receives fees, never sends) ----
    address constant FEE_WALLET = 0xd3f721BDF92a2bB5Dd8d2FE2AFC03aFE5629B420;

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
        //      Stream:  (usdc, feeCalc, feeRecipient, keyRegistry)
        address newEscrow = address(new RemitEscrow(USDC, FEE_CALC, deployer, FEE_WALLET, KEY_REGISTRY, ARBITRATION));
        address newTab = address(new RemitTab(USDC, FEE_CALC, FEE_WALLET, deployer, KEY_REGISTRY));
        address newStream = address(new RemitStream(USDC, FEE_CALC, FEE_WALLET, KEY_REGISTRY));

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
