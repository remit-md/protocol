// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {RemitDeposit} from "../src/RemitDeposit.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";
import {RemitErrors} from "../src/libraries/RemitErrors.sol";
import {RemitEvents} from "../src/libraries/RemitEvents.sol";

/// @title RemitDepositTest
/// @notice Unit tests for RemitDeposit.sol
contract RemitDepositTest is Test {
    MockUSDC internal usdc;
    RemitDeposit internal deposit;

    address internal depositor = makeAddr("depositor");
    address internal provider = makeAddr("provider");
    address internal stranger = makeAddr("stranger");

    bytes32 constant DEPOSIT_ID = keccak256("deposit-1");

    uint96 constant AMOUNT = 50e6; // $50 USDC
    uint64 constant EXPIRY_DELTA = 30 days;
    uint96 constant MINT = 200e6;

    function setUp() public {
        usdc = new MockUSDC();
        deposit = new RemitDeposit(address(usdc), address(0));

        usdc.mint(depositor, MINT);
        vm.prank(depositor);
        usdc.approve(address(deposit), type(uint256).max);
    }

    // =========================================================================
    // lockDeposit
    // =========================================================================

    function test_lockDeposit_happyPath() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_DELTA);

        vm.expectEmit(true, true, true, true);
        emit RemitEvents.DepositLocked(DEPOSIT_ID, depositor, provider, AMOUNT, expiry);

        vm.prank(depositor);
        deposit.lockDeposit(DEPOSIT_ID, provider, AMOUNT, expiry);

        RemitTypes.Deposit memory d = deposit.getDeposit(DEPOSIT_ID);
        assertEq(d.depositor, depositor);
        assertEq(d.provider, provider);
        assertEq(d.amount, AMOUNT);
        assertEq(d.expiry, expiry);
        assertEq(uint8(d.status), uint8(RemitTypes.DepositStatus.Locked));
        assertEq(usdc.balanceOf(address(deposit)), AMOUNT);
    }

    function test_lockDeposit_revert_duplicate() public {
        _lockDeposit();

        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.EscrowAlreadyFunded.selector, DEPOSIT_ID));
        deposit.lockDeposit(DEPOSIT_ID, provider, AMOUNT, uint64(block.timestamp + EXPIRY_DELTA));
    }

    function test_lockDeposit_revert_zeroProvider() public {
        vm.prank(depositor);
        vm.expectRevert(RemitErrors.ZeroAddress.selector);
        deposit.lockDeposit(DEPOSIT_ID, address(0), AMOUNT, uint64(block.timestamp + EXPIRY_DELTA));
    }

    function test_lockDeposit_revert_selfDeposit() public {
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.SelfPayment.selector, depositor));
        deposit.lockDeposit(DEPOSIT_ID, depositor, AMOUNT, uint64(block.timestamp + EXPIRY_DELTA));
    }

    function test_lockDeposit_revert_belowMinimum() public {
        vm.prank(depositor);
        vm.expectRevert(
            abi.encodeWithSelector(RemitErrors.BelowMinimum.selector, RemitTypes.MIN_AMOUNT - 1, RemitTypes.MIN_AMOUNT)
        );
        deposit.lockDeposit(DEPOSIT_ID, provider, RemitTypes.MIN_AMOUNT - 1, uint64(block.timestamp + EXPIRY_DELTA));
    }

    function test_lockDeposit_revert_pastExpiry() public {
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.InvalidTimeout.selector, block.timestamp));
        deposit.lockDeposit(DEPOSIT_ID, provider, AMOUNT, uint64(block.timestamp));
    }

    // =========================================================================
    // returnDeposit
    // =========================================================================

    function test_returnDeposit_happyPath() public {
        _lockDeposit();

        uint256 depositorBefore = usdc.balanceOf(depositor);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.DepositReturned(DEPOSIT_ID, depositor, AMOUNT);

        vm.prank(provider);
        deposit.returnDeposit(DEPOSIT_ID);

        assertEq(usdc.balanceOf(depositor), depositorBefore + AMOUNT);
        assertEq(usdc.balanceOf(address(deposit)), 0);
        assertEq(uint8(deposit.getDeposit(DEPOSIT_ID).status), uint8(RemitTypes.DepositStatus.Returned));
    }

    function test_returnDeposit_revert_notProvider() public {
        _lockDeposit();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        deposit.returnDeposit(DEPOSIT_ID);
    }

    function test_returnDeposit_revert_notFound() public {
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.DepositNotFound.selector, DEPOSIT_ID));
        deposit.returnDeposit(DEPOSIT_ID);
    }

    function test_returnDeposit_revert_alreadySettled() public {
        _lockDeposit();
        vm.prank(provider);
        deposit.returnDeposit(DEPOSIT_ID);

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.AlreadyClosed.selector, DEPOSIT_ID));
        deposit.returnDeposit(DEPOSIT_ID);
    }

    // =========================================================================
    // forfeitDeposit
    // =========================================================================

    function test_forfeitDeposit_happyPath() public {
        _lockDeposit();

        uint256 providerBefore = usdc.balanceOf(provider);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.DepositForfeited(DEPOSIT_ID, provider, AMOUNT);

        vm.prank(provider);
        deposit.forfeitDeposit(DEPOSIT_ID);

        assertEq(usdc.balanceOf(provider), providerBefore + AMOUNT);
        assertEq(usdc.balanceOf(address(deposit)), 0);
        assertEq(uint8(deposit.getDeposit(DEPOSIT_ID).status), uint8(RemitTypes.DepositStatus.Forfeited));
    }

    function test_forfeitDeposit_revert_notProvider() public {
        _lockDeposit();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        deposit.forfeitDeposit(DEPOSIT_ID);
    }

    function test_forfeitDeposit_revert_notFound() public {
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.DepositNotFound.selector, DEPOSIT_ID));
        deposit.forfeitDeposit(DEPOSIT_ID);
    }

    function test_forfeitDeposit_revert_alreadySettled() public {
        _lockDeposit();
        vm.prank(provider);
        deposit.forfeitDeposit(DEPOSIT_ID);

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.AlreadyClosed.selector, DEPOSIT_ID));
        deposit.forfeitDeposit(DEPOSIT_ID);
    }

    function test_forfeitDeposit_revert_afterReturn() public {
        _lockDeposit();
        vm.prank(provider);
        deposit.returnDeposit(DEPOSIT_ID);

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.AlreadyClosed.selector, DEPOSIT_ID));
        deposit.forfeitDeposit(DEPOSIT_ID);
    }

    // =========================================================================
    // claimExpiredDeposit
    // =========================================================================

    function test_claimExpiredDeposit_happyPath() public {
        _lockDeposit();
        vm.warp(block.timestamp + EXPIRY_DELTA + 1);

        uint256 depositorBefore = usdc.balanceOf(depositor);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.DepositReturned(DEPOSIT_ID, depositor, AMOUNT);

        vm.prank(depositor);
        deposit.claimExpiredDeposit(DEPOSIT_ID);

        assertEq(usdc.balanceOf(depositor), depositorBefore + AMOUNT);
        assertEq(usdc.balanceOf(address(deposit)), 0);
        assertEq(uint8(deposit.getDeposit(DEPOSIT_ID).status), uint8(RemitTypes.DepositStatus.Returned));
    }

    function test_claimExpiredDeposit_revert_notDepositor() public {
        _lockDeposit();
        vm.warp(block.timestamp + EXPIRY_DELTA + 1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        deposit.claimExpiredDeposit(DEPOSIT_ID);
    }

    function test_claimExpiredDeposit_revert_notYetExpired() public {
        _lockDeposit();

        vm.prank(depositor);
        vm.expectRevert(
            abi.encodeWithSelector(RemitErrors.InvalidTimeout.selector, uint64(block.timestamp + EXPIRY_DELTA))
        );
        deposit.claimExpiredDeposit(DEPOSIT_ID);
    }

    function test_claimExpiredDeposit_revert_alreadyForfeited() public {
        _lockDeposit();
        vm.prank(provider);
        deposit.forfeitDeposit(DEPOSIT_ID);

        vm.warp(block.timestamp + EXPIRY_DELTA + 1);
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.AlreadyClosed.selector, DEPOSIT_ID));
        deposit.claimExpiredDeposit(DEPOSIT_ID);
    }

    function test_claimExpiredDeposit_revert_notFound() public {
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.DepositNotFound.selector, DEPOSIT_ID));
        deposit.claimExpiredDeposit(DEPOSIT_ID);
    }

    // =========================================================================
    // Invariant: cannot both return and forfeit
    // =========================================================================

    function test_cannotBothReturnAndForfeit() public {
        _lockDeposit();
        vm.prank(provider);
        deposit.returnDeposit(DEPOSIT_ID);

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.AlreadyClosed.selector, DEPOSIT_ID));
        deposit.forfeitDeposit(DEPOSIT_ID);
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    function test_constructor_revert_zeroUsdc() public {
        vm.expectRevert(RemitErrors.ZeroAddress.selector);
        new RemitDeposit(address(0), address(0));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _lockDeposit() internal {
        vm.prank(depositor);
        deposit.lockDeposit(DEPOSIT_ID, provider, AMOUNT, uint64(block.timestamp + EXPIRY_DELTA));
    }
}
