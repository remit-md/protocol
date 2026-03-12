// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {RemitOnrampVault} from "../src/RemitOnrampVault.sol";
import {OnrampVaultFactory} from "../src/OnrampVaultFactory.sol";

/// @title DeployOnrampVault
/// @notice Deploys RemitOnrampVault implementation + OnrampVaultFactory only.
///         Use when the rest of the protocol is already deployed.
///
/// @dev Requires env vars: USDC_ADDRESS, FEE_RECIPIENT
///
///      forge script script/DeployOnrampVault.s.sol \
///        --broadcast \
///        --rpc-url $ALCHEMY_BASE_SEPOLIA_URL \
///        --private-key $DEPLOYER_PRIVATE_KEY
contract DeployOnrampVault is Script {
    function run() external {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        console2.log("USDC:", usdc);
        console2.log("Fee Recipient:", feeRecipient);

        vm.startBroadcast();

        RemitOnrampVault vaultImpl = new RemitOnrampVault();
        console2.log("RemitOnrampVault (impl):", address(vaultImpl));

        OnrampVaultFactory factory = new OnrampVaultFactory(address(vaultImpl), usdc, feeRecipient);
        console2.log("OnrampVaultFactory:", address(factory));

        vm.stopBroadcast();

        console2.log("");
        console2.log("Add to server .env:");
        console2.log("ONRAMP_VAULT_FACTORY_ADDRESS=", address(factory));
    }
}
