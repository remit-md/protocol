// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {MockFeeCalculator} from "./helpers/MockFeeCalculator.sol";
import {RemitTab} from "../src/RemitTab.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";
import {RemitErrors} from "../src/libraries/RemitErrors.sol";
import {RemitEvents} from "../src/libraries/RemitEvents.sol";

/// @title RemitTabTest
/// @notice Unit tests for RemitTab.sol
contract RemitTabTest is Test {
    MockUSDC public usdc;
    MockFeeCalculator public feeCalc;
    RemitTab public tab;

    uint256 internal payerKey;
    uint256 internal providerKey;

    address public payer;
    address public provider;
    address public feeRecipient;
    address public stranger;

    uint96 constant LIMIT = 100e6; // $100 USDC
    uint64 constant PER_UNIT = 1e4; // $0.01 per call
    uint64 constant EXPIRY_DELTA = 7 days;

    bytes32 constant TAB_ID = keccak256("tab-001");

    function setUp() public {
        payerKey = uint256(keccak256("payer"));
        providerKey = uint256(keccak256("provider"));
        payer = vm.addr(payerKey);
        provider = vm.addr(providerKey);
        feeRecipient = makeAddr("feeRecipient");
        stranger = makeAddr("stranger");

        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        address tabAdmin = makeAddr("tabAdmin");
        tab = new RemitTab(address(usdc), address(feeCalc), feeRecipient, tabAdmin, address(0));

        // Fund payer and approve
        usdc.mint(payer, 10_000e6);
        vm.prank(payer);
        usdc.approve(address(tab), type(uint256).max);
    }

    // =========================================================================
    // openTab
    // =========================================================================

    function test_openTab_happyPath() public {
        vm.expectEmit(true, true, true, true);
        emit RemitEvents.TabOpened(TAB_ID, payer, provider, LIMIT, PER_UNIT, uint64(block.timestamp + EXPIRY_DELTA));

        vm.prank(payer);
        tab.openTab(TAB_ID, provider, LIMIT, PER_UNIT, uint64(block.timestamp + EXPIRY_DELTA));

        RemitTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(t.payer, payer);
        assertEq(t.provider, provider);
        assertEq(t.limit, LIMIT);
        assertEq(t.totalCharged, 0);
        assertEq(uint8(t.status), uint8(RemitTypes.TabStatus.Open));
        assertEq(usdc.balanceOf(address(tab)), LIMIT);
    }

    function test_openTab_revertsIfAlreadyExists() public {
        _openTab(TAB_ID);

        vm.expectRevert(abi.encodeWithSelector(RemitErrors.EscrowAlreadyFunded.selector, TAB_ID));
        vm.prank(payer);
        tab.openTab(TAB_ID, provider, LIMIT, PER_UNIT, uint64(block.timestamp + EXPIRY_DELTA));
    }

    function test_openTab_revertsZeroProvider() public {
        vm.expectRevert(RemitErrors.ZeroAddress.selector);
        vm.prank(payer);
        tab.openTab(TAB_ID, address(0), LIMIT, PER_UNIT, uint64(block.timestamp + EXPIRY_DELTA));
    }

    function test_openTab_revertsSelfPayment() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.SelfPayment.selector, payer));
        vm.prank(payer);
        tab.openTab(TAB_ID, payer, LIMIT, PER_UNIT, uint64(block.timestamp + EXPIRY_DELTA));
    }

    function test_openTab_revertsBelowMinimum() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.BelowMinimum.selector, 0, RemitTypes.MIN_AMOUNT));
        vm.prank(payer);
        tab.openTab(TAB_ID, provider, 0, PER_UNIT, uint64(block.timestamp + EXPIRY_DELTA));
    }

    function test_openTab_revertsExpiredExpiry() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.InvalidTimeout.selector, block.timestamp));
        vm.prank(payer);
        tab.openTab(TAB_ID, provider, LIMIT, PER_UNIT, uint64(block.timestamp));
    }

    // =========================================================================
    // closeTab — happy paths
    // =========================================================================

    function test_closeTab_byPayer_fullCharge() public {
        _openTab(TAB_ID);

        uint96 charged = LIMIT; // exact limit
        uint32 calls = 10_000;
        bytes memory sig = _signCharge(TAB_ID, charged, calls);

        uint96 fee = feeCalc.calculateFee(payer, charged);
        uint96 providerPayout = charged - fee;
        uint96 refund = LIMIT - charged; // 0

        vm.expectEmit(true, false, false, true);
        emit RemitEvents.TabClosed(TAB_ID, charged, refund, fee);

        vm.prank(payer);
        tab.closeTab(TAB_ID, charged, calls, sig);

        assertEq(usdc.balanceOf(provider), providerPayout);
        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(usdc.balanceOf(payer), 10_000e6 - LIMIT + refund);
        assertEq(uint8(tab.getTab(TAB_ID).status), uint8(RemitTypes.TabStatus.Closed));
    }

    function test_closeTab_byProvider_partialCharge() public {
        _openTab(TAB_ID);

        uint96 charged = 30e6; // $30 of $100 limit
        uint32 calls = 3_000;
        bytes memory sig = _signCharge(TAB_ID, charged, calls);

        uint96 fee = feeCalc.calculateFee(payer, charged);
        uint96 providerPayout = charged - fee;
        uint96 refund = LIMIT - charged; // $70

        vm.prank(provider);
        tab.closeTab(TAB_ID, charged, calls, sig);

        assertEq(usdc.balanceOf(provider), providerPayout);
        assertEq(usdc.balanceOf(feeRecipient), fee);
        // payer gets refund (started with 10_000e6, locked LIMIT, gets LIMIT-charged back)
        assertEq(usdc.balanceOf(payer), 10_000e6 - LIMIT + refund);
    }

    function test_closeTab_zeroCharged_fullRefund() public {
        _openTab(TAB_ID);

        uint32 calls = 0;
        // zero charge: sig can be empty since we skip verification when totalCharged == 0
        // (Note: closeTab always verifies sig; only closeExpiredTab skips on zero)
        // So for closeTab we still need a valid sig even for zero
        bytes memory sig = _signCharge(TAB_ID, 0, calls);

        vm.prank(payer);
        tab.closeTab(TAB_ID, 0, calls, sig);

        assertEq(usdc.balanceOf(provider), 0);
        assertEq(usdc.balanceOf(feeRecipient), 0);
        assertEq(usdc.balanceOf(payer), 10_000e6); // full refund
    }

    function test_closeTab_atExactLimit_zeroRefund() public {
        _openTab(TAB_ID);

        uint96 charged = LIMIT;
        bytes memory sig = _signCharge(TAB_ID, charged, 100);

        vm.prank(payer);
        tab.closeTab(TAB_ID, charged, 100, sig);

        uint96 fee = feeCalc.calculateFee(payer, charged);
        assertEq(usdc.balanceOf(provider), charged - fee);
        assertEq(usdc.balanceOf(payer), 10_000e6 - LIMIT); // no refund
    }

    // =========================================================================
    // closeTab — reverts
    // =========================================================================

    function test_closeTab_revertsNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.TabNotFound.selector, TAB_ID));
        vm.prank(payer);
        tab.closeTab(TAB_ID, 0, 0, "");
    }

    function test_closeTab_revertsAlreadyClosed() public {
        _openTab(TAB_ID);
        bytes memory sig = _signCharge(TAB_ID, 0, 0);
        vm.prank(payer);
        tab.closeTab(TAB_ID, 0, 0, sig);

        // Second close should revert
        sig = _signCharge(TAB_ID, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.TabDepleted.selector, TAB_ID));
        vm.prank(payer);
        tab.closeTab(TAB_ID, 0, 0, sig);
    }

    function test_closeTab_revertsUnauthorized() public {
        _openTab(TAB_ID);
        bytes memory sig = _signCharge(TAB_ID, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        tab.closeTab(TAB_ID, 0, 0, sig);
    }

    function test_closeTab_revertsOvercharge() public {
        _openTab(TAB_ID);
        uint96 overcharge = LIMIT + 1;
        bytes memory sig = _signCharge(TAB_ID, overcharge, 1);

        vm.expectRevert(abi.encodeWithSelector(RemitErrors.InsufficientBalance.selector, LIMIT, overcharge));
        vm.prank(payer);
        tab.closeTab(TAB_ID, overcharge, 1, sig);
    }

    function test_closeTab_revertsInvalidSig() public {
        _openTab(TAB_ID);
        // Sign with wrong key (payer key instead of provider key)
        uint96 charged = 10e6;
        bytes32 structHash = keccak256(abi.encode(tab.TAB_CHARGE_TYPEHASH(), TAB_ID, charged, uint32(100)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tab.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, digest); // wrong key
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.expectRevert(RemitErrors.InvalidSignature.selector);
        vm.prank(payer);
        tab.closeTab(TAB_ID, charged, 100, badSig);
    }

    // =========================================================================
    // closeExpiredTab
    // =========================================================================

    function test_closeExpiredTab_happyPath() public {
        _openTab(TAB_ID);
        vm.warp(block.timestamp + EXPIRY_DELTA + 1);

        uint96 charged = 50e6;
        bytes memory sig = _signCharge(TAB_ID, charged, 50);

        vm.prank(payer);
        tab.closeExpiredTab(TAB_ID, charged, 50, sig);

        assertEq(uint8(tab.getTab(TAB_ID).status), uint8(RemitTypes.TabStatus.Closed));
        assertEq(usdc.balanceOf(payer), 10_000e6 - LIMIT + (LIMIT - charged));
    }

    function test_closeExpiredTab_zeroCharge_noSigRequired() public {
        _openTab(TAB_ID);
        vm.warp(block.timestamp + EXPIRY_DELTA + 1);

        // Empty sig should work when totalCharged == 0
        vm.prank(payer);
        tab.closeExpiredTab(TAB_ID, 0, 0, "");

        assertEq(usdc.balanceOf(payer), 10_000e6); // full refund
    }

    function test_closeExpiredTab_revertsIfNotExpired() public {
        _openTab(TAB_ID);
        bytes memory sig = _signCharge(TAB_ID, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(RemitErrors.InvalidTimeout.selector, uint64(block.timestamp + EXPIRY_DELTA))
        );
        vm.prank(payer);
        tab.closeExpiredTab(TAB_ID, 0, 0, sig);
    }

    function test_closeExpiredTab_revertsUnauthorized() public {
        _openTab(TAB_ID);
        vm.warp(block.timestamp + EXPIRY_DELTA + 1);
        bytes memory sig = _signCharge(TAB_ID, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        tab.closeExpiredTab(TAB_ID, 0, 0, sig);
    }

    function test_closeExpiredTab_revertsOvercharge() public {
        _openTab(TAB_ID);
        vm.warp(block.timestamp + EXPIRY_DELTA + 1);
        uint96 overcharge = LIMIT + 1;
        bytes memory sig = _signCharge(TAB_ID, overcharge, 1);

        vm.expectRevert(abi.encodeWithSelector(RemitErrors.InsufficientBalance.selector, LIMIT, overcharge));
        vm.prank(payer);
        tab.closeExpiredTab(TAB_ID, overcharge, 1, sig);
    }

    function test_closeExpiredTab_byProvider() public {
        _openTab(TAB_ID);
        vm.warp(block.timestamp + EXPIRY_DELTA + 1);

        uint96 charged = 20e6;
        bytes memory sig = _signCharge(TAB_ID, charged, 20);

        vm.prank(provider);
        tab.closeExpiredTab(TAB_ID, charged, 20, sig);

        assertEq(uint8(tab.getTab(TAB_ID).status), uint8(RemitTypes.TabStatus.Closed));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _openTab(bytes32 tabId) internal {
        vm.prank(payer);
        tab.openTab(tabId, provider, LIMIT, PER_UNIT, uint64(block.timestamp + EXPIRY_DELTA));
    }

    /// @dev Sign TabCharge with the provider's key
    function _signCharge(bytes32 tabId, uint96 totalCharged, uint32 callCount) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(tab.TAB_CHARGE_TYPEHASH(), tabId, totalCharged, callCount));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tab.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(providerKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
