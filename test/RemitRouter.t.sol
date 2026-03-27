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
    // payDirect - happy path
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
    // payDirect - reverts
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
    // setters - onlyOwner
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
    // payDirect - fee math invariant
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

    // =========================================================================
    // settleX402 - EIP-3009 helpers
    // =========================================================================

    bytes32 private constant _TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("USD Coin"),
                keccak256("2"),
                block.chainid,
                address(usdc)
            )
        );
    }

    /// @dev Sign an EIP-3009 transferWithAuthorization for the given params.
    function _signAuth(
        uint256 signerKey,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(_TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (v, r, s) = vm.sign(signerKey, digest);
    }

    // Use a deterministic private key for the payer so we can sign EIP-3009 auths.
    uint256 internal constant PAYER_KEY = 0xA11CE;

    function _payerAddr() internal pure returns (address) {
        return vm.addr(PAYER_KEY);
    }

    /// @dev Fund the keyed payer and return a valid settleX402 call's params.
    function _setupX402(uint96 amount, bytes32 nonce)
        internal
        returns (address from, uint256 validAfter, uint256 validBefore, uint8 v, bytes32 r, bytes32 s)
    {
        from = _payerAddr();
        usdc.mint(from, amount);
        validAfter = 0;
        validBefore = block.timestamp + 1 hours;
        (v, r, s) = _signAuth(PAYER_KEY, from, address(router), amount, validAfter, validBefore, nonce);
    }

    // =========================================================================
    // settleX402 - happy path
    // =========================================================================

    function test_settleX402_happyPath() public {
        bytes32 nonce = bytes32(uint256(1));
        (address from, uint256 validAfter, uint256 validBefore, uint8 v, bytes32 r, bytes32 s) =
            _setupX402(AMOUNT, nonce);

        uint96 fee = uint96((uint256(AMOUNT) * 100) / 10_000); // 1%
        uint96 net = AMOUNT - fee;

        vm.expectEmit(true, true, true, true);
        emit RemitEvents.X402Payment(from, recipient, AMOUNT, fee, nonce);

        router.settleX402(from, recipient, AMOUNT, validAfter, validBefore, nonce, v, r, s);

        // Conservation: recipient gets net, feeRecipient gets fee, payer debited full amount.
        assertEq(usdc.balanceOf(recipient), net, "recipient balance");
        assertEq(usdc.balanceOf(feeRecipient), fee, "fee balance");
        assertEq(usdc.balanceOf(from), 0, "payer should be drained");
        // Router holds nothing.
        assertEq(usdc.balanceOf(address(router)), 0, "router should hold zero");
    }

    function test_settleX402_volumeRecorded() public {
        bytes32 nonce = bytes32(uint256(2));
        (address from, uint256 validAfter, uint256 validBefore, uint8 v, bytes32 r, bytes32 s) =
            _setupX402(AMOUNT, nonce);

        router.settleX402(from, recipient, AMOUNT, validAfter, validBefore, nonce, v, r, s);

        assertEq(feeCalc.monthlyVolume(from), AMOUNT, "volume should be recorded");
    }

    function test_settleX402_minimumAmount() public {
        bytes32 nonce = bytes32(uint256(3));
        (address from, uint256 validAfter, uint256 validBefore, uint8 v, bytes32 r, bytes32 s) = _setupX402(MIN, nonce);

        router.settleX402(from, recipient, MIN, validAfter, validBefore, nonce, v, r, s);

        assertGt(usdc.balanceOf(recipient), 0, "recipient should receive funds");
    }

    function test_settleX402_anyoneCanSubmit() public {
        // A stranger (not the payer, not the server) can submit the settlement.
        // This is by design - the EIP-3009 auth protects funds, not the submitter identity.
        bytes32 nonce = bytes32(uint256(4));
        (address from, uint256 validAfter, uint256 validBefore, uint8 v, bytes32 r, bytes32 s) =
            _setupX402(AMOUNT, nonce);

        vm.prank(stranger);
        router.settleX402(from, recipient, AMOUNT, validAfter, validBefore, nonce, v, r, s);

        assertEq(usdc.balanceOf(recipient), AMOUNT - uint96((uint256(AMOUNT) * 100) / 10_000));
    }

    // =========================================================================
    // settleX402 - reverts
    // =========================================================================

    function test_settleX402_revertsOnZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ZeroAmount.selector));
        router.settleX402(_payerAddr(), recipient, 0, 0, block.timestamp + 1, bytes32(0), 27, bytes32(0), bytes32(0));
    }

    function test_settleX402_revertsOnBelowMinimum() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.BelowMinimum.selector, MIN - 1, MIN));
        router.settleX402(
            _payerAddr(), recipient, MIN - 1, 0, block.timestamp + 1, bytes32(0), 27, bytes32(0), bytes32(0)
        );
    }

    function test_settleX402_revertsOnZeroFrom() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ZeroAddress.selector));
        router.settleX402(address(0), recipient, AMOUNT, 0, block.timestamp + 1, bytes32(0), 27, bytes32(0), bytes32(0));
    }

    function test_settleX402_revertsOnZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ZeroAddress.selector));
        router.settleX402(
            _payerAddr(), address(0), AMOUNT, 0, block.timestamp + 1, bytes32(0), 27, bytes32(0), bytes32(0)
        );
    }

    function test_settleX402_revertsOnSelfPayment() public {
        address from = _payerAddr();
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.SelfPayment.selector, from));
        router.settleX402(from, from, AMOUNT, 0, block.timestamp + 1, bytes32(0), 27, bytes32(0), bytes32(0));
    }

    function test_settleX402_revertsOnExpiredAuth() public {
        bytes32 nonce = bytes32(uint256(5));
        address from = _payerAddr();
        usdc.mint(from, AMOUNT);

        uint256 validBefore = block.timestamp - 1; // already expired
        (uint8 v, bytes32 r, bytes32 s) = _signAuth(PAYER_KEY, from, address(router), AMOUNT, 0, validBefore, nonce);

        vm.expectRevert("MockUSDC: authorization expired");
        router.settleX402(from, recipient, AMOUNT, 0, validBefore, nonce, v, r, s);
    }

    function test_settleX402_revertsOnNotYetValid() public {
        bytes32 nonce = bytes32(uint256(6));
        address from = _payerAddr();
        usdc.mint(from, AMOUNT);

        uint256 validAfter = block.timestamp + 1 hours; // not yet valid
        uint256 validBefore = block.timestamp + 2 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signAuth(PAYER_KEY, from, address(router), AMOUNT, validAfter, validBefore, nonce);

        vm.expectRevert("MockUSDC: not yet valid");
        router.settleX402(from, recipient, AMOUNT, validAfter, validBefore, nonce, v, r, s);
    }

    function test_settleX402_revertsOnInvalidSignature() public {
        bytes32 nonce = bytes32(uint256(7));
        address from = _payerAddr();
        usdc.mint(from, AMOUNT);

        // Sign with a different key (stranger's key), but pass `from` = payer
        uint256 wrongKey = 0xBEEF;
        uint256 validBefore = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signAuth(wrongKey, from, address(router), AMOUNT, 0, validBefore, nonce);

        vm.expectRevert("MockUSDC: invalid signature");
        router.settleX402(from, recipient, AMOUNT, 0, validBefore, nonce, v, r, s);
    }

    function test_settleX402_revertsOnReplay() public {
        bytes32 nonce = bytes32(uint256(8));
        (address from, uint256 validAfter, uint256 validBefore, uint8 v, bytes32 r, bytes32 s) =
            _setupX402(AMOUNT, nonce);

        // First settlement succeeds.
        router.settleX402(from, recipient, AMOUNT, validAfter, validBefore, nonce, v, r, s);

        // Mint more so balance isn't the issue.
        usdc.mint(from, AMOUNT);

        // Replay with same nonce - must revert.
        vm.expectRevert("MockUSDC: nonce already used");
        router.settleX402(from, recipient, AMOUNT, validAfter, validBefore, nonce, v, r, s);
    }

    // =========================================================================
    // settleX402 - conservation fuzz
    // =========================================================================

    function testFuzz_settleX402_feeInvariant(uint96 amount) public {
        amount = uint96(bound(amount, MIN, 50_000e6));

        bytes32 nonce = bytes32(uint256(uint160(address(this))) ^ uint256(amount));
        (address from, uint256 validAfter, uint256 validBefore, uint8 v, bytes32 r, bytes32 s) =
            _setupX402(amount, nonce);

        uint256 payerBefore = usdc.balanceOf(from);

        router.settleX402(from, recipient, amount, validAfter, validBefore, nonce, v, r, s);

        uint256 recipientGot = usdc.balanceOf(recipient);
        uint256 feeGot = usdc.balanceOf(feeRecipient);

        // Conservation: payer's debit == recipient + fee
        assertEq(payerBefore - usdc.balanceOf(from), recipientGot + feeGot, "conservation");
        assertEq(recipientGot + feeGot, amount, "no dust lost");
        // Router holds nothing
        assertEq(usdc.balanceOf(address(router)), 0, "router zero balance");
    }

    // =========================================================================
    // settleX402 - frame condition (settleX402 doesn't affect payDirect state)
    // =========================================================================

    function test_settleX402_frameCondition() public {
        // Do a payDirect first, then settleX402 - ensure payDirect balances are unaffected.
        vm.prank(payer);
        router.payDirect(recipient, AMOUNT, bytes32(0));
        uint256 recipientAfterDirect = usdc.balanceOf(recipient);
        // feeRecipient accrues fees from both paths - only check direct recipient is unaffected.

        // Now do an x402 settlement with a different payer.
        bytes32 nonce = bytes32(uint256(99));
        (address x402Payer, uint256 validAfter, uint256 validBefore, uint8 v, bytes32 r, bytes32 s) =
            _setupX402(AMOUNT, nonce);

        address x402Recipient = makeAddr("x402Recipient");
        router.settleX402(x402Payer, x402Recipient, AMOUNT, validAfter, validBefore, nonce, v, r, s);

        // payDirect payer's balance is unchanged by x402.
        // Fee recipient gets fees from both - but the direct recipient's balance should be unchanged.
        assertEq(usdc.balanceOf(recipient), recipientAfterDirect, "direct recipient unaffected");
    }

    // =========================================================================
    // Relayer authorization - authorize / revoke / isAuthorizedRelayer
    // =========================================================================

    address internal relayer = makeAddr("relayer");

    function _authorizeRelayer() internal {
        vm.prank(protocolAdmin);
        router.authorizeRelayer(relayer);
    }

    function test_authorizeRelayer_works() public {
        assertFalse(router.isAuthorizedRelayer(relayer));
        _authorizeRelayer();
        assertTrue(router.isAuthorizedRelayer(relayer));
    }

    function test_authorizeRelayer_revertsForStranger() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        router.authorizeRelayer(relayer);
    }

    function test_authorizeRelayer_revertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.ZeroAddress.selector));
        vm.prank(protocolAdmin);
        router.authorizeRelayer(address(0));
    }

    function test_revokeRelayer_works() public {
        _authorizeRelayer();
        assertTrue(router.isAuthorizedRelayer(relayer));

        vm.prank(protocolAdmin);
        router.revokeRelayer(relayer);
        assertFalse(router.isAuthorizedRelayer(relayer));
    }

    function test_revokeRelayer_revertsForStranger() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        router.revokeRelayer(relayer);
    }

    // =========================================================================
    // payDirectFor - happy path + conservation
    // =========================================================================

    function test_payDirectFor_happyPath() public {
        _authorizeRelayer();

        // Payer approves Router
        vm.prank(payer);
        usdc.approve(address(router), type(uint256).max);

        uint96 fee = uint96((uint256(AMOUNT) * 100) / 10_000); // 1%
        uint96 net = AMOUNT - fee;

        uint256 payerBefore = usdc.balanceOf(payer);

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.DirectPayment(payer, recipient, AMOUNT, fee, bytes32(0));

        vm.prank(relayer);
        router.payDirectFor(payer, recipient, AMOUNT, bytes32(0));

        // Conservation: payer debited, recipient + feeRecipient credited
        assertEq(payerBefore - usdc.balanceOf(payer), AMOUNT, "payer debited full amount");
        assertEq(usdc.balanceOf(recipient), net, "recipient got net");
        assertEq(usdc.balanceOf(feeRecipient), fee, "fee collected");
        // Relayer balance unchanged (relayer never held USDC in this test)
    }

    function test_payDirectFor_revertsForUnauthorizedRelayer() public {
        // Don't authorize - just call directly
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        router.payDirectFor(payer, recipient, AMOUNT, bytes32(0));
    }

    function test_payDirectFor_revertsOnSelfPayment() public {
        _authorizeRelayer();
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.SelfPayment.selector, payer));
        vm.prank(relayer);
        router.payDirectFor(payer, payer, AMOUNT, bytes32(0));
    }

    function test_payDirectFor_volumeRecordedForPayer() public {
        _authorizeRelayer();
        vm.prank(payer);
        usdc.approve(address(router), type(uint256).max);

        vm.prank(relayer);
        router.payDirectFor(payer, recipient, AMOUNT, bytes32(0));

        // Volume recorded for payer, not relayer
        assertEq(feeCalc.monthlyVolume(payer), AMOUNT, "volume recorded for payer");
        assertEq(feeCalc.monthlyVolume(relayer), 0, "no volume for relayer");
    }

    // =========================================================================
    // payDirectFor - conservation fuzz
    // =========================================================================

    function testFuzz_payDirectFor_feeInvariant(uint96 amount) public {
        amount = uint96(bound(amount, MIN, 50_000e6));

        _authorizeRelayer();
        usdc.mint(payer, amount);
        vm.prank(payer);
        usdc.approve(address(router), type(uint256).max);

        uint256 payerBefore = usdc.balanceOf(payer);

        vm.prank(relayer);
        router.payDirectFor(payer, recipient, amount, bytes32(0));

        uint256 recipientGot = usdc.balanceOf(recipient);
        uint256 feeGot = usdc.balanceOf(feeRecipient);

        // Conservation: payer's spend == recipient's receive + fee
        assertEq(payerBefore - usdc.balanceOf(payer), recipientGot + feeGot, "conservation");
        assertEq(recipientGot + feeGot, amount, "no dust lost");
    }

    // =========================================================================
    // payPerRequestFor - happy path
    // =========================================================================

    function test_payPerRequestFor_happyPath() public {
        _authorizeRelayer();
        vm.prank(payer);
        usdc.approve(address(router), type(uint256).max);

        uint96 fee = uint96((uint256(AMOUNT) * 100) / 10_000);
        uint96 net = AMOUNT - fee;

        vm.expectEmit(true, true, false, true);
        emit RemitEvents.PayPerRequest(payer, recipient, AMOUNT, fee, "https://api.example.com/v1/chat");

        vm.prank(relayer);
        router.payPerRequestFor(payer, recipient, AMOUNT, "https://api.example.com/v1/chat");

        assertEq(usdc.balanceOf(recipient), net, "recipient got net");
        assertEq(usdc.balanceOf(feeRecipient), fee, "fee collected");
    }

    function test_payPerRequestFor_revertsForUnauthorizedRelayer() public {
        vm.expectRevert(abi.encodeWithSelector(RemitErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        router.payPerRequestFor(payer, recipient, AMOUNT, "https://api.example.com/v1/chat");
    }
}
