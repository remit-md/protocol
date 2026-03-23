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
/// @title DeployMainnet
/// @notice Mainnet deployment script. Uses real USDC (no MockUSDC).
///         Does NOT deploy OnrampVaultFactory (deimplemented at server level — D6).
///         Reads admin and fee-recipient from environment so they can be set to a
///         Gnosis Safe multi-sig before going live (highly recommended).
///
///         Ownership model: deployer is the initial owner of all ownable contracts
///         (FeeCalculator, KeyRegistry, Router) so it can configure
///         authorizations and wiring. Ownership is transferred to GNOSIS_SAFE at
///         the end. Fund-holding contracts (Escrow, Tab, Stream, Bounty, Deposit)
///         have immutable protocolAdmin set to GNOSIS_SAFE from the start.
///
/// @dev Prerequisites:
///      - DEPLOYER_PRIVATE_KEY: key with ~0.05 ETH on Base mainnet for gas
///      - GNOSIS_SAFE:          Gnosis Safe address (protocol admin + proxy owner)
///      - FEE_WALLET:           Fee recipient address (defaults to GNOSIS_SAFE)
///      - ALCHEMY_BASE_MAINNET_URL: Base mainnet RPC URL
///      - ETHERSCAN_API_KEY:    for contract verification
///
///      Run with:
///        forge script script/DeployMainnet.s.sol \
///          --broadcast \
///          --rpc-url $ALCHEMY_BASE_MAINNET_URL \
///          --private-key $DEPLOYER_PRIVATE_KEY \
///          --verify \
///          --etherscan-api-key $ETHERSCAN_API_KEY
///
///      Dry-run against Anvil fork:
///        anvil --fork-url https://mainnet.base.org
///        GNOSIS_SAFE=<safe_addr> forge script script/DeployMainnet.s.sol \
///          --rpc-url http://localhost:8545 \
///          --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
///          --broadcast
contract DeployMainnet is Script {
    // Base mainnet USDC (Circle official, 6 decimals)
    address internal constant MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address internal _feeCalcProxy;
    address internal _keyRegistry;
    address internal _routerProxy;
    address internal _escrow;
    address internal _tab;
    address internal _stream;
    address internal _bounty;
    address internal _deposit;

    function run() external {
        address deployer = msg.sender;

        // Admin: defaults to deployer when GNOSIS_SAFE is not set (dry-runs).
        // For production: set GNOSIS_SAFE to the multisig address.
        address admin = vm.envOr("GNOSIS_SAFE", deployer);
        address feeRecipient = vm.envOr("FEE_WALLET", admin);

        console2.log("=== Mainnet Deployment (Base) ===");
        console2.log("Deployer:     ", deployer);
        console2.log("Admin / Safe: ", admin);
        console2.log("Fee Recipient:", feeRecipient);
        console2.log("USDC:         ", MAINNET_USDC);
        console2.log("");

        vm.startBroadcast();

        // Step 1: Deploy ownable contracts with DEPLOYER as initial owner.
        // The deployer needs onlyOwner access to configure authorizations.
        _deployFeeCalculator(deployer);
        _deployKeyRegistry(deployer);

        // Step 2: Deploy fund-holding contracts with admin (Safe) as protocolAdmin.
        // protocolAdmin is immutable — must be the Safe from the start.
        _deployFundHolding(admin, feeRecipient);

        // Step 3: Configure authorizations (requires deployer = owner).
        _authorizeFundHolding();
        _authorizeKeyRegistry();

        // Step 4: Deploy Router with deployer as owner (for wiring),
        // but admin as protocolAdmin and feeRecipient.
        _deployRouter(deployer, admin, feeRecipient);
        _wireRouter();

        // Step 5: Transfer ownership to the Safe (if admin != deployer).
        if (admin != deployer) {
            _transferOwnership(admin);
        }

        vm.stopBroadcast();

        _logSummary(deployer, admin, feeRecipient);
    }

    function _deployFeeCalculator(address owner) internal {
        RemitFeeCalculator impl = new RemitFeeCalculator();
        bytes memory initData = abi.encodeCall(impl.initialize, (owner));
        _feeCalcProxy = address(new ERC1967Proxy(address(impl), initData));
        console2.log("FeeCalculator (proxy):", _feeCalcProxy);
    }

    function _deployKeyRegistry(address owner) internal {
        _keyRegistry = address(new RemitKeyRegistry(owner));
        console2.log("KeyRegistry:          ", _keyRegistry);
    }

    function _deployFundHolding(address protocolAdmin, address feeRecipient) internal {
        _escrow = address(new RemitEscrow(MAINNET_USDC, _feeCalcProxy, protocolAdmin, feeRecipient, _keyRegistry));
        _tab = address(new RemitTab(MAINNET_USDC, _feeCalcProxy, feeRecipient, protocolAdmin, _keyRegistry));
        _stream = address(new RemitStream(MAINNET_USDC, _feeCalcProxy, feeRecipient, protocolAdmin, _keyRegistry));
        _bounty = address(new RemitBounty(MAINNET_USDC, _feeCalcProxy, feeRecipient, protocolAdmin, _keyRegistry));
        _deposit = address(new RemitDeposit(MAINNET_USDC, _keyRegistry, protocolAdmin));
        console2.log("Escrow:               ", _escrow);
        console2.log("Tab:                  ", _tab);
        console2.log("Stream:               ", _stream);
        console2.log("Bounty:               ", _bounty);
        console2.log("Deposit:              ", _deposit);
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
                    usdc: MAINNET_USDC,
                    feeCalculator: _feeCalcProxy,
                    protocolAdmin: protocolAdmin,
                    feeRecipient: feeRecipient
                }))
        );
        _routerProxy = address(new ERC1967Proxy(address(impl), initData));
        console2.log("Router (proxy):       ", _routerProxy);
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

    function _transferOwnership(address newOwner) internal {
        RemitFeeCalculator(_feeCalcProxy).transferOwnership(newOwner);
        RemitKeyRegistry(_keyRegistry).transferOwnership(newOwner);
        RemitRouter(_routerProxy).transferOwnership(newOwner);
        console2.log("");
        console2.log("Ownership transferred to:", newOwner);
    }

    function _logSummary(address deployer, address admin, address feeRecipient) internal view {
        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("Network:       Base (chainId 8453)");
        console2.log("Deployer:      ", deployer);
        console2.log("Admin / Safe:  ", admin);
        console2.log("Fee Recipient: ", feeRecipient);
        console2.log("USDC:          ", MAINNET_USDC);
        console2.log("");
        console2.log("=== Contract Addresses ===");
        console2.log("KeyRegistry:   ", _keyRegistry);
        console2.log("FeeCalc:       ", _feeCalcProxy);
        console2.log("Router:        ", _routerProxy);
        console2.log("Escrow:        ", _escrow);
        console2.log("Tab:           ", _tab);
        console2.log("Stream:        ", _stream);
        console2.log("Bounty:        ", _bounty);
        console2.log("Deposit:       ", _deposit);
        console2.log("");
        console2.log("=== Server .env snippet ===");
        console2.log("CHAIN_ID=8453");
        console2.log("RPC_URL=<alchemy_base_mainnet_url>");
        console2.log("SERVER_SIGNING_KEY=<mainnet_relayer_private_key>");
        console2.log("USDC_ADDRESS=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913");
        console2.log("ROUTER_ADDRESS=", _routerProxy);
        console2.log("ESCROW_ADDRESS=", _escrow);
        console2.log("TAB_ADDRESS=", _tab);
        console2.log("STREAM_ADDRESS=", _stream);
        console2.log("BOUNTY_ADDRESS=", _bounty);
        console2.log("DEPOSIT_ADDRESS=", _deposit);
        console2.log("");
        console2.log("=== NEXT STEPS ===");
        console2.log("1. Run verify-deployment.sh to sanity-check all wiring");
        console2.log("2. Fund mainnet relayer wallet with ~0.1 ETH");
        console2.log("3. Update server .env with CHAIN_ID=8453 + mainnet addresses");
        console2.log("4. Trigger server deploy workflow");
        console2.log("5. Update Ponder indexer env (PONDER_NETWORK=base, PONDER_START_BLOCK=<block>)");
    }
}
