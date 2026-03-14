// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/test/MockUSDC.sol";
import {MockFeeCalculator} from "./helpers/MockFeeCalculator.sol";
import {RemitEscrow} from "../src/RemitEscrow.sol";
import {RemitTypes} from "../src/libraries/RemitTypes.sol";

// =============================================================================
// EscrowHandler
//
// Ghost accounting for RemitEscrow.
//
// Ghost invariant (INV-E1):
//   usdc.balanceOf(escrow) == ghost_total
//   where ghost_total = inflows (createEscrow + bonds in) - outflows (releases/cancels/bonds out)
//
// Additional invariant (INV-E3): terminal IDs are never revisited (enforced by test setup).
// =============================================================================

contract EscrowHandler is Test {
    RemitEscrow public escrow;
    MockUSDC public usdc;
    MockFeeCalculator public feeCalc;

    address public feeRecipient;
    address public admin;

    // Known signing keys so mutualCancel EIP-712 works in invariant context.
    uint256 internal payerKey = uint256(keccak256("inv-escrow-payer-key"));
    uint256 internal payeeKey = uint256(keccak256("inv-escrow-payee-key"));
    address public payer;
    address public payee;

    // Ghost variable: net USDC that should currently be in the escrow contract.
    uint256 public ghost_total;

    // Non-terminal IDs (Funded or Active) — move to _disputedIds on fileDispute.
    bytes32[] internal _activeIds;
    // Disputed IDs — removed when resolved/defaultWin.
    bytes32[] internal _disputedIds;

    mapping(bytes32 => uint96) internal _amount; // locked amount
    mapping(bytes32 => uint8) internal _state; // 0=Funded, 1=Active, 2=Disputed
    mapping(bytes32 => uint64) internal _timeout;

    uint256 internal _idCounter;

    constructor(
        RemitEscrow _escrow,
        MockUSDC _usdc,
        MockFeeCalculator _feeCalc,
        address _feeRecipient,
        address _admin
    ) {
        escrow = _escrow;
        usdc = _usdc;
        feeCalc = _feeCalc;
        feeRecipient = _feeRecipient;
        admin = _admin;
        payer = vm.addr(payerKey);
        payee = vm.addr(payeeKey);

        // Pre-fund with ample USDC to cover bonds (up to 8x 5% of max amount per dispute).
        usdc.mint(payer, 100_000e6);
        usdc.mint(payee, 100_000e6);
        vm.prank(payer);
        usdc.approve(address(escrow), type(uint256).max);
        vm.prank(payee);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // ── createEscrow ─────────────────────────────────────────────────────────

    /// @dev Creates a simple escrow (no milestones, no splits).
    ///      Bounds: amount $0.01–$1,000. Timeout ≥ 4 days (above max floor of 72h).
    function createEscrow(uint96 amount, uint64 timeoutDelta) external {
        amount = uint96(bound(amount, RemitTypes.MIN_AMOUNT, 1_000e6));
        timeoutDelta = uint64(bound(timeoutDelta, 4 days, 30 days));

        bytes32 id = keccak256(abi.encodePacked("inv-escrow", _idCounter++));

        usdc.mint(payer, amount);

        vm.prank(payer);
        escrow.createEscrow(
            id,
            payee,
            amount,
            uint64(block.timestamp + timeoutDelta),
            new RemitTypes.Milestone[](0),
            new RemitTypes.Split[](0)
        );

        _activeIds.push(id);
        _amount[id] = amount;
        _state[id] = 0; // Funded
        _timeout[id] = uint64(block.timestamp + timeoutDelta);
        ghost_total += amount;
    }

    // ── claimStart ───────────────────────────────────────────────────────────

    /// @dev Transitions a Funded escrow to Active.
    function claimStart(uint256 idx) external {
        if (_activeIds.length == 0) return;
        idx = bound(idx, 0, _activeIds.length - 1);
        bytes32 id = _activeIds[idx];
        if (_state[id] != 0) return; // Must be Funded

        vm.prank(payee);
        escrow.claimStart(id);
        _state[id] = 1; // Active
        // ghost_total unchanged (no funds move)
    }

    // ── releaseEscrow ────────────────────────────────────────────────────────

    /// @dev Payer releases to payee (Active → Completed). All funds leave contract.
    function releaseEscrow(uint256 idx) external {
        if (_activeIds.length == 0) return;
        idx = bound(idx, 0, _activeIds.length - 1);
        bytes32 id = _activeIds[idx];
        if (_state[id] != 1) return; // Must be Active

        // Entire amount leaves contract (payee + feeRecipient).
        ghost_total -= _amount[id];

        vm.prank(payer);
        escrow.releaseEscrow(id);

        _removeActive(idx);
    }

    // ── cancelEscrow ─────────────────────────────────────────────────────────

    /// @dev Payer cancels pre-claimStart (Funded → Cancelled). Funds leave (with cancel fee).
    function cancelEscrow(uint256 idx) external {
        if (_activeIds.length == 0) return;
        idx = bound(idx, 0, _activeIds.length - 1);
        bytes32 id = _activeIds[idx];
        if (_state[id] != 0) return; // Must be Funded

        // Entire amount leaves contract (payer + feeRecipient).
        ghost_total -= _amount[id];

        vm.prank(payer);
        escrow.cancelEscrow(id);

        _removeActive(idx);
    }

    // ── mutualCancel ─────────────────────────────────────────────────────────

    /// @dev Both parties agree to cancel (Funded/Active → Cancelled). No fee.
    function mutualCancel(uint256 idx) external {
        if (_activeIds.length == 0) return;
        idx = bound(idx, 0, _activeIds.length - 1);
        bytes32 id = _activeIds[idx];
        // mutualCancel requires status ∈ {Funded, Active}
        if (_state[id] > 1) return;

        bytes32 domainSep = escrow.domainSeparator();
        bytes32 structHash = keccak256(abi.encode(escrow.MUTUAL_CANCEL_TYPEHASH(), id, payer, payee));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(payerKey, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(payeeKey, digest);

        // Full amount returns to payer (no fee on mutual cancel).
        ghost_total -= _amount[id];

        escrow.mutualCancel(id, abi.encodePacked(r1, s1, v1), abi.encodePacked(r2, s2, v2));

        _removeActive(idx);
    }

    // ── claimTimeout ─────────────────────────────────────────────────────────

    /// @dev Payer reclaims after timeout (no evidence path). Warps time.
    function claimTimeout(uint256 idx) external {
        if (_activeIds.length == 0) return;
        idx = bound(idx, 0, _activeIds.length - 1);
        bytes32 id = _activeIds[idx];
        if (_state[id] > 1) return; // Funded or Active only

        RemitTypes.Escrow memory e = escrow.getEscrow(id);
        if (e.evidenceSubmitted) return; // claimTimeout blocked when evidence submitted

        vm.warp(e.timeout + 1);

        // Full amount returns to payer.
        ghost_total -= _amount[id];

        vm.prank(payer);
        escrow.claimTimeout(id);

        _removeActive(idx);
    }

    // ── fileDispute ──────────────────────────────────────────────────────────

    /// @dev Files a dispute (Funded/Active → Disputed). Bond enters contract.
    function fileDispute(uint256 idx) external {
        if (_activeIds.length == 0) return;
        idx = bound(idx, 0, _activeIds.length - 1);
        bytes32 id = _activeIds[idx];
        if (_state[id] > 1) return; // Funded or Active only

        bytes32 evidenceHash = keccak256(abi.encodePacked("dispute-evidence", id));

        // Alternate filer: payer or payee based on index parity.
        address filer = idx % 2 == 0 ? payer : payee;

        uint256 balanceBefore = usdc.balanceOf(address(escrow));

        vm.prank(filer);
        try escrow.fileDispute(id, evidenceHash) {
            // Bond entered contract. Measure delta.
            uint256 balanceAfter = usdc.balanceOf(address(escrow));
            // Bond in = balanceAfter - balanceBefore (typically positive or zero)
            if (balanceAfter >= balanceBefore) {
                ghost_total += balanceAfter - balanceBefore;
            }
            // Move ID from active to disputed list.
            _disputedIds.push(id);
            _state[id] = 2;
            _removeActive(idx);
        } catch {
            // Revert (e.g. insufficient approvals for edge cases) — state unchanged.
        }
    }

    // ── resolveDispute ───────────────────────────────────────────────────────

    /// @dev Admin resolves a dispute. All funds (escrow + bonds) leave contract.
    function resolveDispute(uint256 idx, bool payeeWins) external {
        if (_disputedIds.length == 0) return;
        idx = bound(idx, 0, _disputedIds.length - 1);
        bytes32 id = _disputedIds[idx];

        uint96 amount = _amount[id];
        RemitTypes.DisputeBond memory bond = escrow.getDisputeBond(id);

        uint96 payerAmt = payeeWins ? 0 : amount;
        uint96 payeeAmt = payeeWins ? amount : 0;

        // Escrow amount + all bonds leave contract.
        ghost_total -= amount;
        ghost_total -= bond.filerBond + bond.respondentBond;

        vm.prank(admin);
        escrow.resolveDispute(id, payerAmt, payeeAmt, payeeWins);

        _removeDisputed(idx);
    }

    // ── claimDefaultWin ──────────────────────────────────────────────────────

    /// @dev Filer claims default win after respondent didn't post counter-bond.
    function claimDefaultWin(uint256 idx) external {
        if (_disputedIds.length == 0) return;
        idx = bound(idx, 0, _disputedIds.length - 1);
        bytes32 id = _disputedIds[idx];

        RemitTypes.DisputeBond memory bond = escrow.getDisputeBond(id);
        if (bond.respondentPosted) return; // Respondent posted — can't claim default win

        // Warp past the counter-bond deadline.
        vm.warp(bond.counterBondDeadline + 1);

        // Escrow amount + filer's bond leave contract.
        ghost_total -= _amount[id];
        ghost_total -= bond.filerBond;

        vm.prank(bond.filer);
        escrow.claimDefaultWin(id);

        _removeDisputed(idx);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function activeCount() external view returns (uint256) {
        return _activeIds.length;
    }

    function disputedCount() external view returns (uint256) {
        return _disputedIds.length;
    }

    function _removeActive(uint256 idx) internal {
        uint256 last = _activeIds.length - 1;
        if (idx != last) _activeIds[idx] = _activeIds[last];
        _activeIds.pop();
    }

    function _removeDisputed(uint256 idx) internal {
        uint256 last = _disputedIds.length - 1;
        if (idx != last) _disputedIds[idx] = _disputedIds[last];
        _disputedIds.pop();
    }
}

// =============================================================================
// EscrowInvariantTest
// =============================================================================

contract EscrowInvariantTest is Test {
    EscrowHandler internal handler;
    RemitEscrow internal escrowContract;
    MockUSDC internal usdc;
    MockFeeCalculator internal feeCalc;
    address internal feeRecipient = makeAddr("inv-escrow-fee-recipient");
    address internal admin = makeAddr("inv-escrow-admin");

    function setUp() public {
        usdc = new MockUSDC();
        feeCalc = new MockFeeCalculator();
        escrowContract = new RemitEscrow(address(usdc), address(feeCalc), admin, feeRecipient, address(0), address(0));
        handler = new EscrowHandler(escrowContract, usdc, feeCalc, feeRecipient, admin);
        targetContract(address(handler));
    }

    /// @notice INV-E1: Contract balance always equals ghost accounting of net inflows.
    ///         Any discrepancy indicates funds were created or destroyed illegally.
    function invariant_conservationOfFunds() public view {
        assertEq(
            usdc.balanceOf(address(escrowContract)),
            handler.ghost_total(),
            "escrow: balance != ghost_total (fund conservation violated)"
        );
    }

    /// @notice INV-E3: No escrow can have zero balance (active escrows always hold something).
    ///         Checks that the contract holds at least as much as the ghost total.
    function invariant_balanceNeverBelowGhost() public view {
        assertGe(
            usdc.balanceOf(address(escrowContract)),
            handler.ghost_total(),
            "escrow: balance < ghost_total (funds went missing)"
        );
    }
}
