// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {RemitDeposit} from "../src/RemitDeposit.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";

/// @title RemitDepositFuzzTest
/// @notice Fuzz/property tests for RemitDeposit.sol
/// @dev No fee on deposits — all transfers must be exact.
contract RemitDepositFuzzTest is Test {
    MockUSDC internal usdc;
    RemitDeposit internal dep;

    address internal depositor = makeAddr("depositor");
    address internal provider = makeAddr("provider");

    uint64 constant EXPIRY_DELTA = 7 days;

    function setUp() public {
        usdc = new MockUSDC();
        dep = new RemitDeposit(address(usdc), address(0), address(this));

        usdc.mint(depositor, type(uint96).max);
        vm.prank(depositor);
        usdc.approve(address(dep), type(uint256).max);
    }

    // =========================================================================
    // Fuzz: returnDeposit — depositor gets back exact amount (no fee)
    // =========================================================================

    /// @dev Deposit has no fee. Provider returning a deposit means depositor
    ///      receives exactly the locked amount.
    function testFuzz_returnDeposit_exactAmount(uint96 amount) public {
        amount = uint96(bound(amount, RemitTypes.MIN_AMOUNT, 10_000e6));
        bytes32 id = keccak256(abi.encodePacked("fuzz-return", amount));

        vm.prank(depositor);
        dep.lockDeposit(id, provider, amount, uint64(block.timestamp + EXPIRY_DELTA));

        uint256 depositorBefore = usdc.balanceOf(depositor);

        vm.prank(provider);
        dep.returnDeposit(id);

        assertEq(
            usdc.balanceOf(depositor) - depositorBefore, amount, "depositor must receive exact locked amount on return"
        );
        assertEq(usdc.balanceOf(address(dep)), 0, "contract must hold zero after return");
    }

    // =========================================================================
    // Fuzz: forfeitDeposit — provider gets exact amount (no fee)
    // =========================================================================

    /// @dev When the depositor defaults, provider claims by calling forfeitDeposit.
    function testFuzz_forfeitDeposit_exactAmount(uint96 amount) public {
        amount = uint96(bound(amount, RemitTypes.MIN_AMOUNT, 10_000e6));
        bytes32 id = keccak256(abi.encodePacked("fuzz-forfeit", amount));

        vm.prank(depositor);
        dep.lockDeposit(id, provider, amount, uint64(block.timestamp + EXPIRY_DELTA));

        uint256 providerBefore = usdc.balanceOf(provider);

        vm.prank(provider); // provider calls forfeitDeposit to claim defaulted funds
        dep.forfeitDeposit(id);

        assertEq(
            usdc.balanceOf(provider) - providerBefore, amount, "provider must receive exact locked amount on forfeit"
        );
        assertEq(usdc.balanceOf(address(dep)), 0, "contract must hold zero after forfeit");
    }

    // =========================================================================
    // Fuzz: claimExpiredDeposit — depositor reclaims after expiry
    // =========================================================================

    /// @dev Depositor can reclaim after expiry. Gets back exact amount.
    function testFuzz_claimExpiredDeposit_exactAmount(uint96 amount, uint64 warpDelta) public {
        amount = uint96(bound(amount, RemitTypes.MIN_AMOUNT, 10_000e6));
        warpDelta = uint64(bound(warpDelta, 1, 365 days));

        bytes32 id = keccak256(abi.encodePacked("fuzz-expired", amount, warpDelta));

        uint64 expiry = uint64(block.timestamp + EXPIRY_DELTA);
        vm.prank(depositor);
        dep.lockDeposit(id, provider, amount, expiry);

        vm.warp(expiry + warpDelta);

        uint256 depositorBefore = usdc.balanceOf(depositor);

        vm.prank(depositor);
        dep.claimExpiredDeposit(id);

        assertEq(
            usdc.balanceOf(depositor) - depositorBefore, amount, "depositor must get exact amount back on expired claim"
        );
        assertEq(usdc.balanceOf(address(dep)), 0, "contract must hold zero after expired claim");
    }

    // =========================================================================
    // Fuzz: independent deposits never cross-contaminate
    // =========================================================================

    /// @dev Two deposits with different IDs do not share funds.
    function testFuzz_independentDeposits_noContamination(uint96 amount1, uint96 amount2) public {
        amount1 = uint96(bound(amount1, RemitTypes.MIN_AMOUNT, 5_000e6));
        amount2 = uint96(bound(amount2, RemitTypes.MIN_AMOUNT, 5_000e6));

        bytes32 id1 = keccak256("deposit-1");
        bytes32 id2 = keccak256("deposit-2");

        address depositor2 = makeAddr("depositor2");
        usdc.mint(depositor2, type(uint96).max);
        vm.prank(depositor2);
        usdc.approve(address(dep), type(uint256).max);

        vm.prank(depositor);
        dep.lockDeposit(id1, provider, amount1, uint64(block.timestamp + EXPIRY_DELTA));
        vm.prank(depositor2);
        dep.lockDeposit(id2, provider, amount2, uint64(block.timestamp + EXPIRY_DELTA));

        // Contract holds exactly amount1 + amount2
        assertEq(usdc.balanceOf(address(dep)), uint256(amount1) + uint256(amount2));

        // Forfeit deposit 1 (provider claims) — deposit 2 intact
        vm.prank(provider);
        dep.forfeitDeposit(id1);
        assertEq(usdc.balanceOf(address(dep)), amount2, "deposit 2 must be intact after deposit 1 forfeit");

        // Return deposit 2
        vm.prank(provider);
        dep.returnDeposit(id2);
        assertEq(usdc.balanceOf(address(dep)), 0, "contract must hold zero after both deposits settled");
    }

    // =========================================================================
    // Fuzz: lockDeposit — any valid amount stores correctly
    // =========================================================================

    /// @dev Any amount in [MIN_AMOUNT, uint96.max] stores without overflow.
    function testFuzz_lockDeposit_storesCorrectly(uint96 amount, uint64 expiryDelta) public {
        amount = uint96(bound(amount, RemitTypes.MIN_AMOUNT, type(uint96).max));
        expiryDelta = uint64(bound(expiryDelta, 1, 365 days));

        bytes32 id = keccak256(abi.encodePacked("fuzz-lock", amount, expiryDelta));

        vm.prank(depositor);
        dep.lockDeposit(id, provider, amount, uint64(block.timestamp + expiryDelta));

        RemitTypes.Deposit memory d = dep.getDeposit(id);
        assertEq(d.amount, amount, "stored amount must match locked amount");
        assertEq(d.depositor, depositor);
        assertEq(d.provider, provider);
        assertEq(usdc.balanceOf(address(dep)), amount);
    }
}
