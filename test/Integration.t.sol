// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./helpers/TestBase.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";
import {RemitEvents} from "../src/libraries/RemitEvents.sol";

/// @title IntegrationTest
/// @notice Cross-contract lifecycle tests using the REAL FeeCalculator and Router.
/// @dev Inherits TestBase which deploys the full real stack (realFeeCalc, router,
///      realEscrow, realTab, realStream, realBounty, realDeposit).
///
///      These tests verify that:
///        1. All contracts are correctly wired (FeeCalculator authorized, Router connected)
///        2. Fee tiers work correctly across contracts
///        3. Volume from multiple contracts accumulates in a single wallet
///        4. The 30-day reset works correctly
///        5. payDirect routes correctly through the Router
contract IntegrationTest is TestBase {
    bytes32 constant INV = keccak256("integration-invoice-01");
    bytes32 constant INV2 = keccak256("integration-invoice-02");
    bytes32 constant TAB_ID = keccak256("integration-tab-01");
    bytes32 constant STREAM_ID = keccak256("integration-stream-01");

    // =========================================================================
    // Router wiring
    // =========================================================================

    function test_router_allAddressesRegistered() public view {
        assertEq(router.escrow(), address(realEscrow));
        assertEq(router.tab(), address(realTab));
        assertEq(router.stream(), address(realStream));
        assertEq(router.bounty(), address(realBounty));
        assertEq(router.deposit(), address(realDeposit));
        assertEq(router.feeCalculator(), address(realFeeCalc));
        assertEq(router.usdc(), address(usdc));
    }

    function test_feeCalc_allContractsAuthorized() public view {
        assertTrue(realFeeCalc.authorizedCallers(address(realEscrow)));
        assertTrue(realFeeCalc.authorizedCallers(address(realTab)));
        assertTrue(realFeeCalc.authorizedCallers(address(realStream)));
        assertTrue(realFeeCalc.authorizedCallers(address(realBounty)));
        assertTrue(realFeeCalc.authorizedCallers(address(router)));
    }

    // =========================================================================
    // payDirect — real fee calculator
    // =========================================================================

    function test_payDirect_standardRate() public {
        uint96 amount = 1_000e6; // $1,000 — below threshold
        uint96 expectedFee = uint96((uint256(amount) * 100) / 10_000); // 1%

        // Record balances before (payee has existing funds from TestBase setUp)
        uint256 payeeBefore = usdc.balanceOf(payee);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        vm.prank(payer);
        router.payDirect(payee, amount, bytes32(0));

        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, expectedFee);
        assertEq(usdc.balanceOf(payee) - payeeBefore, amount - expectedFee);
    }

    function test_payDirect_crossesThreshold_marginalFee() public {
        // First push payer's volume to $9,500.
        vm.prank(admin);
        realFeeCalc.authorizeCaller(address(this)); // temporarily authorize test
        realFeeCalc.recordTransaction(payer, 9_500e6);
        vm.prank(admin);
        realFeeCalc.revokeCaller(address(this));

        // Now payDirect $1,000 — straddles $10k threshold.
        // $500 at 1% = $5. $500 at 0.5% = $2.50. Total fee = $7.50.
        uint96 amount = 1_000e6;
        uint256 standardFee = (500e6 * 100) / 10_000; // $5.00
        uint256 preferredFee = (500e6 * 50) / 10_000; // $2.50
        uint96 expectedFee = uint96(standardFee + preferredFee);

        vm.prank(payer);
        router.payDirect(payee, amount, bytes32(0));

        assertEq(usdc.balanceOf(feeRecipient), expectedFee);
    }

    function test_payDirect_preferredRate_afterThreshold() public {
        // Push payer's volume above threshold first.
        vm.prank(admin);
        realFeeCalc.authorizeCaller(address(this));
        realFeeCalc.recordTransaction(payer, RemitTypes.FEE_THRESHOLD);
        vm.prank(admin);
        realFeeCalc.revokeCaller(address(this));

        uint96 amount = 1_000e6;
        uint96 expectedFee = uint96((uint256(amount) * 50) / 10_000); // 0.5%

        vm.prank(payer);
        router.payDirect(payee, amount, bytes32(0));

        assertEq(usdc.balanceOf(feeRecipient), expectedFee);
    }

    // =========================================================================
    // Volume accumulation across contracts
    // =========================================================================

    function test_volume_accumulatesAcrossContracts() public {
        // Pay via router — volume recorded.
        vm.prank(payer);
        router.payDirect(payee, 5_000e6, bytes32(0));
        assertEq(realFeeCalc.getMonthlyVolume(payer), 5_000e6);

        // Open + close an escrow — volume recorded on release.
        // Fund payer with additional USDC.
        usdc.mint(payer, 5_000e6 + 100e6); // amount + fee buffer
        vm.prank(payer);
        usdc.approve(address(realEscrow), type(uint256).max);

        vm.prank(payer);
        realEscrow.createEscrow(
            INV,
            payee,
            5_000e6,
            uint64(block.timestamp + 7 days),
            new RemitTypes.Milestone[](0),
            new RemitTypes.Split[](0)
        );
        vm.prank(payee);
        realEscrow.claimStart(INV);
        vm.prank(payer);
        realEscrow.releaseEscrow(INV);

        // After $5k payDirect + $5k escrow = $10k → should be at preferred tier.
        assertGe(realFeeCalc.getMonthlyVolume(payer), RemitTypes.FEE_THRESHOLD);
        assertEq(realFeeCalc.getFeeRate(payer), RemitTypes.FEE_RATE_PREFERRED_BPS);
    }

    // =========================================================================
    // Fee tier transition
    // =========================================================================

    function test_feeTierTransition_standardToPreferred() public {
        // Mint extra so payer can afford $9k + $2k = $11k total payments.
        usdc.mint(payer, 2_000e6);

        // Make enough volume to cross threshold.
        // First payment: $9,000 at standard rate.
        vm.prank(payer);
        router.payDirect(payee, 9_000e6, bytes32(0));

        assertEq(realFeeCalc.getFeeRate(payer), RemitTypes.FEE_RATE_BPS); // still standard

        // Second payment: $2,000 straddles $10k mark.
        vm.prank(payer);
        router.payDirect(payee, 2_000e6, bytes32(0));

        assertEq(realFeeCalc.getFeeRate(payer), RemitTypes.FEE_RATE_PREFERRED_BPS); // now preferred
    }

    // =========================================================================
    // Volume resets after 30-day window
    // =========================================================================

    function test_volumeReset_afterWindow() public {
        // Mint extra so payer can afford $9k + $2k = $11k total.
        usdc.mint(payer, 2_000e6);

        // Accumulate above threshold.
        vm.prank(payer);
        router.payDirect(payee, 9_000e6, bytes32(0));

        vm.prank(payer);
        router.payDirect(payee, 2_000e6, bytes32(0));

        assertEq(realFeeCalc.getFeeRate(payer), RemitTypes.FEE_RATE_PREFERRED_BPS);

        // Advance 31 days — volume resets.
        vm.warp(block.timestamp + 31 days);

        assertEq(realFeeCalc.getFeeRate(payer), RemitTypes.FEE_RATE_BPS);
        assertEq(realFeeCalc.getMonthlyVolume(payer), 0);
    }

    // =========================================================================
    // Independent wallets don't share volume
    // =========================================================================

    function test_volume_independentPerWallet() public {
        // Mint extra so payer can afford $9k + $2k = $11k total.
        usdc.mint(payer, 2_000e6);

        // payer crosses threshold.
        vm.prank(payer);
        router.payDirect(payee, 9_000e6, bytes32(0));
        vm.prank(payer);
        router.payDirect(payee, 2_000e6, bytes32(0));

        // payee's volume is unaffected (payee hasn't sent anything).
        assertEq(realFeeCalc.getMonthlyVolume(payee), 0);
        assertEq(realFeeCalc.getFeeRate(payee), RemitTypes.FEE_RATE_BPS);
    }

    // =========================================================================
    // Escrow + Router coexist (funds in escrow don't affect router)
    // =========================================================================

    function test_escrowAndRouter_independent() public {
        // Create an escrow (funds locked).
        vm.prank(payer);
        realEscrow.createEscrow(
            INV,
            payee,
            AMOUNT,
            uint64(block.timestamp + 7 days),
            new RemitTypes.Milestone[](0),
            new RemitTypes.Split[](0)
        );

        // payDirect works independently with remaining balance.
        vm.prank(payer);
        router.payDirect(payee, AMOUNT, bytes32(0)); // payer has 10k USDC, spent 100 for escrow + 100 here

        // Escrow still holds its AMOUNT.
        assertEq(usdc.balanceOf(address(realEscrow)), AMOUNT);
    }

    // =========================================================================
    // Tab + FeeCalculator
    // =========================================================================

    function test_tab_feeTierApplied() public {
        // Open a tab — this doesn't record volume yet (no settlement).
        vm.prank(payer);
        realTab.openTab(TAB_ID, payee, AMOUNT, 1e6, uint64(block.timestamp + 1 days));

        // Close the tab with $50 charged.
        uint96 charged = 50e6;
        bytes memory sig = _signTabCharge(TAB_ID, charged, 50, payee);
        vm.prank(payer);
        realTab.closeTab(TAB_ID, charged, 50, sig);

        // Fee recorded in fee calculator.
        assertEq(realFeeCalc.getMonthlyVolume(payer), charged);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    bytes32 constant TAB_CHARGE_TYPEHASH = keccak256("TabCharge(bytes32 tabId,uint96 totalCharged,uint32 callCount)");

    function _signTabCharge(bytes32 tabId, uint96 totalCharged, uint32 callCount, address signer)
        internal
        view
        returns (bytes memory)
    {
        // payeeKey is set in TestBase from the deterministic key.
        // We need to get the payee key — use vm.sign with the payee private key.
        bytes32 domainSep = realTab.domainSeparator();
        bytes32 structHash = keccak256(abi.encode(TAB_CHARGE_TYPEHASH, tabId, totalCharged, callCount));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payeeKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
