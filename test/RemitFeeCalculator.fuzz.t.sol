// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RemitFeeCalculator} from "../src/RemitFeeCalculator.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";

/// @title RemitFeeCalculatorFuzzTest
/// @notice Property-based fuzz tests for RemitFeeCalculator
contract RemitFeeCalculatorFuzzTest is Test {
    RemitFeeCalculator internal calc;

    address internal owner = makeAddr("owner");
    address internal caller = makeAddr("caller");

    function setUp() public {
        RemitFeeCalculator impl = new RemitFeeCalculator();
        bytes memory data = abi.encodeCall(impl.initialize, (owner));
        calc = RemitFeeCalculator(address(new ERC1967Proxy(address(impl), data)));

        vm.prank(owner);
        calc.authorizeCaller(caller);

        // Warp to a known date: 2026-03-15 00:00:00 UTC
        vm.warp(1773532800);
    }

    // =========================================================================
    // Month key determinism: same timestamp always gives same month key
    // =========================================================================

    /// @dev Volume recorded in the same month always accumulates
    function testFuzz_sameMonthVolumeAccumulates(uint96 a, uint96 b) public {
        a = uint96(bound(a, 1, type(uint88).max));
        b = uint96(bound(b, 1, type(uint88).max));

        address w = makeAddr("w1");

        vm.startPrank(caller);
        calc.recordTransaction(w, a);
        calc.recordTransaction(w, b);
        vm.stopPrank();

        assertEq(calc.getMonthlyVolume(w), uint256(a) + uint256(b));
    }

    /// @dev Volume resets when crossing any month boundary
    function testFuzz_volumeResetsOnNewMonth(uint96 amount, uint32 dayOffset) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        dayOffset = uint32(bound(dayOffset, 28, 365)); // at least 28 days forward guarantees new month

        address w = makeAddr("w2");

        vm.prank(caller);
        calc.recordTransaction(w, amount);
        assertEq(calc.getMonthlyVolume(w), amount);

        // Warp forward by at least 28 days (guaranteed new month)
        vm.warp(block.timestamp + uint256(dayOffset) * 1 days);

        assertEq(calc.getMonthlyVolume(w), 0);
    }

    // =========================================================================
    // Fee monotonicity: higher amount => higher or equal fee
    // =========================================================================

    /// @dev Fee is monotonically non-decreasing with amount (same wallet/volume)
    function testFuzz_feeMonotonicity(uint96 amountLow, uint96 amountHigh, uint96 volume) public {
        amountLow = uint96(bound(amountLow, 1, type(uint88).max));
        amountHigh = uint96(bound(amountHigh, amountLow, type(uint88).max));
        volume = uint96(bound(volume, 0, type(uint88).max));

        address w = makeAddr("w3");
        if (volume > 0) {
            vm.prank(caller);
            calc.recordTransaction(w, volume);
        }

        uint96 feeLow = calc.calculateFee(w, amountLow);
        uint96 feeHigh = calc.calculateFee(w, amountHigh);
        assertLe(feeLow, feeHigh, "fee must be monotonically non-decreasing with amount");
    }

    // =========================================================================
    // Preferred rate is always <= standard rate for same amount
    // =========================================================================

    /// @dev Once above threshold, fee is always <= what it would be at standard rate
    function testFuzz_preferredRateNeverExceedsStandard(uint96 amount) public {
        amount = uint96(bound(amount, 1, type(uint96).max));

        address w = makeAddr("w4");

        // Standard rate (no volume)
        uint96 standardFee = calc.calculateFee(w, amount);

        // Push above threshold
        vm.prank(caller);
        calc.recordTransaction(w, RemitTypes.FEE_THRESHOLD);

        // Preferred rate
        uint96 preferredFee = calc.calculateFee(w, amount);

        assertLe(preferredFee, standardFee, "preferred fee must not exceed standard fee");
    }

    // =========================================================================
    // Fee precision: fee * 10000 / amount should equal the rate in bps
    // =========================================================================

    /// @dev Fee is exactly rate * amount / 10000 (no rounding beyond integer division)
    function testFuzz_feeExactCalculation(uint96 amount, uint96 volume) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        volume = uint96(bound(volume, 0, type(uint96).max - amount));

        address w = makeAddr("w5");
        if (volume > 0) {
            vm.prank(caller);
            calc.recordTransaction(w, volume);
        }

        uint96 fee = calc.calculateFee(w, amount);
        uint96 rate = volume >= RemitTypes.FEE_THRESHOLD ? RemitTypes.FEE_RATE_PREFERRED_BPS : RemitTypes.FEE_RATE_BPS;

        assertEq(fee, uint96((uint256(amount) * rate) / 10_000));
    }
}
