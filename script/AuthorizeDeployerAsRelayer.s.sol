// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitRouter} from "../src/RemitRouter.sol";
import {RemitEscrow} from "../src/RemitEscrow.sol";
import {RemitTab} from "../src/RemitTab.sol";
import {RemitStream} from "../src/RemitStream.sol";
import {RemitBounty} from "../src/RemitBounty.sol";
import {RemitDeposit} from "../src/RemitDeposit.sol";

/// @title AuthorizeDeployerAsRelayer
/// @notice Authorize the deployer address as relayer on ALL contracts.
///         Must be run after any full redeploy (DeployTestnet.s.sol).
///
/// @dev Must be run by the deployer (who is protocolAdmin on all contracts).
///
///      forge script script/AuthorizeDeployerAsRelayer.s.sol \
///        --broadcast \
///        --rpc-url $ALCHEMY_BASE_SEPOLIA_URL \
///        --private-key $DEPLOYER_PRIVATE_KEY
contract AuthorizeDeployerAsRelayer is Script {
    address constant ROUTER = 0x3120F396fF6A9aFc5a9D92e28796082F1429e024;
    address constant ESCROW = 0x47De7cDD757e3765d36C083dAb59B2c5A9d249f2;
    address constant TAB = 0x9415f510D8C6199e0f66Bde927D7d88dE391f5E8;
    address constant STREAM = 0x20d413e0eaC0f5da3c8630667FD16A94fCd7231A;
    address constant BOUNTY = 0xB3868471c3034280ccE3a56DD37C6154c3Bb0B32;
    address constant DEPOSIT = 0x7E0ae37DF62E93c1c16A5661a7998bd174331554;

    function run() external {
        address deployer = msg.sender;
        console2.log("=== Authorize deployer as relayer ===");
        console2.log("Deployer/relayer:", deployer);

        vm.startBroadcast();

        RemitRouter(ROUTER).authorizeRelayer(deployer);
        console2.log("Router: relayer authorized");

        RemitEscrow(ESCROW).authorizeRelayer(deployer);
        console2.log("Escrow: relayer authorized");

        RemitTab(TAB).authorizeRelayer(deployer);
        console2.log("Tab: relayer authorized");

        RemitStream(STREAM).authorizeRelayer(deployer);
        console2.log("Stream: relayer authorized");

        RemitBounty(BOUNTY).authorizeRelayer(deployer);
        console2.log("Bounty: relayer authorized");

        RemitDeposit(DEPOSIT).authorizeRelayer(deployer);
        console2.log("Deposit: relayer authorized");

        vm.stopBroadcast();

        console2.log("Done. All 6 contracts now accept txns from deployer.");
    }
}
