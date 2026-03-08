// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {MockFeeCalculator} from "./helpers/MockFeeCalculator.sol";
import {RemitRouter} from "../src/RemitRouter.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";
import {RemitErrors} from "../src/libraries/RemitErrors.sol";
import {RemitEvents} from "../src/libraries/RemitEvents.sol";

/// @title RemitRouterTest
/// @notice Unit tests for RemitRouter.sol
contract RemitRouterTest is Test {
    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    RemitRouter internal router;

    address internal owner = makeAddr("owner");
    address internal protocolAdmin = makeAddr("protocolAdmin");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal payer = makeAddr("payer");
    address internal recipient = makeAddr("recipient");
    address internal stranger = makeAddr("stranger");

    uint96 constant AMOUNT = 1_000e6; // $1,000
    uint96 constant MIN = RemitTypes.MIN_AMOUNT;

    function setUp() public {
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();

        RemitRouter impl = new RemitRouter();
        bytes memory data = abi.encodeCall(
            impl.initialize,
            (RemitRouter.RouterConfig({
                    owner: owner,
                    usdc: address(usdc),
                    feeCalculator: address(feeCalc),
                    protocolAdmin: protocolAdmin,
                    feeRecipient: feeRecipient
                }))
        );
        router = RemitRouter(address(new ERC1967Proxy(address(impl), data)));

        // Fund payer and approve router.
        usdc.mint(payer, 100_000e6);
        vm.prank(payer);
        usdc.approve(address(router), type(uint256).max);
    }

    // =========================================================================
    // initialize
    // =========================================================================

    function test_initialize_setsAllFields() public view {
        assertEq(router.owner(), owner);
        assertEq(router.usdc(), address(usdc));
        assertEq(router.feeCalculator(), address(feeCalc));
        assertEq(router.protocolAdmin(), protocolAdmin);
        assertEq(router.feeRecipient(), feeRecipient);
    }

    function test_initialize_revertsIfCalledAgain() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, address(this)));
        router.initialize(
            RemitRouter.RouterConfig({
                owner: stranger,
                usdc: address(usdc),
                feeCalculator: address(feeCalc),
                protocolAdmin: stranger,
                feeRecipient: stranger
            })
        );
    }

    function test_initialize_revertsOnZeroOwner() public {
        RemitRouter impl = new RemitRouter();
        bytes memory data = abi.encodeCall(
            impl.initialize,
            (RemitRouter.RouterConfig({
                    owner: address(0),
                    usdc: address(usdc),
                    feeCalculator: address(feeCalc),
                    protocolAdmin: protocolAdmin,
                    feeRecipient: feeRecipient
                }))
        );
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ZeroAddress.selector));
        new ERC1967Proxy(address(impl), data);
    }

    // =========================================================================
    // payDirect — happy path
    // =========================================================================

    function test_payDirect_happyPath() public {
        uint96 fee = uint96((uint256(AMOUNT) * 100) / 10_000); // 1%
        uint96 net = AMOUNT - fee;

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.DirectPayment(payer, recipient, AMOUNT, fee, bytes32(0));

        vm.prank(payer);
        router.payDirect(recipient, AMOUNT, bytes32(0));

        assertEq(usdc.balanceOf(recipient), net);
        assertEq(usdc.balanceOf(feeRecipient), fee);
    }

    function test_payDirect_withMemo() public {
        bytes32 memo = keccak256("invoice-42");
        vm.expectEmit(true, true, false, true);
        emit RemitEvents.DirectPayment(payer, recipient, AMOUNT, (AMOUNT * 100) / 10_000, memo);

        vm.prank(payer);
        router.payDirect(recipient, AMOUNT, memo);
    }

    function test_payDirect_minimumAmount() public {
        // MIN_AMOUNT should succeed.
        usdc.mint(payer, MIN);
        vm.prank(payer);
        router.payDirect(recipient, MIN, bytes32(0));
    }

    // =========================================================================
    // payDirect — reverts
    // =========================================================================

    function test_payDirect_revertsOnZeroTo() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ZeroAddress.selector));
        vm.prank(payer);
        router.payDirect(address(0), AMOUNT, bytes32(0));
    }

    function test_payDirect_revertsOnZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ZeroAmount.selector));
        vm.prank(payer);
        router.payDirect(recipient, 0, bytes32(0));
    }

    function test_payDirect_revertsOnSelfPayment() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.SelfPayment.selector, payer));
        vm.prank(payer);
        router.payDirect(payer, AMOUNT, bytes32(0));
    }

    function test_payDirect_revertsOnBelowMinimum() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.BelowMinimum.selector, MIN - 1, MIN));
        vm.prank(payer);
        router.payDirect(recipient, MIN - 1, bytes32(0));
    }

    // =========================================================================
    // setters — onlyOwner
    // =========================================================================

    function test_setEscrow_works() public {
        address addr = makeAddr("escrow");
        vm.prank(owner);
        router.setEscrow(addr);
        assertEq(router.escrow(), addr);
    }

    function test_setTab_works() public {
        address addr = makeAddr("tab");
        vm.prank(owner);
        router.setTab(addr);
        assertEq(router.tab(), addr);
    }

    function test_setStream_works() public {
        address addr = makeAddr("stream");
        vm.prank(owner);
        router.setStream(addr);
        assertEq(router.stream(), addr);
    }

    function test_setBounty_works() public {
        address addr = makeAddr("bounty");
        vm.prank(owner);
        router.setBounty(addr);
        assertEq(router.bounty(), addr);
    }

    function test_setDeposit_works() public {
        address addr = makeAddr("deposit");
        vm.prank(owner);
        router.setDeposit(addr);
        assertEq(router.deposit(), addr);
    }

    function test_setFeeCalculator_works() public {
        address addr = makeAddr("newFeeCalc");
        vm.prank(owner);
        router.setFeeCalculator(addr);
        assertEq(router.feeCalculator(), addr);
    }

    function test_setEscrow_revertsForStranger() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        router.setEscrow(makeAddr("x"));
    }

    function test_setEscrow_revertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ZeroAddress.selector));
        vm.prank(owner);
        router.setEscrow(address(0));
    }

    // =========================================================================
    // transferOwnership
    // =========================================================================

    function test_transferOwnership_works() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        router.transferOwnership(newOwner);
        assertEq(router.owner(), newOwner);

        // Old owner can no longer call setters.
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, owner));
        vm.prank(owner);
        router.setEscrow(makeAddr("x"));
    }

    function test_transferOwnership_revertsForStranger() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        router.transferOwnership(stranger);
    }

    // =========================================================================
    // payDirect — fee math invariant
    // =========================================================================

    function testFuzz_payDirect_feeInvariant(uint96 amount) public {
        amount = uint96(bound(amount, MIN, 50_000e6)); // keep within minted balance

        usdc.mint(payer, amount);
        uint256 payerBefore = usdc.balanceOf(payer);

        vm.prank(payer);
        router.payDirect(recipient, amount, bytes32(0));

        uint256 recipientGot = usdc.balanceOf(recipient);
        uint256 feeGot = usdc.balanceOf(feeRecipient);

        // Conservation: payer's spend == recipient's receive + fee
        assertEq(payerBefore - usdc.balanceOf(payer), recipientGot + feeGot);
        // No dust lost
        assertEq(recipientGot + feeGot, amount);
    }
}
