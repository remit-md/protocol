// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitEscrow} from "../src/RemitEscrow.sol";
import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";
import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {RemitArbitration} from "../src/RemitArbitration.sol";
import {RemitRouter} from "../src/RemitRouter.sol";

/// @title RedeployEscrow
/// @notice V14 Campaign 1: Redeploy Escrow with `For` variants (relayer auth).
///         - Deploys new RemitEscrow (immutable, new code with For variants)
///         - Authorizes with FeeCalculator, KeyRegistry, Arbitration
///         - Updates Router to point to new Escrow
///         - Authorizes the server relayer on the new Escrow
///
/// @dev Must be run by the 0x3267 deployer (owns Router, FeeCalc, KeyRegistry, Arbitration).
///
///      forge script script/RedeployEscrow.s.sol \
///        --broadcast \
///        --rpc-url $ALCHEMY_BASE_SEPOLIA_URL \
///        --private-key $DEPLOYER_PRIVATE_KEY
contract RedeployEscrow is Script {
    // Infrastructure (do NOT redeploy)
    address constant USDC = 0x2d846325766921935f37d5b4478196d3ef93707c;
    address constant FEE_CALC = 0xcce1b8cee59f860578bed3c05fe2a80eea04aafb;
    address constant KEY_REGISTRY = 0xf5ba0baa124885eb88ad225e81a60864d5e43074;
    address constant ARBITRATION = 0x4b88c779c970314216b97ca94cb6d380db57ce91;
    address constant ROUTER = 0x3120f396ff6a9afc5a9d92e28796082f1429e024;
    address constant FEE_WALLET = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    // Server relayer (same key that submits all on-chain txns)
    address constant RELAYER = 0x3267B8B2D4A43F7eEd02B11a1564Faf8C9617020;

    function run() external {
        address deployer = msg.sender;
        console2.log("=== V14 C1: Redeploy Escrow with For variants ===");
        console2.log("Deployer:", deployer);

        vm.startBroadcast();

        // 1. Deploy new Escrow (constructor: usdc, feeCalc, protocolAdmin, feeRecipient, keyRegistry, arbitration)
        address newEscrow = address(new RemitEscrow(USDC, FEE_CALC, deployer, FEE_WALLET, KEY_REGISTRY, ARBITRATION));
        console2.log("New Escrow:", newEscrow);

        // 2. Authorize with FeeCalculator (so Escrow can call calculateFee/recordTransaction)
        RemitFeeCalculator(FEE_CALC).authorizeCaller(newEscrow);

        // 3. Authorize with KeyRegistry (so Escrow can validate session keys)
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(newEscrow);

        // 4. Authorize with Arbitration (so Escrow can escalate disputes)
        RemitArbitration(ARBITRATION).authorizeEscrow(newEscrow);

        // 5. Update Router to point to new Escrow
        RemitRouter(ROUTER).setEscrow(newEscrow);

        // 6. Authorize server relayer on new Escrow
        RemitEscrow(newEscrow).authorizeRelayer(RELAYER);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Update GitHub secret ===");
        console2.log("ESCROW_ADDRESS=", newEscrow);
        console2.log("");
        console2.log("Relayer authorized:", RELAYER);
        console2.log("Router.escrow updated");
    }
}
