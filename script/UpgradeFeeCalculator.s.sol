// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";

/// @title UpgradeFeeCalculator
/// @notice Upgrades the FeeCalculator proxy to a new implementation (cliff + calendar month).
///
/// @dev Run with:
///      forge script script/UpgradeFeeCalculator.s.sol \
///        --broadcast --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY
///
///      Storage layout is unchanged — only function logic + a new pure helper.
contract UpgradeFeeCalculator is Script {
    /// @dev Current FeeCalculator proxy address (Base Sepolia).
    address constant FEE_CALC_PROXY = 0x274F4B69F4aa102ABA6ad8bD8dE30d4733306C25;

    function run() external {
        address deployer = msg.sender;
        console2.log("=== FeeCalculator UUPS Upgrade ===");
        console2.log("Proxy:", FEE_CALC_PROXY);
        console2.log("Owner (deployer):", deployer);

        // Verify caller is the proxy owner.
        address currentOwner = RemitFeeCalculator(FEE_CALC_PROXY).owner();
        require(currentOwner == deployer, "Deployer is not the proxy owner");

        vm.startBroadcast();

        // 1. Deploy new implementation.
        RemitFeeCalculator newImpl = new RemitFeeCalculator();
        console2.log("New implementation:", address(newImpl));

        // 2. Upgrade proxy to new implementation (no re-initialization needed).
        RemitFeeCalculator(FEE_CALC_PROXY).upgradeToAndCall(address(newImpl), "");
        console2.log("Proxy upgraded successfully.");

        vm.stopBroadcast();

        // 3. Verify the upgrade worked.
        // With cliff: volume=0 should return standard rate (100 bps on $100 = $1).
        uint96 fee = RemitFeeCalculator(FEE_CALC_PROXY).calculateFee(deployer, 100e6);
        console2.log("Verification - fee on $100 (zero volume):", fee);
        require(fee == 1e6, "Fee should be $1.00 (100 bps)");

        console2.log("");
        console2.log("=== Upgrade complete ===");
        console2.log("Changes: marginal -> cliff tiering, 30-day -> calendar month reset");
    }
}
