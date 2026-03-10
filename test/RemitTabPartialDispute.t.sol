// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/test/MockUSDC.sol";
import {MockFeeCalculator} from "./helpers/MockFeeCalculator.sol";
import {RemitTab} from "../src/RemitTab.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";
import {RemitErrors} from "../src/libraries/RemitErrors.sol";
import {RemitEvents} from "../src/libraries/RemitEvents.sol";

/// @title RemitTabPartialDisputeTest
/// @notice Unit tests for V2 metered tab partial disputes
contract RemitTabPartialDisputeTest is Test {
    MockUSDC public usdc;
    MockFeeCalculator public feeCalc;
    RemitTab public tab;

    uint256 internal payerKey;
    uint256 internal providerKey;

    address public payer;
    address public provider;
    address public feeRecipient;
    address public admin;
    address public stranger;

    uint96 constant LIMIT = 100e6; // $100 USDC
    uint64 constant PER_UNIT = 1e4; // $0.01 per call
    uint64 constant EXPIRY_DELTA = 7 days;

    bytes32 constant TAB_ID = keccak256("tab-001");

    function setUp() public {
        vm.warp(1_000_000); // avoid degradationTimestamp == 0 when block.timestamp starts at 1

        payerKey = uint256(keccak256("payer"));
        providerKey = uint256(keccak256("provider"));
        payer = vm.addr(payerKey);
        provider = vm.addr(providerKey);
        feeRecipient = makeAddr("feeRecipient");
        admin = makeAddr("admin");
        stranger = makeAddr("stranger");

        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        tab = new RemitTab(address(usdc), address(feeCalc), feeRecipient, admin, address(0));

        usdc.mint(payer, 10_000e6);
        vm.prank(payer);
        usdc.approve(address(tab), type(uint256).max);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _openTab() internal {
        vm.prank(payer);
        tab.openTab(TAB_ID, provider, LIMIT, PER_UNIT, uint64(block.timestamp + EXPIRY_DELTA));
    }

    function _signCharge(bytes32 tabId, uint96 amount, uint32 calls, uint256 signerKey)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domainSep = tab.domainSeparator();
        bytes32 structHash = keccak256(abi.encode(tab.TAB_CHARGE_TYPEHASH(), tabId, amount, calls));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // =========================================================================
    // Happy path: partial dispute splits correctly
    // =========================================================================

    function test_filePartialDispute_happyPath() public {
        _openTab();

        // Provider signs: 60 USDC undisputed (charges before degradation)
        uint96 undisputedAmount = 60e6;
        uint32 undisputedCalls = 6000;
        bytes memory undisputedSig = _signCharge(TAB_ID, undisputedAmount, undisputedCalls, providerKey);

        // Provider signs: 80 USDC total (60 + 20 post-degradation)
        uint96 totalCharged = 80e6;
        uint32 totalCalls = 8000;
        bytes memory totalSig = _signCharge(TAB_ID, totalCharged, totalCalls, providerKey);

        uint64 degradationTs = uint64(block.timestamp - 1); // past timestamp

        uint96 disputedAmount = totalCharged - undisputedAmount; // 20 USDC
        uint96 undisputedFee = uint96((uint256(undisputedAmount) * 100) / 10_000); // 1% = 0.60 USDC
        uint96 providerUndisputed = undisputedAmount - undisputedFee;
        uint96 refund = LIMIT - totalCharged; // 100 - 80 = 20 USDC

        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 payerBefore = usdc.balanceOf(payer);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.TabPartialDispute(TAB_ID, payer, degradationTs, disputedAmount, undisputedAmount);

        vm.prank(payer);
        tab.filePartialDispute(
            TAB_ID, degradationTs, undisputedAmount, undisputedCalls, undisputedSig, totalCharged, totalCalls, totalSig
        );

        // Verify tab state
        RemitTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(uint8(t.status), uint8(RemitTypes.TabStatus.PartiallyDisputed));
        assertEq(t.totalCharged, totalCharged);
        assertEq(t.degradationTimestamp, degradationTs);
        assertEq(t.disputedAmount, disputedAmount);

        // Verify fund distribution
        assertEq(usdc.balanceOf(provider) - providerBefore, providerUndisputed, "provider undisputed wrong");
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, undisputedFee, "fee wrong");
        assertEq(usdc.balanceOf(payer) - payerBefore, refund, "refund wrong");
        // disputedAmount (20 USDC) should still be in contract
        assertEq(usdc.balanceOf(address(tab)), disputedAmount, "contract should hold disputed amount");
    }

    function test_filePartialDispute_zeroUndisputed_allDisputed() public {
        _openTab();

        // Provider signed 0 undisputed (all charges post-degradation)
        uint96 undisputedAmount = 0;
        // Need to sign with 0 — _verifyProviderSig requires signature for 0 case
        // Actually, undisputedSig is verified for undisputedAmount=0, callCount=0
        bytes memory undisputedSig = _signCharge(TAB_ID, 0, 0, providerKey);
        uint96 totalCharged = 50e6;
        bytes memory totalSig = _signCharge(TAB_ID, totalCharged, 5000, providerKey);

        uint64 degradationTs = uint64(block.timestamp - 1);

        vm.prank(payer);
        tab.filePartialDispute(TAB_ID, degradationTs, undisputedAmount, 0, undisputedSig, totalCharged, 5000, totalSig);

        RemitTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(uint8(t.status), uint8(RemitTypes.TabStatus.PartiallyDisputed));
        assertEq(t.disputedAmount, totalCharged, "all should be disputed");
        assertEq(usdc.balanceOf(address(tab)), totalCharged, "full amount frozen");
    }

    // =========================================================================
    // Undisputed charges release correctly, disputed frozen
    // =========================================================================

    function test_filePartialDispute_fundsConserved() public {
        _openTab();

        uint96 undisputedAmount = 40e6;
        uint96 totalCharged = 70e6;
        bytes memory undisputedSig = _signCharge(TAB_ID, undisputedAmount, 4000, providerKey);
        bytes memory totalSig = _signCharge(TAB_ID, totalCharged, 7000, providerKey);

        uint256 contractBefore = usdc.balanceOf(address(tab)); // == LIMIT

        vm.prank(payer);
        tab.filePartialDispute(
            TAB_ID, uint64(block.timestamp - 1), undisputedAmount, 4000, undisputedSig, totalCharged, 7000, totalSig
        );

        uint256 contractAfter = usdc.balanceOf(address(tab));
        uint96 disputedAmount = totalCharged - undisputedAmount; // 30 USDC

        assertEq(contractAfter, disputedAmount, "contract should hold exactly disputed amount");
        assertEq(contractBefore - contractAfter, LIMIT - disputedAmount, "distributed amount wrong");
    }

    // =========================================================================
    // Resolution of partial dispute
    // =========================================================================

    function test_resolvePartialDispute_adminSplits() public {
        _openTab();

        uint96 undisputedAmount = 60e6;
        uint96 totalCharged = 80e6;
        uint96 disputedAmount = totalCharged - undisputedAmount; // 20e6

        bytes memory undisputedSig = _signCharge(TAB_ID, undisputedAmount, 6000, providerKey);
        bytes memory totalSig = _signCharge(TAB_ID, totalCharged, 8000, providerKey);

        vm.prank(payer);
        tab.filePartialDispute(
            TAB_ID, uint64(block.timestamp - 1), undisputedAmount, 6000, undisputedSig, totalCharged, 8000, totalSig
        );

        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 payerBefore = usdc.balanceOf(payer);

        // Admin resolves: provider gets 10, payer gets 10
        uint96 providerAward = 10e6;
        uint96 payerAward = 10e6;

        vm.prank(admin);
        tab.resolvePartialDispute(TAB_ID, providerAward, payerAward);

        assertEq(usdc.balanceOf(provider) - providerBefore, providerAward, "provider resolution wrong");
        assertEq(usdc.balanceOf(payer) - payerBefore, payerAward, "payer resolution wrong");
        assertEq(usdc.balanceOf(address(tab)), 0, "contract still holds funds");

        RemitTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(uint8(t.status), uint8(RemitTypes.TabStatus.Closed));
        assertEq(t.disputedAmount, 0);
    }

    function test_resolvePartialDispute_revertsOnAmountMismatch() public {
        _openTab();

        uint96 undisputedAmount = 60e6;
        uint96 totalCharged = 80e6;
        bytes memory undisputedSig = _signCharge(TAB_ID, undisputedAmount, 6000, providerKey);
        bytes memory totalSig = _signCharge(TAB_ID, totalCharged, 8000, providerKey);

        vm.prank(payer);
        tab.filePartialDispute(
            TAB_ID, uint64(block.timestamp - 1), undisputedAmount, 6000, undisputedSig, totalCharged, 8000, totalSig
        );

        vm.prank(admin);
        vm.expectRevert();
        tab.resolvePartialDispute(TAB_ID, 15e6, 10e6); // 25 != 20
    }

    function test_resolvePartialDispute_revertsIfNotAdmin() public {
        _openTab();

        bytes memory undisputedSig = _signCharge(TAB_ID, 60e6, 6000, providerKey);
        bytes memory totalSig = _signCharge(TAB_ID, 80e6, 8000, providerKey);

        vm.prank(payer);
        tab.filePartialDispute(TAB_ID, uint64(block.timestamp - 1), 60e6, 6000, undisputedSig, 80e6, 8000, totalSig);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        tab.resolvePartialDispute(TAB_ID, 10e6, 10e6);
    }

    // =========================================================================
    // Validation errors
    // =========================================================================

    function test_filePartialDispute_revertsIfNotPayer() public {
        _openTab();
        bytes memory undisputedSig = _signCharge(TAB_ID, 40e6, 4000, providerKey);
        bytes memory totalSig = _signCharge(TAB_ID, 60e6, 6000, providerKey);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        tab.filePartialDispute(TAB_ID, uint64(block.timestamp - 1), 40e6, 4000, undisputedSig, 60e6, 6000, totalSig);
    }

    function test_filePartialDispute_revertsOnFutureDegradationTimestamp() public {
        _openTab();
        bytes memory undisputedSig = _signCharge(TAB_ID, 40e6, 4000, providerKey);
        bytes memory totalSig = _signCharge(TAB_ID, 60e6, 6000, providerKey);

        uint64 futureTs = uint64(block.timestamp + 100);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.InvalidTimeout.selector, futureTs));
        tab.filePartialDispute(TAB_ID, futureTs, 40e6, 4000, undisputedSig, 60e6, 6000, totalSig);
    }

    function test_filePartialDispute_revertsOnUndisputedExceedsTotal() public {
        _openTab();
        bytes memory undisputedSig = _signCharge(TAB_ID, 70e6, 7000, providerKey);
        bytes memory totalSig = _signCharge(TAB_ID, 60e6, 6000, providerKey);

        vm.prank(payer);
        vm.expectRevert();
        tab.filePartialDispute(TAB_ID, uint64(block.timestamp - 1), 70e6, 7000, undisputedSig, 60e6, 6000, totalSig);
    }

    function test_filePartialDispute_revertsOnNothingToDispute() public {
        _openTab();
        // undisputedAmount == totalCharged → nothing to dispute
        bytes memory sig = _signCharge(TAB_ID, 60e6, 6000, providerKey);

        vm.prank(payer);
        vm.expectRevert(RemitErrors.ZeroAmount.selector);
        tab.filePartialDispute(TAB_ID, uint64(block.timestamp - 1), 60e6, 6000, sig, 60e6, 6000, sig);
    }

    function test_filePartialDispute_revertsOnClosedTab() public {
        _openTab();

        // Close the tab first
        bytes memory closeSig = _signCharge(TAB_ID, 50e6, 5000, providerKey);
        vm.prank(payer);
        tab.closeTab(TAB_ID, 50e6, 5000, closeSig);

        bytes memory undisputedSig = _signCharge(TAB_ID, 40e6, 4000, providerKey);
        bytes memory totalSig = _signCharge(TAB_ID, 50e6, 5000, providerKey);

        vm.prank(payer);
        vm.expectRevert();
        tab.filePartialDispute(TAB_ID, uint64(block.timestamp - 1), 40e6, 4000, undisputedSig, 50e6, 5000, totalSig);
    }
}
