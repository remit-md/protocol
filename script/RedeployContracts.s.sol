// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitEscrow} from "../src/RemitEscrow.sol";
import {RemitTab} from "../src/RemitTab.sol";
import {RemitStream} from "../src/RemitStream.sol";
import {RemitBounty} from "../src/RemitBounty.sol";
import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";
import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {RemitArbitration} from "../src/RemitArbitration.sol";
import {RemitRouter} from "../src/RemitRouter.sol";

/// @title RedeployContracts
/// @notice Redeploy all fund-holding contracts with a dedicated fee wallet.
///         Also upgrades the Router to set the new feeRecipient.
///
/// @dev Run with:
///      forge script script/RedeployContracts.s.sol \
///        --broadcast --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY
contract RedeployContracts is Script {
    // Existing contracts (do NOT redeploy — proxies or infrastructure)
    address constant USDC = 0xb6302F6aF30bA13d51CEd27ACF0279AD3c4e4497;
    address constant FEE_CALC = 0x274F4B69F4aa102ABA6ad8bD8dE30d4733306C25;
    address constant KEY_REGISTRY = 0x53eC0c47bE3dD330aDb123E074cA8E618fd82eDC;
    address constant ARBITRATION = 0x9d0Bbdfa1036AAF88e567402e792f09cD650659A;
    address constant ROUTER = 0x887536bD817B758f99F090a80F48032a24f50916;

    // Dedicated fee wallet (only receives fees, never sends)
    address constant FEE_WALLET = 0xd3f721BDF92a2bB5Dd8d2FE2AFC03aFE5629B420;

    function run() external {
        address deployer = msg.sender;
        console2.log("=== Redeploy with dedicated fee wallet ===");
        console2.log("Deployer / Admin:", deployer);
        console2.log("Fee Wallet:", FEE_WALLET);

        vm.startBroadcast();

        // 1. Deploy new fund-holding contracts with FEE_WALLET as feeRecipient
        address newEscrow = address(new RemitEscrow(USDC, FEE_CALC, FEE_WALLET, deployer, KEY_REGISTRY, ARBITRATION));
        address newTab = address(new RemitTab(USDC, FEE_CALC, FEE_WALLET, deployer, KEY_REGISTRY));
        address newStream = address(new RemitStream(USDC, FEE_CALC, FEE_WALLET, KEY_REGISTRY));
        address newBounty = address(new RemitBounty(USDC, FEE_CALC, FEE_WALLET, deployer, KEY_REGISTRY));

        console2.log("New Escrow:", newEscrow);
        console2.log("New Tab:", newTab);
        console2.log("New Stream:", newStream);
        console2.log("New Bounty:", newBounty);

        // 2. Authorize new contracts with FeeCalculator
        RemitFeeCalculator(FEE_CALC).authorizeCaller(newEscrow);
        RemitFeeCalculator(FEE_CALC).authorizeCaller(newTab);
        RemitFeeCalculator(FEE_CALC).authorizeCaller(newStream);
        RemitFeeCalculator(FEE_CALC).authorizeCaller(newBounty);

        // 3. Authorize with KeyRegistry
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(newEscrow);
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(newTab);
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(newStream);
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(newBounty);

        // 4. Authorize Escrow with Arbitration
        RemitArbitration(ARBITRATION).authorizeEscrow(newEscrow);

        // 5. Update Router contract references + feeRecipient
        RemitRouter(ROUTER).setEscrow(newEscrow);
        RemitRouter(ROUTER).setTab(newTab);
        RemitRouter(ROUTER).setStream(newStream);
        RemitRouter(ROUTER).setBounty(newBounty);
        RemitRouter(ROUTER).setFeeRecipient(FEE_WALLET);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Update server .env ===");
        console2.log("ESCROW_ADDRESS=", newEscrow);
        console2.log("TAB_ADDRESS=", newTab);
        console2.log("STREAM_ADDRESS=", newStream);
        console2.log("BOUNTY_ADDRESS=", newBounty);
        console2.log("FEE_WALLET=", FEE_WALLET);
        console2.log("");
        console2.log("Then run: scripts/approve-relayer.sh with new addresses");
    }
}
