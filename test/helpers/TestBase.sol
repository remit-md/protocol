// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockUSDC} from "../../src/test/MockUSDC.sol";
import {MockFeeCalculator} from "./MockFeeCalculator.sol";
import {RemitFeeCalculator} from "../../src/RemitFeeCalculator.sol";
import {RemitRouter} from "../../src/RemitRouter.sol";
import {RemitEscrow} from "../../src/RemitEscrow.sol";
import {RemitTab} from "../../src/RemitTab.sol";
import {RemitStream} from "../../src/RemitStream.sol";
import {RemitBounty} from "../../src/RemitBounty.sol";
import {RemitDeposit} from "../../src/RemitDeposit.sol";
import {RemitTypes} from "../../src/libraries/RemitTypes.sol";

/// @title TestBase
/// @notice Shared test setup for all Remit contract tests.
/// @dev Provides two stacks:
///
///      MOCK STACK (unit tests):
///        `usdc`, `feeCalc` (MockFeeCalculator), `escrow`, `tabContract`,
///        `streamContract`, `bountyContract`, `depositContract`
///        — predictable 1% fee, no volume tracking.
///
///      REAL STACK (integration tests):
///        `realFeeCalc` (UUPS proxy), `router` (UUPS proxy), `realEscrow`,
///        `realTab`, `realStream`, `realBounty`, `realDeposit`
///        — real cliff-based fee tiers, all contracts authorized.
///
///      RemitEscrow.t.sol inherits this and uses the mock stack (backward-compat).
///      Integration.t.sol inherits this and uses the real stack.
contract TestBase is Test {
    // ── Mock stack (unit tests) ───────────────────────────────────────────────
    MockUSDC public usdc;
    MockFeeCalculator public feeCalc;
    RemitEscrow public escrow;
    RemitTab public tabContract;
    RemitStream public streamContract;
    RemitBounty public bountyContract;
    RemitDeposit public depositContract;

    // ── Real stack (integration tests) ───────────────────────────────────────
    RemitFeeCalculator public realFeeCalc;
    RemitRouter public router;
    RemitEscrow public realEscrow;
    RemitTab public realTab;
    RemitStream public realStream;
    RemitBounty public realBounty;
    RemitDeposit public realDeposit;

    // ── Actors ────────────────────────────────────────────────────────────────
    address public payer;
    address public payee;
    address public admin = makeAddr("admin");
    address public feeRecipient = makeAddr("feeRecipient");
    address public stranger = makeAddr("stranger");

    uint256 internal payerKey;
    uint256 internal payeeKey;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint96 constant AMOUNT = 100e6; // $100 USDC
    uint64 constant TIMEOUT_DELTA = 7 days;

    // =========================================================================
    // setUp
    // =========================================================================

    function setUp() public virtual {
        // Deterministic keys so EIP-712 signing works in escrow tests.
        payerKey = uint256(keccak256(abi.encodePacked("payer")));
        payeeKey = uint256(keccak256(abi.encodePacked("payee")));
        payer = vm.addr(payerKey);
        payee = vm.addr(payeeKey);

        // ── Token + mocks ─────────────────────────────────────────────────────
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();

        // ── Mock-stack fund-holding contracts ─────────────────────────────────
        escrow = new RemitEscrow(address(usdc), address(feeCalc), admin, feeRecipient, address(0), address(0));
        tabContract = new RemitTab(address(usdc), address(feeCalc), feeRecipient, admin, address(0));
        streamContract = new RemitStream(address(usdc), address(feeCalc), feeRecipient, address(0));
        bountyContract = new RemitBounty(address(usdc), address(feeCalc), feeRecipient, admin, address(0));
        depositContract = new RemitDeposit(address(usdc), address(0));

        // ── Real FeeCalculator (UUPS proxy) ───────────────────────────────────
        RemitFeeCalculator feeCalcImpl = new RemitFeeCalculator();
        bytes memory feeCalcInit = abi.encodeCall(feeCalcImpl.initialize, (admin));
        realFeeCalc = RemitFeeCalculator(address(new ERC1967Proxy(address(feeCalcImpl), feeCalcInit)));

        // ── Real fund-holding contracts ───────────────────────────────────────
        realEscrow = new RemitEscrow(address(usdc), address(realFeeCalc), admin, feeRecipient, address(0), address(0));
        realTab = new RemitTab(address(usdc), address(realFeeCalc), feeRecipient, admin, address(0));
        realStream = new RemitStream(address(usdc), address(realFeeCalc), feeRecipient, address(0));
        realBounty = new RemitBounty(address(usdc), address(realFeeCalc), feeRecipient, admin, address(0));
        realDeposit = new RemitDeposit(address(usdc), address(0));

        // Authorize real contracts in real fee calculator.
        vm.startPrank(admin);
        realFeeCalc.authorizeCaller(address(realEscrow));
        realFeeCalc.authorizeCaller(address(realTab));
        realFeeCalc.authorizeCaller(address(realStream));
        realFeeCalc.authorizeCaller(address(realBounty));
        vm.stopPrank();

        // ── Router (UUPS proxy) ───────────────────────────────────────────────
        RemitRouter routerImpl = new RemitRouter();
        bytes memory routerInit = abi.encodeCall(
            routerImpl.initialize,
            (RemitRouter.RouterConfig({
                    owner: admin,
                    usdc: address(usdc),
                    feeCalculator: address(realFeeCalc),
                    protocolAdmin: admin,
                    feeRecipient: feeRecipient
                }))
        );
        router = RemitRouter(address(new ERC1967Proxy(address(routerImpl), routerInit)));

        vm.startPrank(admin);
        router.setEscrow(address(realEscrow));
        router.setTab(address(realTab));
        router.setStream(address(realStream));
        router.setBounty(address(realBounty));
        router.setDeposit(address(realDeposit));
        realFeeCalc.authorizeCaller(address(router));
        vm.stopPrank();

        // ── Fund test accounts ────────────────────────────────────────────────
        _fundAndApprove(payer, 10_000e6);
        _fundAndApprove(payee, 10_000e6);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Mint USDC and approve all contracts for `user`.
    function _fundAndApprove(address user, uint96 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        // Mock stack
        usdc.approve(address(escrow), type(uint256).max);
        usdc.approve(address(tabContract), type(uint256).max);
        usdc.approve(address(streamContract), type(uint256).max);
        usdc.approve(address(bountyContract), type(uint256).max);
        usdc.approve(address(depositContract), type(uint256).max);
        // Real stack
        usdc.approve(address(realEscrow), type(uint256).max);
        usdc.approve(address(realTab), type(uint256).max);
        usdc.approve(address(realStream), type(uint256).max);
        usdc.approve(address(realBounty), type(uint256).max);
        usdc.approve(address(realDeposit), type(uint256).max);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Create a basic escrow (mock stack).
    function _createEscrow(bytes32 invoiceId) internal {
        vm.prank(payer);
        escrow.createEscrow(
            invoiceId,
            payee,
            AMOUNT,
            uint64(block.timestamp + TIMEOUT_DELTA),
            new RemitTypes.Milestone[](0),
            new RemitTypes.Split[](0)
        );
    }

    /// @dev Create and activate escrow (mock stack).
    function _createAndActivate(bytes32 invoiceId) internal {
        _createEscrow(invoiceId);
        vm.prank(payee);
        escrow.claimStart(invoiceId);
    }

    /// @dev Create an escrow with milestones (mock stack).
    function _createEscrowWithMilestones(bytes32 invoiceId, uint96[] memory amounts) internal {
        RemitTypes.Milestone[] memory milestones = new RemitTypes.Milestone[](amounts.length);
        for (uint256 i; i < amounts.length; ++i) {
            milestones[i] = RemitTypes.Milestone({
                amount: amounts[i],
                timeout: uint64(block.timestamp + TIMEOUT_DELTA),
                status: RemitTypes.MilestoneStatus.Pending,
                evidenceHash: bytes32(0)
            });
        }

        uint96 total;
        for (uint256 i; i < amounts.length; ++i) {
            total += amounts[i];
        }

        usdc.mint(payer, total);
        vm.prank(payer);
        escrow.createEscrow(
            invoiceId, payee, total, uint64(block.timestamp + TIMEOUT_DELTA), milestones, new RemitTypes.Split[](0)
        );
    }

    /// @dev Sign a mutual cancel digest (mock stack escrow).
    function _signMutualCancel(bytes32 invoiceId, uint256 signerKey) internal view returns (bytes memory) {
        bytes32 domainSep = escrow.domainSeparator();
        bytes32 structHash = keccak256(abi.encode(escrow.MUTUAL_CANCEL_TYPEHASH(), invoiceId, payer, payee));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
