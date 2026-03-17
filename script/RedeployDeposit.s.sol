// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitDeposit} from "../src/RemitDeposit.sol";
import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {RemitRouter} from "../src/RemitRouter.sol";

/// @title RedeployDeposit
/// @notice Redeploy RemitDeposit with For-variant relayer support + protocolAdmin.
///         Authorizes the deployer as relayer (deployer = server signing key on production).
///
/// @dev Run with:
///      source .env.testnet && forge script script/RedeployDeposit.s.sol \
///        --broadcast --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY
contract RedeployDeposit is Script {
    address constant USDC = 0xb6302F6aF30bA13d51CEd27ACF0279AD3c4e4497;
    address constant KEY_REGISTRY = 0x53eC0c47bE3dD330aDb123E074cA8E618fd82eDC;
    address constant ROUTER = 0x887536bD817B758f99F090a80F48032a24f50916;

    function run() external {
        address deployer = msg.sender;
        console2.log("=== Redeploy Deposit with relayer support ===");
        console2.log("Deployer / Relayer:", deployer);

        vm.startBroadcast();

        // 1. Deploy new Deposit with protocolAdmin
        RemitDeposit newDeposit = new RemitDeposit(USDC, KEY_REGISTRY, deployer);
        console2.log("New Deposit:", address(newDeposit));

        // 2. Authorize deployer as relayer (deployer = server signing key on production)
        newDeposit.authorizeRelayer(deployer);
        console2.log("Relayer authorized:", deployer);

        // 3. Authorize with KeyRegistry
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(address(newDeposit));

        // 4. Update Router to point to new Deposit
        RemitRouter(ROUTER).setDeposit(address(newDeposit));

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Update server .env ===");
        console2.log("DEPOSIT_ADDRESS=", address(newDeposit));
    }
}
