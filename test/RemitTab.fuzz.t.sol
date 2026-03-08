// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {MockFeeCalculator} from "./helpers/MockFeeCalculator.sol";
import {RemitTab} from "../src/RemitTab.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";

/// @title RemitTabFuzzTest
/// @notice Fuzz tests for RemitTab.sol invariants
contract RemitTabFuzzTest is Test {
    MockUSDC public usdc;
    MockFeeCalculator public feeCalc;
    RemitTab public tab;

    uint256 internal payerKey;
    uint256 internal providerKey;

    address public payer;
    address public provider;
    address public feeRecipient;

    uint64 constant EXPIRY_DELTA = 7 days;

    function setUp() public {
        payerKey = uint256(keccak256("payer"));
        providerKey = uint256(keccak256("provider"));
        payer = vm.addr(payerKey);
        provider = vm.addr(providerKey);
        feeRecipient = makeAddr("feeRecipient");

        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        tab = new RemitTab(address(usdc), address(feeCalc), feeRecipient);
    }

    // =========================================================================
    // Fuzz: fee + payout + refund == limit (no funds lost or gained)
    // =========================================================================

    /// @notice For any valid (limit, totalCharged), the accounting must be exact:
    ///         providerPayout + fee + refund == limit
    function testFuzz_balanceInvariant(uint96 limit, uint96 totalCharged) public {
        // Bound inputs to valid range
        limit = uint96(bound(limit, RemitTypes.MIN_AMOUNT, 10_000e6));
        totalCharged = uint96(bound(totalCharged, 0, limit));

        bytes32 tabId = keccak256(abi.encodePacked("tab", limit, totalCharged));

        // Fund payer
        usdc.mint(payer, limit);
        vm.prank(payer);
        usdc.approve(address(tab), type(uint256).max);

        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        // Open tab
        vm.prank(payer);
        tab.openTab(tabId, provider, limit, 1e4, uint64(block.timestamp + EXPIRY_DELTA));

        // Close tab with fuzzed charge
        bytes memory sig = _signCharge(tabId, totalCharged, 1);
        vm.prank(payer);
        tab.closeTab(tabId, totalCharged, 1, sig);

        uint256 payerAfter = usdc.balanceOf(payer);
        uint256 providerAfter = usdc.balanceOf(provider);
        uint256 feeAfter = usdc.balanceOf(feeRecipient);

        uint256 payerDelta = payerBefore - payerAfter;
        uint256 providerGain = providerAfter - providerBefore;
        uint256 feeGain = feeAfter - feeBefore;

        // Total out of payer == total in to provider + fee
        // payerDelta = providerGain + feeGain (refund returned to payer, so net is totalCharged)
        assertEq(payerDelta, providerGain + feeGain, "payer delta != provider + fee");

        // Payer net cost is exactly totalCharged (the rest is refunded)
        assertEq(payerDelta, totalCharged, "payer net cost != totalCharged");
    }

    // =========================================================================
    // Fuzz: fee never exceeds totalCharged; payout never negative
    // =========================================================================

    /// @notice MockFeeCalculator charges 1%. For any totalCharged, fee <= totalCharged.
    function testFuzz_feeNeverExceedsCharged(uint96 totalCharged) public {
        totalCharged = uint96(bound(totalCharged, 1, 10_000e6));
        uint96 fee = feeCalc.calculateFee(payer, totalCharged);
        assertLe(fee, totalCharged, "fee > totalCharged");
        // Provider payout is non-negative
        assertGe(totalCharged - fee, 0);
    }

    // =========================================================================
    // Fuzz: close at any time before/after expiry
    // =========================================================================

    /// @notice Tab can always be force-closed after expiry regardless of warp amount
    function testFuzz_closeExpiredTab(uint64 warpDelta) public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_DELTA);
        warpDelta = uint64(bound(warpDelta, 1, 365 days));

        bytes32 tabId = keccak256(abi.encodePacked("tab-expired", warpDelta));
        uint96 limit = 100e6;

        usdc.mint(payer, limit);
        vm.prank(payer);
        usdc.approve(address(tab), type(uint256).max);

        // Open BEFORE warping past expiry
        vm.prank(payer);
        tab.openTab(tabId, provider, limit, 1e4, expiry);

        // Now warp to after expiry
        vm.warp(expiry + warpDelta);

        // Close with zero charge (no sig needed)
        vm.prank(payer);
        tab.closeExpiredTab(tabId, 0, 0, "");

        assertEq(usdc.balanceOf(payer), limit, "payer should get full refund");
        assertEq(uint8(tab.getTab(tabId).status), uint8(RemitTypes.TabStatus.Closed));
    }

    // =========================================================================
    // Fuzz: any valid limit opens successfully (no overflow)
    // =========================================================================

    /// @notice Opening a tab with any limit in range should not revert or overflow
    function testFuzz_openTab(uint96 limit, uint64 expiryDelta) public {
        limit = uint96(bound(limit, RemitTypes.MIN_AMOUNT, type(uint96).max));
        expiryDelta = uint64(bound(expiryDelta, 1, 365 days));

        bytes32 tabId = keccak256(abi.encodePacked("tab-open", limit, expiryDelta));

        usdc.mint(payer, limit);
        vm.prank(payer);
        usdc.approve(address(tab), type(uint256).max);

        vm.prank(payer);
        tab.openTab(tabId, provider, limit, 1e4, uint64(block.timestamp + expiryDelta));

        RemitTypes.Tab memory t = tab.getTab(tabId);
        assertEq(t.limit, limit);
        assertEq(t.payer, payer);
        assertEq(uint8(t.status), uint8(RemitTypes.TabStatus.Open));
        assertEq(usdc.balanceOf(address(tab)), limit);
    }

    // =========================================================================
    // Fuzz: partial charges are always bounded by limit
    // =========================================================================

    /// @notice Multiple independent tabs' charges never cross-contaminate
    function testFuzz_independentTabs(uint96 limit1, uint96 charged1, uint96 limit2, uint96 charged2) public {
        limit1 = uint96(bound(limit1, RemitTypes.MIN_AMOUNT, 5_000e6));
        charged1 = uint96(bound(charged1, 0, limit1));
        limit2 = uint96(bound(limit2, RemitTypes.MIN_AMOUNT, 5_000e6));
        charged2 = uint96(bound(charged2, 0, limit2));

        bytes32 tab1 = keccak256("tab1");
        bytes32 tab2 = keccak256("tab2");

        address payer2 = makeAddr("payer2");
        usdc.mint(payer, limit1);
        usdc.mint(payer2, limit2);

        vm.prank(payer);
        usdc.approve(address(tab), type(uint256).max);
        vm.prank(payer2);
        usdc.approve(address(tab), type(uint256).max);

        vm.prank(payer);
        tab.openTab(tab1, provider, limit1, 1e4, uint64(block.timestamp + EXPIRY_DELTA));
        vm.prank(payer2);
        tab.openTab(tab2, provider, limit2, 1e4, uint64(block.timestamp + EXPIRY_DELTA));

        // Close both
        bytes memory sig1 = _signCharge(tab1, charged1, 1);
        bytes memory sig2 = _signCharge(tab2, charged2, 1);

        vm.prank(payer);
        tab.closeTab(tab1, charged1, 1, sig1);
        vm.prank(payer2);
        tab.closeTab(tab2, charged2, 1, sig2);

        // Each tab closed correctly
        assertEq(uint8(tab.getTab(tab1).status), uint8(RemitTypes.TabStatus.Closed));
        assertEq(uint8(tab.getTab(tab2).status), uint8(RemitTypes.TabStatus.Closed));

        // Tab contract holds no residual funds
        assertEq(usdc.balanceOf(address(tab)), 0);
    }

    // =========================================================================
    // Helper
    // =========================================================================

    function _signCharge(bytes32 tabId, uint96 totalCharged, uint32 callCount) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(tab.TAB_CHARGE_TYPEHASH(), tabId, totalCharged, callCount));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tab.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(providerKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
