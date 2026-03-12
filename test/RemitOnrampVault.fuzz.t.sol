// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {RemitOnrampVault} from "../src/RemitOnrampVault.sol";
import {OnrampVaultFactory} from "../src/OnrampVaultFactory.sol";

/// @title RemitOnrampVaultFuzzTest
/// @notice Fuzz tests for RemitOnrampVault sweep math.
contract RemitOnrampVaultFuzzTest is Test {
    MockUSDC internal usdc;
    RemitOnrampVault internal implementation;
    OnrampVaultFactory internal factory;

    address internal operator = makeAddr("operator");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        usdc = new MockUSDC();
        implementation = new RemitOnrampVault();
        factory = new OnrampVaultFactory(address(implementation), address(usdc), feeRecipient);
    }

    /// @notice Verify that sweep conserves funds: operatorAmount + feeAmount == balance.
    ///         No USDC can be lost or created during sweep.
    function testFuzz_sweep_conservesFunds(uint96 amount) public {
        vm.assume(amount > 0); // sweep reverts on 0

        address vault = factory.getOrCreate(operator);
        usdc.mint(vault, amount);

        uint256 totalBefore = usdc.balanceOf(vault);
        RemitOnrampVault(vault).sweep();

        uint256 operatorBal = usdc.balanceOf(operator);
        uint256 feeBal = usdc.balanceOf(feeRecipient);
        uint256 vaultBal = usdc.balanceOf(vault);

        assertEq(operatorBal + feeBal + vaultBal, totalBefore, "funds conserved");
        assertEq(vaultBal, 0, "vault fully emptied");
    }

    /// @notice Verify that fee never exceeds 1% of the balance.
    function testFuzz_sweep_feeNeverExceedsOnePercent(uint96 amount) public {
        vm.assume(amount > 0);

        address vault = factory.getOrCreate(operator);
        usdc.mint(vault, amount);

        RemitOnrampVault(vault).sweep();

        uint256 fee = usdc.balanceOf(feeRecipient);
        // fee should be <= amount * 100 / 10000 (integer division rounds down)
        uint256 maxFee = (uint256(amount) * 100) / 10_000;
        assertLe(fee, maxFee, "fee within 1%");
    }

    /// @notice Verify that fee matches exact computation: floor(amount * 100 / 10000).
    function testFuzz_sweep_feeMatchesFormula(uint96 amount) public {
        vm.assume(amount > 0);

        address vault = factory.getOrCreate(operator);
        usdc.mint(vault, amount);

        RemitOnrampVault(vault).sweep();

        uint256 expectedFee = (uint256(amount) * 100) / 10_000;
        uint256 expectedOperator = uint256(amount) - expectedFee;

        assertEq(usdc.balanceOf(feeRecipient), expectedFee, "fee matches formula");
        assertEq(usdc.balanceOf(operator), expectedOperator, "operator matches formula");
    }

    /// @notice Verify that operator always gets >= 99% of the deposited amount.
    function testFuzz_sweep_operatorGetsAtLeast99Percent(uint96 amount) public {
        vm.assume(amount >= 100); // need at least 100 units for fee to be non-zero

        address vault = factory.getOrCreate(operator);
        usdc.mint(vault, amount);

        RemitOnrampVault(vault).sweep();

        uint256 operatorBal = usdc.balanceOf(operator);
        // operator should get at least 99% (integer math may give slightly more due to rounding)
        uint256 min99Percent = (uint256(amount) * 9_900) / 10_000;
        assertGe(operatorBal, min99Percent, "operator >= 99%");
    }

    /// @notice Verify that multiple sequential sweeps from the same vault conserve funds.
    function testFuzz_sweep_sequential(uint96 amount1, uint96 amount2) public {
        vm.assume(amount1 > 0);
        vm.assume(amount2 > 0);

        address vault = factory.getOrCreate(operator);

        // First deposit + sweep
        usdc.mint(vault, amount1);
        RemitOnrampVault(vault).sweep();

        uint256 op1 = usdc.balanceOf(operator);
        uint256 fee1 = usdc.balanceOf(feeRecipient);

        // Second deposit + sweep
        usdc.mint(vault, amount2);
        RemitOnrampVault(vault).sweep();

        uint256 opTotal = usdc.balanceOf(operator);
        uint256 feeTotal = usdc.balanceOf(feeRecipient);

        // Total disbursed should equal total deposited
        assertEq(opTotal + feeTotal, uint256(amount1) + uint256(amount2), "sequential funds conserved");

        // Each sweep should have moved funds in the right direction
        assertGe(opTotal, op1, "operator balance non-decreasing");
        assertGe(feeTotal, fee1, "fee balance non-decreasing");
    }
}
