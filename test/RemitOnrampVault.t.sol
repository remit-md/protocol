// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {RemitOnrampVault} from "../src/RemitOnrampVault.sol";
import {OnrampVaultFactory} from "../src/OnrampVaultFactory.sol";

/// @title RemitOnrampVaultTest
/// @notice Unit tests for RemitOnrampVault + OnrampVaultFactory
contract RemitOnrampVaultTest is Test {
    MockUSDC internal usdc;
    RemitOnrampVault internal implementation;
    OnrampVaultFactory internal factory;

    address internal operatorA = makeAddr("operatorA");
    address internal operatorB = makeAddr("operatorB");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal sweeper = makeAddr("sweeper"); // random third party

    uint256 constant MINT = 1_000_000e6; // $1M USDC

    function setUp() public {
        usdc = new MockUSDC();
        implementation = new RemitOnrampVault();
        factory = new OnrampVaultFactory(address(implementation), address(usdc), feeRecipient);
    }

    // =========================================================================
    // RemitOnrampVault — sweep
    // =========================================================================

    function test_sweep_happyPath() public {
        address vault = factory.getOrCreate(operatorA);
        usdc.mint(vault, 100e6); // $100 deposit

        vm.prank(sweeper);
        RemitOnrampVault(vault).sweep();

        // 1% of 100e6 = 1e6
        assertEq(usdc.balanceOf(operatorA), 99e6, "operator gets 99%");
        assertEq(usdc.balanceOf(feeRecipient), 1e6, "fee recipient gets 1%");
        assertEq(usdc.balanceOf(vault), 0, "vault emptied");
    }

    function test_sweep_multipleDeposits() public {
        address vault = factory.getOrCreate(operatorA);
        usdc.mint(vault, 50e6);
        usdc.mint(vault, 50e6);

        RemitOnrampVault(vault).sweep();

        assertEq(usdc.balanceOf(operatorA), 99e6, "operator gets 99% of total");
        assertEq(usdc.balanceOf(feeRecipient), 1e6, "fee 1% of total");
    }

    function test_sweep_emitsEvent() public {
        address vault = factory.getOrCreate(operatorA);
        usdc.mint(vault, 200e6);

        vm.expectEmit(true, false, false, true);
        emit RemitOnrampVault.Swept(operatorA, 198e6, 2e6);

        RemitOnrampVault(vault).sweep();
    }

    function test_sweep_dustAmount() public {
        address vault = factory.getOrCreate(operatorA);
        usdc.mint(vault, 1); // 1 unit = 0.000001 USDC

        RemitOnrampVault(vault).sweep();

        // fee = 1 * 100 / 10000 = 0 (rounds down)
        assertEq(usdc.balanceOf(operatorA), 1, "operator gets everything on dust");
        assertEq(usdc.balanceOf(feeRecipient), 0, "zero fee on dust");
    }

    function test_sweep_99units() public {
        address vault = factory.getOrCreate(operatorA);
        usdc.mint(vault, 99); // 99 units

        RemitOnrampVault(vault).sweep();

        // fee = 99 * 100 / 10000 = 0 (rounds down, 0.99 rounds to 0)
        assertEq(usdc.balanceOf(operatorA), 99, "operator gets everything sub-cent");
        assertEq(usdc.balanceOf(feeRecipient), 0, "zero fee sub-cent");
    }

    function test_sweep_100units() public {
        address vault = factory.getOrCreate(operatorA);
        usdc.mint(vault, 100); // 100 units = $0.0001

        RemitOnrampVault(vault).sweep();

        // fee = 100 * 100 / 10000 = 1
        assertEq(usdc.balanceOf(operatorA), 99, "operator gets 99");
        assertEq(usdc.balanceOf(feeRecipient), 1, "fee is 1 unit");
    }

    function test_sweep_zeroBalance_reverts() public {
        address vault = factory.getOrCreate(operatorA);

        vm.expectRevert(RemitOnrampVault.NothingToSweep.selector);
        RemitOnrampVault(vault).sweep();
    }

    function test_sweep_permissionless() public {
        address vault = factory.getOrCreate(operatorA);
        usdc.mint(vault, 10e6);

        // Random third party can call sweep — funds still go to operator + feeRecipient
        vm.prank(sweeper);
        RemitOnrampVault(vault).sweep();

        assertEq(usdc.balanceOf(sweeper), 0, "sweeper gets nothing");
        assertEq(usdc.balanceOf(operatorA), 9_900_000, "operator gets 99%");
        assertEq(usdc.balanceOf(feeRecipient), 100_000, "fee gets 1%");
    }

    function test_sweep_twice() public {
        address vault = factory.getOrCreate(operatorA);

        // First deposit + sweep
        usdc.mint(vault, 100e6);
        RemitOnrampVault(vault).sweep();

        // Second deposit + sweep
        usdc.mint(vault, 50e6);
        RemitOnrampVault(vault).sweep();

        // 99 + 49.5 = 148.5
        assertEq(usdc.balanceOf(operatorA), 99e6 + 49_500_000, "cumulative operator amount");
        // 1 + 0.5 = 1.5
        assertEq(usdc.balanceOf(feeRecipient), 1e6 + 500_000, "cumulative fee amount");
    }

    function test_sweep_largeAmount() public {
        address vault = factory.getOrCreate(operatorA);
        usdc.mint(vault, 10_000_000e6); // $10M

        RemitOnrampVault(vault).sweep();

        assertEq(usdc.balanceOf(operatorA), 9_900_000e6, "operator gets 99% of $10M");
        assertEq(usdc.balanceOf(feeRecipient), 100_000e6, "fee is $100K");
    }

    // =========================================================================
    // RemitOnrampVault — pendingBalance
    // =========================================================================

    function test_pendingBalance_empty() public {
        address vault = factory.getOrCreate(operatorA);
        assertEq(RemitOnrampVault(vault).pendingBalance(), 0);
    }

    function test_pendingBalance_afterDeposit() public {
        address vault = factory.getOrCreate(operatorA);
        usdc.mint(vault, 42e6);
        assertEq(RemitOnrampVault(vault).pendingBalance(), 42e6);
    }

    function test_pendingBalance_afterSweep() public {
        address vault = factory.getOrCreate(operatorA);
        usdc.mint(vault, 42e6);
        RemitOnrampVault(vault).sweep();
        assertEq(RemitOnrampVault(vault).pendingBalance(), 0);
    }

    // =========================================================================
    // RemitOnrampVault — initialization
    // =========================================================================

    function test_initialize_twice_reverts() public {
        address vault = factory.getOrCreate(operatorA);

        vm.expectRevert(RemitOnrampVault.AlreadyInitialized.selector);
        RemitOnrampVault(vault).initialize(operatorB, address(usdc), feeRecipient);
    }

    function test_implementation_cannotBeInitialized() public {
        vm.expectRevert(RemitOnrampVault.AlreadyInitialized.selector);
        implementation.initialize(operatorA, address(usdc), feeRecipient);
    }

    function test_initialize_zeroOperator_reverts() public {
        // Deploy a raw clone manually to test init validation
        bytes32 salt = keccak256(abi.encodePacked("test-zero"));
        address clone = _deployClone(salt);

        vm.expectRevert(RemitOnrampVault.ZeroAddress.selector);
        RemitOnrampVault(clone).initialize(address(0), address(usdc), feeRecipient);
    }

    function test_initialize_zeroUsdc_reverts() public {
        bytes32 salt = keccak256(abi.encodePacked("test-zero-usdc"));
        address clone = _deployClone(salt);

        vm.expectRevert(RemitOnrampVault.ZeroAddress.selector);
        RemitOnrampVault(clone).initialize(operatorA, address(0), feeRecipient);
    }

    function test_initialize_zeroFeeRecipient_reverts() public {
        bytes32 salt = keccak256(abi.encodePacked("test-zero-fee"));
        address clone = _deployClone(salt);

        vm.expectRevert(RemitOnrampVault.ZeroAddress.selector);
        RemitOnrampVault(clone).initialize(operatorA, address(usdc), address(0));
    }

    // =========================================================================
    // OnrampVaultFactory — getOrCreate
    // =========================================================================

    function test_getOrCreate_deploysClone() public {
        address predicted = factory.predictVault(operatorA);
        address vault = factory.getOrCreate(operatorA);

        assertEq(vault, predicted, "vault matches predicted address");
        assertTrue(vault != address(0), "vault is non-zero");
        assertEq(factory.vaults(operatorA), vault, "stored in mapping");
    }

    function test_getOrCreate_idempotent() public {
        address vault1 = factory.getOrCreate(operatorA);
        address vault2 = factory.getOrCreate(operatorA);

        assertEq(vault1, vault2, "same vault returned on second call");
    }

    function test_getOrCreate_emitsEvent() public {
        address predicted = factory.predictVault(operatorA);

        vm.expectEmit(true, true, false, false);
        emit OnrampVaultFactory.VaultCreated(operatorA, predicted);

        factory.getOrCreate(operatorA);
    }

    function test_getOrCreate_noEventOnSecondCall() public {
        factory.getOrCreate(operatorA);

        // Second call should NOT emit VaultCreated (idempotent)
        vm.recordLogs();
        factory.getOrCreate(operatorA);
        assertEq(vm.getRecordedLogs().length, 0, "no events on second call");
    }

    function test_getOrCreate_differentOperators() public {
        address vaultA = factory.getOrCreate(operatorA);
        address vaultB = factory.getOrCreate(operatorB);

        assertTrue(vaultA != vaultB, "different operators get different vaults");
    }

    function test_getOrCreate_zeroOperator_reverts() public {
        vm.expectRevert(OnrampVaultFactory.ZeroAddress.selector);
        factory.getOrCreate(address(0));
    }

    // =========================================================================
    // OnrampVaultFactory — predictVault
    // =========================================================================

    function test_predictVault_deterministic() public view {
        address pred1 = factory.predictVault(operatorA);
        address pred2 = factory.predictVault(operatorA);

        assertEq(pred1, pred2, "predictions are deterministic");
    }

    function test_predictVault_differentForDifferentOperators() public view {
        address predA = factory.predictVault(operatorA);
        address predB = factory.predictVault(operatorB);

        assertTrue(predA != predB, "different operators different predictions");
    }

    // =========================================================================
    // OnrampVaultFactory — constructor validation
    // =========================================================================

    function test_factory_zeroImplementation_reverts() public {
        vm.expectRevert(OnrampVaultFactory.ZeroAddress.selector);
        new OnrampVaultFactory(address(0), address(usdc), feeRecipient);
    }

    function test_factory_zeroUsdc_reverts() public {
        vm.expectRevert(OnrampVaultFactory.ZeroAddress.selector);
        new OnrampVaultFactory(address(implementation), address(0), feeRecipient);
    }

    function test_factory_zeroFeeRecipient_reverts() public {
        vm.expectRevert(OnrampVaultFactory.ZeroAddress.selector);
        new OnrampVaultFactory(address(implementation), address(usdc), address(0));
    }

    // =========================================================================
    // End-to-end: Factory → Vault → Sweep
    // =========================================================================

    function test_e2e_factoryDeployAndSweep() public {
        // 1. Factory deploys vault for operator
        address vault = factory.getOrCreate(operatorA);

        // 2. Simulate fiat on-ramp deposit (USDC sent to vault)
        usdc.mint(vault, 500e6); // $500

        // 3. Server (or anyone) calls sweep
        RemitOnrampVault(vault).sweep();

        // 4. Verify split
        assertEq(usdc.balanceOf(operatorA), 495e6, "operator: $495");
        assertEq(usdc.balanceOf(feeRecipient), 5e6, "protocol: $5");
        assertEq(usdc.balanceOf(vault), 0, "vault: $0");
    }

    function test_e2e_twoOperatorsIndependent() public {
        address vaultA = factory.getOrCreate(operatorA);
        address vaultB = factory.getOrCreate(operatorB);

        usdc.mint(vaultA, 100e6);
        usdc.mint(vaultB, 200e6);

        RemitOnrampVault(vaultA).sweep();
        RemitOnrampVault(vaultB).sweep();

        assertEq(usdc.balanceOf(operatorA), 99e6, "operatorA: $99");
        assertEq(usdc.balanceOf(operatorB), 198e6, "operatorB: $198");
        assertEq(usdc.balanceOf(feeRecipient), 1e6 + 2e6, "fee: $3 total");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Deploy a raw clone without initializing (for testing init validation).
    function _deployClone(bytes32 salt) internal returns (address) {
        // Use low-level clone to avoid factory's auto-init
        bytes20 impl = bytes20(address(implementation));
        address clone;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), impl)
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            clone := create2(0, ptr, 0x37, salt)
        }
        require(clone != address(0), "clone deployment failed");
        return clone;
    }
}
