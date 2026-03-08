// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";
import {RemitRouter} from "../src/RemitRouter.sol";
import {RemitEscrow} from "../src/RemitEscrow.sol";
import {RemitTab} from "../src/RemitTab.sol";
import {RemitStream} from "../src/RemitStream.sol";
import {RemitBounty} from "../src/RemitBounty.sol";
import {RemitDeposit} from "../src/RemitDeposit.sol";
import {MockUSDC} from "../src/test/MockUSDC.sol";

/// @title DeployLocal
/// @notice Local development deployment. Deploys MockUSDC and mints test tokens.
/// @dev Run with:
///      forge script script/DeployLocal.s.sol --broadcast --rpc-url http://localhost:8545
///
///      Uses the first Anvil account as deployer/admin/feeRecipient.
///      Mints $1,000,000 USDC to the deployer for testing.
contract DeployLocal is Script {
    // Deployed addresses (set during run, logged in summary)
    address internal _usdc;
    address internal _feeCalcProxy;
    address internal _routerProxy;
    address internal _escrow;
    address internal _tab;
    address internal _stream;
    address internal _bounty;
    address internal _deposit;

    function run() external {
        address deployer = msg.sender;

        console2.log("=== Local Deployment ===");
        console2.log("Deployer:", deployer);
        console2.log("");

        vm.startBroadcast();
        _deployMockUSDC();
        _deployFeeCalculator(deployer);
        _deployFundHolding(deployer, deployer);
        _authorizeFundHolding();
        _deployRouter(deployer, deployer, deployer);
        _wireRouter();
        _mintTestTokens(deployer);
        vm.stopBroadcast();

        _logSummary();
    }

    function _deployMockUSDC() internal {
        _usdc = address(new MockUSDC());
        console2.log("MockUSDC:", _usdc);
    }

    function _deployFeeCalculator(address owner) internal {
        RemitFeeCalculator impl = new RemitFeeCalculator();
        bytes memory initData = abi.encodeCall(impl.initialize, (owner));
        _feeCalcProxy = address(new ERC1967Proxy(address(impl), initData));
        console2.log("FeeCalculator:", _feeCalcProxy);
    }

    function _deployFundHolding(address protocolAdmin, address feeRecipient) internal {
        _escrow = address(new RemitEscrow(_usdc, _feeCalcProxy, protocolAdmin, feeRecipient));
        _tab = address(new RemitTab(_usdc, _feeCalcProxy, feeRecipient));
        _stream = address(new RemitStream(_usdc, _feeCalcProxy, feeRecipient));
        _bounty = address(new RemitBounty(_usdc, _feeCalcProxy, feeRecipient));
        _deposit = address(new RemitDeposit(_usdc));
        console2.log("Escrow:  ", _escrow);
        console2.log("Tab:     ", _tab);
        console2.log("Stream:  ", _stream);
        console2.log("Bounty:  ", _bounty);
        console2.log("Deposit: ", _deposit);
    }

    function _authorizeFundHolding() internal {
        RemitFeeCalculator feeCalc = RemitFeeCalculator(_feeCalcProxy);
        feeCalc.authorizeCaller(_escrow);
        feeCalc.authorizeCaller(_tab);
        feeCalc.authorizeCaller(_stream);
        feeCalc.authorizeCaller(_bounty);
    }

    function _deployRouter(address owner, address protocolAdmin, address feeRecipient) internal {
        RemitRouter impl = new RemitRouter();
        bytes memory initData = abi.encodeCall(
            impl.initialize,
            (RemitRouter.RouterConfig({
                    owner: owner,
                    usdc: _usdc,
                    feeCalculator: _feeCalcProxy,
                    protocolAdmin: protocolAdmin,
                    feeRecipient: feeRecipient
                }))
        );
        _routerProxy = address(new ERC1967Proxy(address(impl), initData));
        console2.log("Router:  ", _routerProxy);
    }

    function _wireRouter() internal {
        RemitRouter router = RemitRouter(_routerProxy);
        router.setEscrow(_escrow);
        router.setTab(_tab);
        router.setStream(_stream);
        router.setBounty(_bounty);
        router.setDeposit(_deposit);
        RemitFeeCalculator(_feeCalcProxy).authorizeCaller(_routerProxy);
    }

    function _mintTestTokens(address deployer) internal {
        MockUSDC usdc = MockUSDC(_usdc);
        usdc.mint(deployer, 1_000_000e6); // $1M for deployer
        usdc.mint(address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8), 100_000e6); // Anvil #1
        usdc.mint(address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC), 100_000e6); // Anvil #2
    }

    function _logSummary() internal view {
        console2.log("");
        console2.log("=== Local Deployment Complete ===");
        console2.log("MockUSDC:     ", _usdc);
        console2.log("FeeCalculator:", _feeCalcProxy);
        console2.log("Router:       ", _routerProxy);
        console2.log("Escrow:       ", _escrow);
        console2.log("Tab:          ", _tab);
        console2.log("Stream:       ", _stream);
        console2.log("Bounty:       ", _bounty);
        console2.log("Deposit:      ", _deposit);
    }
}
