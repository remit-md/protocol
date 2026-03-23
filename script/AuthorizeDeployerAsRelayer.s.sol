// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitEscrow} from "../src/RemitEscrow.sol";
import {RemitTab} from "../src/RemitTab.sol";
import {RemitStream} from "../src/RemitStream.sol";

/// @title AuthorizeDeployerAsRelayer
/// @notice Authorize the deployer address as relayer on Escrow, Tab, and Stream.
///         The deploy scripts hardcoded a separate RELAYER address, but the server
///         signs with the deployer key. This script fixes the mismatch.
///
/// @dev Must be run by the deployer (who is protocolAdmin on all contracts).
///
///      forge script script/AuthorizeDeployerAsRelayer.s.sol \
///        --broadcast \
///        --rpc-url $ALCHEMY_BASE_SEPOLIA_URL \
///        --private-key $DEPLOYER_PRIVATE_KEY
contract AuthorizeDeployerAsRelayer is Script {
    address constant ESCROW = 0x47de7cdd757e3765d36c083dab59b2c5a9d249f2;
    address constant TAB = 0x9415f510d8c6199e0f66bde927d7d88de391f5e8;
    address constant STREAM = 0x20d413e0eac0f5da3c8630667fd16a94fcd7231a;

    function run() external {
        address deployer = msg.sender;
        console2.log("=== Authorize deployer as relayer ===");
        console2.log("Deployer/relayer:", deployer);

        vm.startBroadcast();

        RemitEscrow(ESCROW).authorizeRelayer(deployer);
        console2.log("Escrow: relayer authorized");

        RemitTab(TAB).authorizeRelayer(deployer);
        console2.log("Tab: relayer authorized");

        RemitStream(STREAM).authorizeRelayer(deployer);
        console2.log("Stream: relayer authorized");

        vm.stopBroadcast();

        console2.log("Done. All 3 contracts now accept txns from deployer.");
    }
}
