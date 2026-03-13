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

        // Warp to a known date: 2026-03-15 00:00:00 UTC
        vm.warp(1773532800);
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
    // calculateFee — standard rate (below cliff)
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
    // calculateFee — preferred rate (above cliff)
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
    // calculateFee — cliff behavior (no marginal split)
    // =========================================================================

    function test_calculateFee_cliff_transactionCrossingThreshold() public {
        // Volume at $9,500. Transaction of $1,000 would cross $10k.
        // Cliff: entire $1,000 charged at STANDARD (you haven't crossed yet).
        vm.prank(caller);
        calc.recordTransaction(wallet, 9_500e6);

        uint96 amount = 1_000e6;
        uint96 fee = calc.calculateFee(wallet, amount);

        // Under old marginal: $500 at 1% + $500 at 0.5% = $7.50
        // Under cliff: full $1,000 at 1% = $10.00
        assertEq(fee, (uint256(amount) * STANDARD) / 10_000);
    }

    function test_calculateFee_cliff_firstTransactionAfterCrossing() public {
        // Volume at $9,500 + record $1,000 → volume = $10,500 (above cliff).
        vm.startPrank(caller);
        calc.recordTransaction(wallet, 9_500e6);
        calc.recordTransaction(wallet, 1_000e6);
        vm.stopPrank();

        // Next transaction should be at preferred rate.
        uint96 amount = 500e6;
        uint96 fee = calc.calculateFee(wallet, amount);
        assertEq(fee, (uint256(amount) * PREFERRED) / 10_000);
    }

    function test_calculateFee_cliff_oneBelowThreshold() public {
        // Volume at THRESHOLD - 1. Still below → standard rate for entire transaction.
        vm.prank(caller);
        calc.recordTransaction(wallet, THRESHOLD - 1);

        uint96 fee = calc.calculateFee(wallet, 1_000e6);
        assertEq(fee, (uint256(1_000e6) * STANDARD) / 10_000);
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
    // Calendar month volume reset
    // =========================================================================

    function test_volumeResets_onCalendarMonthBoundary() public {
        // Record volume on March 15, 2026
        vm.prank(caller);
        calc.recordTransaction(wallet, 9_000e6);
        assertEq(calc.getMonthlyVolume(wallet), 9_000e6);

        // Warp to April 1, 2026 00:00:00 UTC (next calendar month)
        vm.warp(1775001600);

        // Volume is now 0 (new month).
        assertEq(calc.getMonthlyVolume(wallet), 0);

        // Fee recalculates from zero → standard rate.
        uint96 fee = calc.calculateFee(wallet, 1_000e6);
        assertEq(fee, (1_000e6 * STANDARD) / 10_000);
    }

    function test_recordTransaction_resetsThenAccumulates() public {
        // Record in March 2026
        vm.prank(caller);
        calc.recordTransaction(wallet, 9_000e6);

        // Warp to April 1, 2026
        vm.warp(1775001600);

        // Record in new month — should start fresh.
        vm.prank(caller);
        calc.recordTransaction(wallet, 500e6);

        assertEq(calc.getMonthlyVolume(wallet), 500e6);
    }

    function test_volumeNotReset_sameMonth() public {
        // Record on March 1, 2026
        vm.warp(1772323200);
        vm.prank(caller);
        calc.recordTransaction(wallet, 5_000e6);

        // Warp to March 31, 2026 23:59:59 UTC (same month)
        vm.warp(1775001599);

        vm.prank(caller);
        calc.recordTransaction(wallet, 2_000e6);

        assertEq(calc.getMonthlyVolume(wallet), 7_000e6);
    }

    function test_volumeResets_jan31ToFeb1() public {
        // Warp to Jan 31, 2026 12:00:00 UTC
        vm.warp(1769860800);

        vm.prank(caller);
        calc.recordTransaction(wallet, 8_000e6);
        assertEq(calc.getMonthlyVolume(wallet), 8_000e6);

        // Warp to Feb 1, 2026 00:00:00 UTC
        vm.warp(1769904000);

        // Volume resets on calendar month boundary.
        assertEq(calc.getMonthlyVolume(wallet), 0);
    }

    function test_volumeNotReset_sameDayDifferentHour() public {
        // Warp to March 15, 2026 08:00:00 UTC
        vm.warp(1773561600);

        vm.prank(caller);
        calc.recordTransaction(wallet, 3_000e6);

        // Warp to March 15, 2026 20:00:00 UTC (same day)
        vm.warp(1773604800);

        vm.prank(caller);
        calc.recordTransaction(wallet, 1_000e6);

        assertEq(calc.getMonthlyVolume(wallet), 4_000e6);
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
        // Bound amount first (minimum 1), then cap volume to avoid overflow.
        amount = uint96(bound(amount, 1, type(uint96).max));
        volume = uint96(bound(volume, 0, type(uint96).max - amount));

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

    /// @dev Cliff fee: below threshold → always STANDARD rate, above → always PREFERRED.
    function testFuzz_calculateFee_cliffBehavior(uint96 txAmount, uint96 volume) public {
        txAmount = uint96(bound(txAmount, 1, type(uint96).max));
        volume = uint96(bound(volume, 0, type(uint96).max - txAmount));

        if (volume > 0) {
            vm.prank(caller);
            calc.recordTransaction(wallet, volume);
        }

        uint96 fee = calc.calculateFee(wallet, txAmount);

        // Cliff: rate is determined by volume BEFORE this transaction.
        uint256 effectiveVolume = volume; // volume is what was recorded
        if (effectiveVolume >= THRESHOLD) {
            assertEq(fee, uint96((uint256(txAmount) * PREFERRED) / 10_000));
        } else {
            assertEq(fee, uint96((uint256(txAmount) * STANDARD) / 10_000));
        }
    }
}
