// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";
import {RemitErrors} from "../src/libraries/RemitErrors.sol";

/// @title RemitFeeCalculatorTest
/// @notice Unit tests for RemitFeeCalculator.sol
/// @dev Deploys the calculator behind a real ERC1967Proxy to test the UUPS pattern.
contract RemitFeeCalculatorTest is Test {
    RemitFeeCalculator internal calc;

    address internal owner = makeAddr("owner");
    address internal caller = makeAddr("caller"); // authorized contract
    address internal wallet = makeAddr("wallet");
    address internal stranger = makeAddr("stranger");

    // Fee constants from RemitTypes
    uint96 constant THRESHOLD = RemitTypes.FEE_THRESHOLD; // $10,000
    uint96 constant STANDARD = RemitTypes.FEE_RATE_BPS; // 100 bps = 1%
    uint96 constant PREFERRED = RemitTypes.FEE_RATE_PREFERRED_BPS; // 50 bps = 0.5%

    function setUp() public {
        // Deploy via UUPS proxy (same as production).
        RemitFeeCalculator impl = new RemitFeeCalculator();
        bytes memory data = abi.encodeCall(impl.initialize, (owner));
        calc = RemitFeeCalculator(address(new ERC1967Proxy(address(impl), data)));

        // Authorize `caller` as a fund-holding contract.
        vm.prank(owner);
        calc.authorizeCaller(caller);
    }

    // =========================================================================
    // initialize
    // =========================================================================

    function test_initialize_setsOwner() public view {
        assertEq(calc.owner(), owner);
    }

    function test_initialize_revertsIfCalledAgain() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, address(this)));
        calc.initialize(stranger);
    }

    function test_initialize_revertsOnZeroOwner() public {
        // Deploy a fresh impl + proxy with zero owner.
        RemitFeeCalculator impl = new RemitFeeCalculator();
        bytes memory data = abi.encodeCall(impl.initialize, (address(0)));
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ZeroAddress.selector));
        new ERC1967Proxy(address(impl), data);
    }

    // =========================================================================
    // calculateFee — standard rate region
    // =========================================================================

    function test_calculateFee_standardRate_zeroVolume() public view {
        // No prior volume → standard rate (1%)
        uint96 amount = 1_000e6; // $1,000
        uint96 fee = calc.calculateFee(wallet, amount);
        assertEq(fee, (uint256(amount) * STANDARD) / 10_000);
    }

    function test_calculateFee_standardRate_halfwayToThreshold() public {
        // Volume at $5,000 → still standard
        vm.prank(caller);
        calc.recordTransaction(wallet, 5_000e6);

        uint96 amount = 500e6; // $500 — stays below $10k
        uint96 fee = calc.calculateFee(wallet, amount);
        assertEq(fee, (uint256(amount) * STANDARD) / 10_000);
    }

    function test_calculateFee_standardRate_exactlyAtThreshold() public {
        // Volume at $10,000 → preferred rate for any additional
        vm.prank(caller);
        calc.recordTransaction(wallet, THRESHOLD);

        uint96 amount = 1_000e6;
        uint96 fee = calc.calculateFee(wallet, amount);
        assertEq(fee, (uint256(amount) * PREFERRED) / 10_000);
    }

    // =========================================================================
    // calculateFee — preferred rate region
    // =========================================================================

    function test_calculateFee_preferredRate_aboveThreshold() public {
        // Volume already above threshold
        vm.prank(caller);
        calc.recordTransaction(wallet, THRESHOLD + 1_000e6);

        uint96 amount = 2_000e6;
        uint96 fee = calc.calculateFee(wallet, amount);
        assertEq(fee, (uint256(amount) * PREFERRED) / 10_000);
    }

    // =========================================================================
    // calculateFee — marginal (straddles threshold)
    // =========================================================================

    function test_calculateFee_marginal_exactSplit() public {
        // Volume at $9,500. Transaction of $1,000 straddles the $10k mark.
        // $500 at standard (1%) = $5. $500 at preferred (0.5%) = $2.50 → $7.50 total.
        vm.prank(caller);
        calc.recordTransaction(wallet, 9_500e6);

        uint96 amount = 1_000e6;
        uint96 fee = calc.calculateFee(wallet, amount);

        uint256 standardFee = (500e6 * STANDARD) / 10_000; // $5.00
        uint256 preferredFee = (500e6 * PREFERRED) / 10_000; // $2.50
        assertEq(fee, uint96(standardFee + preferredFee));
    }

    function test_calculateFee_marginal_oneBelowThreshold() public {
        // Volume at THRESHOLD - 1 (just below). Any transaction straddles.
        vm.prank(caller);
        calc.recordTransaction(wallet, THRESHOLD - 1);

        // Transaction of 2: 1 at standard, 1 at preferred.
        uint96 fee = calc.calculateFee(wallet, 2);
        uint256 standardFee = (1 * STANDARD) / 10_000; // rounds to 0
        uint256 preferredFee = (1 * PREFERRED) / 10_000; // rounds to 0
        assertEq(fee, uint96(standardFee + preferredFee));
    }

    // =========================================================================
    // calculateFee — does not write state (view function)
    // =========================================================================

    function test_calculateFee_doesNotChangeVolume() public {
        uint256 volBefore = calc.getMonthlyVolume(wallet);
        calc.calculateFee(wallet, 1_000e6);
        assertEq(calc.getMonthlyVolume(wallet), volBefore);
    }

    // =========================================================================
    // getFeeRate
    // =========================================================================

    function test_getFeeRate_standard_zeroVolume() public view {
        assertEq(calc.getFeeRate(wallet), STANDARD);
    }

    function test_getFeeRate_preferred_afterThreshold() public {
        vm.prank(caller);
        calc.recordTransaction(wallet, THRESHOLD);
        assertEq(calc.getFeeRate(wallet), PREFERRED);
    }

    // =========================================================================
    // recordTransaction
    // =========================================================================

    function test_recordTransaction_accumulatesVolume() public {
        vm.startPrank(caller);
        calc.recordTransaction(wallet, 1_000e6);
        calc.recordTransaction(wallet, 2_000e6);
        vm.stopPrank();

        assertEq(calc.getMonthlyVolume(wallet), 3_000e6);
    }

    function test_recordTransaction_revertsIfUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        calc.recordTransaction(wallet, 1_000e6);
    }

    // =========================================================================
    // Monthly volume reset (30-day window)
    // =========================================================================

    function test_volumeResets_afterNewWindow() public {
        vm.prank(caller);
        calc.recordTransaction(wallet, 9_000e6);
        assertEq(calc.getMonthlyVolume(wallet), 9_000e6);

        // Advance past 30 days.
        vm.warp(block.timestamp + 31 days);

        // Volume is now 0 (new window).
        assertEq(calc.getMonthlyVolume(wallet), 0);

        // Fee recalculates from zero.
        uint96 fee = calc.calculateFee(wallet, 1_000e6);
        assertEq(fee, (1_000e6 * STANDARD) / 10_000);
    }

    function test_recordTransaction_resetsThenAccumulates() public {
        vm.prank(caller);
        calc.recordTransaction(wallet, 9_000e6);

        vm.warp(block.timestamp + 31 days);

        // Record in new window — should start fresh.
        vm.prank(caller);
        calc.recordTransaction(wallet, 500e6);

        assertEq(calc.getMonthlyVolume(wallet), 500e6);
    }

    function test_volumeNotReset_sameWindow() public {
        vm.prank(caller);
        calc.recordTransaction(wallet, 5_000e6);

        vm.warp(block.timestamp + 29 days); // still same 30-day window

        vm.prank(caller);
        calc.recordTransaction(wallet, 2_000e6);

        assertEq(calc.getMonthlyVolume(wallet), 7_000e6);
    }

    // =========================================================================
    // authorizeCaller / revokeCaller
    // =========================================================================

    function test_authorizeCaller_onlyOwner() public {
        address newCaller = makeAddr("new");
        vm.prank(owner);
        calc.authorizeCaller(newCaller);
        assertTrue(calc.authorizedCallers(newCaller));
    }

    function test_authorizeCaller_revertsForStranger() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        calc.authorizeCaller(makeAddr("x"));
    }

    function test_authorizeCaller_revertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ZeroAddress.selector));
        vm.prank(owner);
        calc.authorizeCaller(address(0));
    }

    function test_revokeCaller_works() public {
        vm.prank(owner);
        calc.revokeCaller(caller);
        assertFalse(calc.authorizedCallers(caller));

        // No longer can record.
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, caller));
        vm.prank(caller);
        calc.recordTransaction(wallet, 100e6);
    }

    // =========================================================================
    // transferOwnership
    // =========================================================================

    function test_transferOwnership_works() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        calc.transferOwnership(newOwner);
        assertEq(calc.owner(), newOwner);
    }

    function test_transferOwnership_revertsForStranger() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        calc.transferOwnership(stranger);
    }

    function test_transferOwnership_revertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ZeroAddress.selector));
        vm.prank(owner);
        calc.transferOwnership(address(0));
    }

    // =========================================================================
    // Fuzz: fee invariants
    // =========================================================================

    /// @dev Fee is always <= amount (can never drain more than was sent).
    function testFuzz_fee_neverExceedsAmount(uint96 amount, uint96 volume) public {
        // Cap volume to avoid overflow when adding to storage.
        volume = uint96(bound(volume, 0, type(uint96).max - amount));
        amount = uint96(bound(amount, 1, type(uint96).max - volume));

        if (volume > 0) {
            vm.prank(caller);
            calc.recordTransaction(wallet, volume);
        }

        uint96 fee = calc.calculateFee(wallet, amount);
        assertLe(fee, amount);
    }

    /// @dev getFeeRate returns either STANDARD or PREFERRED, nothing else.
    function testFuzz_getFeeRate_validValues(uint96 volume) public {
        if (volume > 0) {
            vm.prank(caller);
            calc.recordTransaction(wallet, volume);
        }
        uint96 rate = calc.getFeeRate(wallet);
        assertTrue(rate == STANDARD || rate == PREFERRED);
    }

    /// @dev Marginal fee math: standard + preferred portions sum correctly.
    function testFuzz_calculateFee_marginalSplit(uint96 txAmount) public {
        // Set volume to half the threshold so we always cross it.
        vm.prank(caller);
        calc.recordTransaction(wallet, THRESHOLD / 2);

        // Bound amount so it definitely straddles the threshold.
        txAmount = uint96(bound(txAmount, THRESHOLD / 2 + 1, type(uint96).max - THRESHOLD / 2));

        uint96 fee = calc.calculateFee(wallet, txAmount);

        // Manual calculation.
        uint256 remaining = THRESHOLD - (THRESHOLD / 2);
        uint256 preferredPortion = uint256(txAmount) - remaining;
        uint256 expectedFee = (remaining * STANDARD) / 10_000 + (preferredPortion * PREFERRED) / 10_000;

        assertEq(fee, uint96(expectedFee));
    }
}
