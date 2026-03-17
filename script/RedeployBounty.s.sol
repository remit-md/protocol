// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitBounty} from "../src/RemitBounty.sol";
import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";
import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {RemitRouter} from "../src/RemitRouter.sol";

/// @title RedeployBounty
/// @notice Redeploy RemitBounty with For-variant relayer support.
///         Authorizes the deployer as relayer (deployer = server signing key on production).
///
/// @dev Run with:
///      source .env.testnet && forge script script/RedeployBounty.s.sol \
///        --broadcast --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY
contract RedeployBounty is Script {
    address constant USDC = 0xb6302F6aF30bA13d51CEd27ACF0279AD3c4e4497;
    address constant FEE_CALC = 0x274F4B69F4aa102ABA6ad8bD8dE30d4733306C25;
    address constant KEY_REGISTRY = 0x53eC0c47bE3dD330aDb123E074cA8E618fd82eDC;
    address constant ROUTER = 0x887536bD817B758f99F090a80F48032a24f50916;
    address constant FEE_WALLET = 0xd3f721BDF92a2bB5Dd8d2FE2AFC03aFE5629B420;

    function run() external {
        address deployer = msg.sender;
        console2.log("=== Redeploy Bounty with relayer support ===");
        console2.log("Deployer / Relayer:", deployer);

        vm.startBroadcast();

        // 1. Deploy new Bounty with For-variants
        RemitBounty newBounty = new RemitBounty(USDC, FEE_CALC, FEE_WALLET, deployer, KEY_REGISTRY);
        console2.log("New Bounty:", address(newBounty));

        // 2. Authorize deployer as relayer (deployer = server signing key on production)
        newBounty.authorizeRelayer(deployer);
        console2.log("Relayer authorized:", deployer);

        // 3. Authorize with FeeCalculator
        RemitFeeCalculator(FEE_CALC).authorizeCaller(address(newBounty));

        // 4. Authorize with KeyRegistry
        RemitKeyRegistry(KEY_REGISTRY).authorizeContract(address(newBounty));

        // 5. Update Router to point to new Bounty
        RemitRouter(ROUTER).setBounty(address(newBounty));

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Update server .env ===");
        console2.log("BOUNTY_ADDRESS=", address(newBounty));
    }
}
