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
import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {RemitArbitration} from "../src/RemitArbitration.sol";

/// @title Deploy
/// @notice Production deployment script for all Remit protocol contracts.
/// @dev Run with:
///      forge script script/Deploy.s.sol --broadcast --rpc-url $RPC_URL
///
///      Required env vars:
///        PROTOCOL_ADMIN   — address that resolves disputes and approves upgrades
///        FEE_RECIPIENT    — address that receives protocol fees
///        USDC_ADDRESS     — USDC token address on target chain
///
///      The deployer account (--account or --private-key) becomes the initial
///      owner of both UUPS proxies and must call transferOwnership afterwards if needed.
contract Deploy is Script {
    // Deployed addresses (set during run, logged in summary)
    address internal _feeCalcProxy;
    address internal _keyRegistry;
    address internal _arbitration;
    address internal _routerProxy;
    address internal _escrow;
    address internal _tab;
    address internal _stream;
    address internal _bounty;
    address internal _deposit;

    function run() external {
        address deployer = msg.sender;
        address protocolAdmin = vm.envAddress("PROTOCOL_ADMIN");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        address usdcAddr = vm.envAddress("USDC_ADDRESS");

        console2.log("Deployer:      ", deployer);
        console2.log("Protocol admin:", protocolAdmin);
        console2.log("Fee recipient: ", feeRecipient);
        console2.log("USDC:          ", usdcAddr);
        console2.log("");

        vm.startBroadcast();
        _deployFeeCalculator(deployer);
        _deployKeyRegistry(deployer);
        _deployArbitration(deployer, usdcAddr);
        _deployFundHolding(usdcAddr, protocolAdmin, feeRecipient);
        _authorizeFundHolding();
        _authorizeKeyRegistry();
        _authorizeArbitration();
        _deployRouter(deployer, usdcAddr, protocolAdmin, feeRecipient);
        _wireRouter();
        vm.stopBroadcast();

        _logSummary();
    }

    function _deployFeeCalculator(address owner) internal {
        RemitFeeCalculator impl = new RemitFeeCalculator();
        bytes memory initData = abi.encodeCall(impl.initialize, (owner));
        _feeCalcProxy = address(new ERC1967Proxy(address(impl), initData));
        console2.log("FeeCalculator (impl):  ", address(impl));
        console2.log("FeeCalculator (proxy): ", _feeCalcProxy);
    }

    function _deployKeyRegistry(address owner) internal {
        _keyRegistry = address(new RemitKeyRegistry(owner));
        console2.log("RemitKeyRegistry:", _keyRegistry);
    }

    function _deployArbitration(address owner, address usdcAddr) internal {
        _arbitration = address(new RemitArbitration(usdcAddr, owner));
        console2.log("RemitArbitration:", _arbitration);
    }

    function _deployFundHolding(address usdcAddr, address protocolAdmin, address feeRecipient) internal {
        _escrow =
            address(new RemitEscrow(usdcAddr, _feeCalcProxy, protocolAdmin, feeRecipient, _keyRegistry, _arbitration));
        console2.log("RemitEscrow:   ", _escrow);

        _tab = address(new RemitTab(usdcAddr, _feeCalcProxy, feeRecipient, protocolAdmin, _keyRegistry));
        console2.log("RemitTab:      ", _tab);

        _stream = address(new RemitStream(usdcAddr, _feeCalcProxy, feeRecipient, _keyRegistry));
        console2.log("RemitStream:   ", _stream);

        _bounty = address(new RemitBounty(usdcAddr, _feeCalcProxy, feeRecipient, protocolAdmin, _keyRegistry));
        console2.log("RemitBounty:   ", _bounty);

        _deposit = address(new RemitDeposit(usdcAddr, _keyRegistry));
        console2.log("RemitDeposit:  ", _deposit);
    }

    function _authorizeKeyRegistry() internal {
        RemitKeyRegistry kr = RemitKeyRegistry(_keyRegistry);
        kr.authorizeContract(_escrow);
        kr.authorizeContract(_tab);
        kr.authorizeContract(_stream);
        kr.authorizeContract(_bounty);
        kr.authorizeContract(_deposit);
    }

    function _authorizeArbitration() internal {
        RemitArbitration arb = RemitArbitration(_arbitration);
        arb.authorizeEscrow(_escrow);
    }

    function _authorizeFundHolding() internal {
        RemitFeeCalculator feeCalc = RemitFeeCalculator(_feeCalcProxy);
        feeCalc.authorizeCaller(_escrow);
        feeCalc.authorizeCaller(_tab);
        feeCalc.authorizeCaller(_stream);
        feeCalc.authorizeCaller(_bounty);
        // Note: RemitDeposit has no fee, does not need authorization.
    }

    function _deployRouter(address owner, address usdcAddr, address protocolAdmin, address feeRecipient) internal {
        RemitRouter impl = new RemitRouter();
        bytes memory initData = abi.encodeCall(
            impl.initialize,
            (RemitRouter.RouterConfig({
                    owner: owner,
                    usdc: usdcAddr,
                    feeCalculator: _feeCalcProxy,
                    protocolAdmin: protocolAdmin,
                    feeRecipient: feeRecipient
                }))
        );
        _routerProxy = address(new ERC1967Proxy(address(impl), initData));
        console2.log("RemitRouter (impl):    ", address(impl));
        console2.log("RemitRouter (proxy):   ", _routerProxy);
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

    function _logSummary() internal view {
        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("FeeCalculator: ", _feeCalcProxy);
        console2.log("KeyRegistry:   ", _keyRegistry);
        console2.log("Arbitration:   ", _arbitration);
        console2.log("Router:        ", _routerProxy);
        console2.log("Escrow:        ", _escrow);
        console2.log("Tab:           ", _tab);
        console2.log("Stream:        ", _stream);
        console2.log("Bounty:        ", _bounty);
        console2.log("Deposit:       ", _deposit);
    }
}
