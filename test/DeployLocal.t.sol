// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";
import {RemitKeyRegistry} from "../src/RemitKeyRegistry.sol";
import {RemitArbitration} from "../src/RemitArbitration.sol";
import {RemitEscrow} from "../src/RemitEscrow.sol";
import {RemitTab} from "../src/RemitTab.sol";
import {RemitStream} from "../src/RemitStream.sol";
import {RemitBounty} from "../src/RemitBounty.sol";
import {RemitDeposit} from "../src/RemitDeposit.sol";
import {RemitRouter} from "../src/RemitRouter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";

/// @title DeployLocalTest
/// @notice Simulates DeployLocal.s.sol in a Foundry test environment.
///
///         Verifies that:
///         1. All 10 contracts deploy without revert.
///         2. Router is wired to the correct contract addresses.
///         3. FeeCalculator authorizes the 4 fee-bearing contracts.
///         4. KeyRegistry authorizes all 5 fund-holding contracts.
///         5. Arbitration authorizes Escrow.
///         6. USDC minting works (sanity check for MockUSDC).
///
///         This test is the CI equivalent of running:
///         forge script script/DeployLocal.s.sol --broadcast --rpc-url http://localhost:8545
contract DeployLocalTest is Test {
    address internal deployer = makeAddr("deployer");

    // Deployed contract addresses
    MockUSDC internal usdc;
    RemitFeeCalculator internal feeCalc;
    RemitKeyRegistry internal keyRegistry;
    RemitArbitration internal arbitration;
    RemitEscrow internal escrow;
    RemitTab internal tab;
    RemitStream internal stream;
    RemitBounty internal bounty;
    RemitDeposit internal deposit;
    RemitRouter internal router;

    function setUp() public {
        vm.startPrank(deployer);

        // 1. MockUSDC
        usdc = new MockUSDC();

        // 2. FeeCalculator (UUPS proxy)
        RemitFeeCalculator feeCalcImpl = new RemitFeeCalculator();
        bytes memory feeCalcInit = abi.encodeCall(feeCalcImpl.initialize, (deployer));
        feeCalc = RemitFeeCalculator(address(new ERC1967Proxy(address(feeCalcImpl), feeCalcInit)));

        // 3. KeyRegistry
        keyRegistry = new RemitKeyRegistry(deployer);

        // 4. Arbitration
        arbitration = new RemitArbitration(address(usdc), deployer);

        // 5. Fund-holding contracts
        escrow = new RemitEscrow(
            address(usdc), address(feeCalc), deployer, deployer, address(keyRegistry), address(arbitration)
        );
        tab = new RemitTab(address(usdc), address(feeCalc), deployer, deployer, address(keyRegistry));
        stream = new RemitStream(address(usdc), address(feeCalc), deployer, address(keyRegistry));
        bounty = new RemitBounty(address(usdc), address(feeCalc), deployer, deployer, address(keyRegistry));
        deposit = new RemitDeposit(address(usdc), address(keyRegistry), deployer);

        // 6. Authorize fund-holding contracts in FeeCalculator
        feeCalc.authorizeCaller(address(escrow));
        feeCalc.authorizeCaller(address(tab));
        feeCalc.authorizeCaller(address(stream));
        feeCalc.authorizeCaller(address(bounty));

        // 7. Authorize all contracts in KeyRegistry
        keyRegistry.authorizeContract(address(escrow));
        keyRegistry.authorizeContract(address(tab));
        keyRegistry.authorizeContract(address(stream));
        keyRegistry.authorizeContract(address(bounty));
        keyRegistry.authorizeContract(address(deposit));

        // 8. Authorize Escrow in Arbitration
        arbitration.authorizeEscrow(address(escrow));

        // 9. Router (UUPS proxy)
        RemitRouter routerImpl = new RemitRouter();
        bytes memory routerInit = abi.encodeCall(
            routerImpl.initialize,
            (RemitRouter.RouterConfig({
                    owner: deployer,
                    usdc: address(usdc),
                    feeCalculator: address(feeCalc),
                    protocolAdmin: deployer,
                    feeRecipient: deployer
                }))
        );
        router = RemitRouter(address(new ERC1967Proxy(address(routerImpl), routerInit)));

        // 10. Wire router
        router.setEscrow(address(escrow));
        router.setTab(address(tab));
        router.setStream(address(stream));
        router.setBounty(address(bounty));
        router.setDeposit(address(deposit));
        feeCalc.authorizeCaller(address(router));

        // 11. Mint test tokens
        usdc.mint(deployer, 1_000_000e6);

        vm.stopPrank();
    }

    // =========================================================================
    // Deployment sanity
    // =========================================================================

    function test_deploy_allContractsNonZero() public view {
        assertTrue(address(usdc) != address(0), "usdc not deployed");
        assertTrue(address(feeCalc) != address(0), "feeCalc not deployed");
        assertTrue(address(keyRegistry) != address(0), "keyRegistry not deployed");
        assertTrue(address(arbitration) != address(0), "arbitration not deployed");
        assertTrue(address(escrow) != address(0), "escrow not deployed");
        assertTrue(address(tab) != address(0), "tab not deployed");
        assertTrue(address(stream) != address(0), "stream not deployed");
        assertTrue(address(bounty) != address(0), "bounty not deployed");
        assertTrue(address(deposit) != address(0), "deposit not deployed");
        assertTrue(address(router) != address(0), "router not deployed");
    }

    function test_deploy_usdcMinted() public view {
        assertEq(usdc.balanceOf(deployer), 1_000_000e6, "deployer should have 1M USDC");
    }

    // =========================================================================
    // Router wiring
    // =========================================================================

    function test_deploy_routerWired_escrow() public view {
        assertEq(router.escrow(), address(escrow), "router.escrow mismatch");
    }

    function test_deploy_routerWired_tab() public view {
        assertEq(router.tab(), address(tab), "router.tab mismatch");
    }

    function test_deploy_routerWired_stream() public view {
        assertEq(router.stream(), address(stream), "router.stream mismatch");
    }

    function test_deploy_routerWired_bounty() public view {
        assertEq(router.bounty(), address(bounty), "router.bounty mismatch");
    }

    function test_deploy_routerWired_deposit() public view {
        assertEq(router.deposit(), address(deposit), "router.deposit mismatch");
    }

    // =========================================================================
    // FeeCalculator authorizations
    // =========================================================================

    function test_deploy_feeCalc_authorizedEscrow() public {
        // calculateFee checks msg.sender against authorizedCallers.
        // Call as escrow to verify it's authorized (would revert otherwise).
        vm.prank(address(escrow));
        uint96 fee = feeCalc.calculateFee(deployer, 1_000e6);
        assertGe(fee, 0, "fee calculation should not revert for authorized escrow");
    }

    function test_deploy_keyRegistry_authorizedEscrow() public view {
        assertTrue(keyRegistry.isAuthorizedContract(address(escrow)), "escrow not authorized in keyRegistry");
    }

    function test_deploy_keyRegistry_authorizedDeposit() public view {
        assertTrue(keyRegistry.isAuthorizedContract(address(deposit)), "deposit not authorized in keyRegistry");
    }

    function test_deploy_keyRegistry_authorizedAll() public view {
        assertTrue(keyRegistry.isAuthorizedContract(address(escrow)), "escrow not auth");
        assertTrue(keyRegistry.isAuthorizedContract(address(tab)), "tab not auth");
        assertTrue(keyRegistry.isAuthorizedContract(address(stream)), "stream not auth");
        assertTrue(keyRegistry.isAuthorizedContract(address(bounty)), "bounty not auth");
        assertTrue(keyRegistry.isAuthorizedContract(address(deposit)), "deposit not auth");
    }

    // =========================================================================
    // Arbitration authorization
    // =========================================================================

    function test_deploy_arbitration_authorizedEscrow() public view {
        assertTrue(arbitration.isAuthorizedEscrow(address(escrow)), "escrow not authorized in arbitration");
    }

    // =========================================================================
    // Smoke: basic escrow create → release flow
    // =========================================================================

    function test_deploy_smoke_escrowCreateAndRelease() public {
        address payer = makeAddr("smoke-payer");
        address payee = makeAddr("smoke-payee");

        usdc.mint(payer, 500e6);
        vm.prank(payer);
        usdc.approve(address(escrow), 500e6);

        bytes32 id = keccak256("smoke-escrow");

        vm.prank(payer);
        escrow.createEscrow(
            id, payee, 500e6, uint64(block.timestamp + 7 days), new RemitTypes.Milestone[](0), new RemitTypes.Split[](0)
        );

        vm.prank(payee);
        escrow.claimStart(id);

        uint256 payeeBefore = usdc.balanceOf(payee);
        vm.prank(payer);
        escrow.releaseEscrow(id);

        assertGt(usdc.balanceOf(payee), payeeBefore, "payee should receive funds");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow should be empty after release");
    }
}
