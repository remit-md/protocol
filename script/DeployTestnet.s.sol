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
import {RemitOnrampVault} from "../src/RemitOnrampVault.sol";
import {OnrampVaultFactory} from "../src/OnrampVaultFactory.sol";
import {MockUSDC} from "../src/test/MockUSDC.sol";

/// @title DeployTestnet
/// @notice Testnet deployment script. Deploys MockUSDC + full protocol.
///         The deployer is set as protocol admin and fee recipient.
///         MockUSDC has open minting so the server faucet endpoint works.
///
/// @dev Run with:
///      forge script script/DeployTestnet.s.sol \
///        --broadcast \
///        --rpc-url $ALCHEMY_BASE_SEPOLIA_URL \
///        --private-key $DEPLOYER_PRIVATE_KEY \
///        --verify \
///        --etherscan-api-key $ETHERSCAN_API_KEY
contract DeployTestnet is Script {
    address internal _usdc;
    address internal _feeCalcProxy;
    address internal _keyRegistry;
    address internal _routerProxy;
    address internal _escrow;
    address internal _tab;
    address internal _stream;
    address internal _bounty;
    address internal _deposit;
    address internal _onrampVaultFactory;

    function run() external {
        address deployer = msg.sender;

        console2.log("=== Testnet Deployment (Base Sepolia) ===");
        console2.log("Deployer / Admin / Fee Recipient:", deployer);
        console2.log("");

        vm.startBroadcast();
        _deployMockUSDC();
        _deployFeeCalculator(deployer);
        _deployKeyRegistry(deployer);
        _deployFundHolding(deployer, deployer);
        _authorizeFundHolding();
        _authorizeKeyRegistry();
        _deployRouter(deployer, deployer, deployer);
        _wireRouter();
        _deployOnrampVaultFactory(deployer);
        // Mint $1M USDC to deployer for faucet seeding.
        MockUSDC(_usdc).mint(deployer, 1_000_000e6);
        vm.stopBroadcast();

        _logSummary(deployer);
    }

    function _deployMockUSDC() internal {
        _usdc = address(new MockUSDC());
        console2.log("MockUSDC:", _usdc);
    }

    function _deployFeeCalculator(address owner) internal {
        RemitFeeCalculator impl = new RemitFeeCalculator();
        bytes memory initData = abi.encodeCall(impl.initialize, (owner));
        _feeCalcProxy = address(new ERC1967Proxy(address(impl), initData));
        console2.log("FeeCalculator (proxy):", _feeCalcProxy);
    }

    function _deployKeyRegistry(address owner) internal {
        _keyRegistry = address(new RemitKeyRegistry(owner));
        console2.log("KeyRegistry:", _keyRegistry);
    }

    function _deployFundHolding(address protocolAdmin, address feeRecipient) internal {
        _escrow =
            address(new RemitEscrow(_usdc, _feeCalcProxy, protocolAdmin, feeRecipient, _keyRegistry));
        _tab = address(new RemitTab(_usdc, _feeCalcProxy, feeRecipient, protocolAdmin, _keyRegistry));
        _stream = address(new RemitStream(_usdc, _feeCalcProxy, feeRecipient, protocolAdmin, _keyRegistry));
        _bounty = address(new RemitBounty(_usdc, _feeCalcProxy, feeRecipient, protocolAdmin, _keyRegistry));
        _deposit = address(new RemitDeposit(_usdc, _keyRegistry, protocolAdmin));
        console2.log("Escrow: ", _escrow);
        console2.log("Tab:    ", _tab);
        console2.log("Stream: ", _stream);
        console2.log("Bounty: ", _bounty);
        console2.log("Deposit:", _deposit);
    }

    function _authorizeKeyRegistry() internal {
        RemitKeyRegistry kr = RemitKeyRegistry(_keyRegistry);
        kr.authorizeContract(_escrow);
        kr.authorizeContract(_tab);
        kr.authorizeContract(_stream);
        kr.authorizeContract(_bounty);
        kr.authorizeContract(_deposit);
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
        console2.log("Router (proxy):", _routerProxy);
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

    function _deployOnrampVaultFactory(address feeRecipient) internal {
        RemitOnrampVault vaultImpl = new RemitOnrampVault();
        _onrampVaultFactory = address(new OnrampVaultFactory(address(vaultImpl), _usdc, feeRecipient));
        console2.log("OnrampVault (impl):", address(vaultImpl));
        console2.log("OnrampVaultFactory:", _onrampVaultFactory);
    }

    function _logSummary(address deployer) internal view {
        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("Network:      Base Sepolia (chainId 84532)");
        console2.log("Deployer:    ", deployer);
        console2.log("MockUSDC:    ", _usdc);
        console2.log("KeyRegistry: ", _keyRegistry);
        console2.log("FeeCalc:     ", _feeCalcProxy);
        console2.log("Router:      ", _routerProxy);
        console2.log("Escrow:      ", _escrow);
        console2.log("Tab:         ", _tab);
        console2.log("Stream:      ", _stream);
        console2.log("Bounty:      ", _bounty);
        console2.log("Deposit:     ", _deposit);
        console2.log("VaultFactory:", _onrampVaultFactory);
        console2.log("");
        console2.log("=== Hetzner .env snippet ===");
        console2.log("CHAIN_ID=84532");
        console2.log("RPC_URL=<alchemy_base_sepolia_url>");
        console2.log("SERVER_SIGNING_KEY=<deployer_private_key>");
        console2.log("USDC_ADDRESS=", _usdc);
        console2.log("ROUTER_ADDRESS=", _routerProxy);
        console2.log("ESCROW_ADDRESS=", _escrow);
        console2.log("TAB_ADDRESS=", _tab);
        console2.log("STREAM_ADDRESS=", _stream);
        console2.log("BOUNTY_ADDRESS=", _bounty);
        console2.log("DEPOSIT_ADDRESS=", _deposit);
        console2.log("ONRAMP_VAULT_FACTORY_ADDRESS=", _onrampVaultFactory);
    }
}
