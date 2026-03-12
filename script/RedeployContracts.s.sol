// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitEscrow} from "../src/RemitEscrow.sol";
import {RemitStream} from "../src/RemitStream.sol";
import {RemitBounty} from "../src/RemitBounty.sol";
import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";
import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {RemitArbitration} from "../src/RemitArbitration.sol";
import {RemitRouter} from "../src/RemitRouter.sol";

/// @title RedeployContracts
/// @notice Targeted redeployment of Escrow, Stream, Bounty when contract ABIs change.
///         Reuses existing MockUSDC, FeeCalculator, KeyRegistry, Router, Arbitration.
///
/// @dev Run with:
///      forge script script/RedeployContracts.s.sol \
///        --broadcast --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY
contract RedeployContracts is Script {
    // Existing contracts (do NOT redeploy)
    address constant USDC = 0xb6302F6aF30bA13d51CEd27ACF0279AD3c4e4497;
    address constant FEE_CALC = 0x274F4B69F4aa102ABA6ad8bD8dE30d4733306C25;
    address constant KEY_REGISTRY = 0x53eC0c47bE3dD330aDb123E074cA8E618fd82eDC;
    address constant ARBITRATION = 0x9d0Bbdfa1036AAF88e567402e792f09cD650659A;
    address constant ROUTER = 0x63d62554CDC9C50bf998339888116D02e0a34A3b;

    function run() external {
        address deployer = msg.sender;
        console2.log("Deployer / Admin / Fee Recipient:", deployer);

        vm.startBroadcast();

        // 1. Deploy new contracts
        address escrow = address(new RemitEscrow(USDC, FEE_CALC, deployer, deployer, KEY_REGISTRY, ARBITRATION));
        address stream = address(new RemitStream(USDC, FEE_CALC, deployer, KEY_REGISTRY));
        address bounty = address(new RemitBounty(USDC, FEE_CALC, deployer, deployer, KEY_REGISTRY));

        console2.log("New Escrow:", escrow);
        console2.log("New Stream:", stream);
        console2.log("New Bounty:", bounty);

        // 2. Authorize with FeeCalculator
        RemitFeeCalculator(FEE_CALC).authorizeCaller(escrow);
        RemitFeeCalculator(FEE_CALC).authorizeCaller(stream);
        RemitFeeCalculator(FEE_CALC).authorizeCaller(bounty);

        // 3. Authorize with KeyRegistry
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(escrow);
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(stream);
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(bounty);

        // 4. Authorize Escrow with Arbitration
        RemitArbitration(ARBITRATION).authorizeEscrow(escrow);

        // 5. Update Router
        RemitRouter(ROUTER).setEscrow(escrow);
        RemitRouter(ROUTER).setStream(stream);
        RemitRouter(ROUTER).setBounty(bounty);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Update server .env ===");
        console2.log("ESCROW_ADDRESS=", escrow);
        console2.log("STREAM_ADDRESS=", stream);
        console2.log("BOUNTY_ADDRESS=", bounty);
        console2.log("");
        console2.log("Then run: scripts/approve-relayer.sh with new addresses");
    }
}
