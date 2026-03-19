// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRemitArbitration} from "./interfaces/IRemitArbitration.sol";
import {RemitErrors} from "./libraries/RemitErrors.sol";
import {RemitEvents} from "./libraries/RemitEvents.sol";

/// @dev Minimal interface used to call back into RemitEscrow after a decision.
interface IDisputeResolvable {
    function resolveDisputeArbitration(
        bytes32 invoiceId,
        uint8 payerPercent,
        uint8 payeePercent,
        address arbitrator,
        uint96 arbitratorFee
    ) external;
}

/// @title RemitArbitration
/// @notice Third-party arbitration pool for Remit protocol disputes.
/// @dev Non-fund-holding for escrow funds — arbitrator bonds are held here.
///      Arbitrators stake USDC collateral. Strike-based selection picks one from three candidates.
///      Tiered routing: <$100 = admin, $100–$1K = pool, >$1K = pool required.
///      CEI pattern strictly enforced. ReentrancyGuard on all fund-moving functions.
contract RemitArbitration is IRemitArbitration, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Minimum USDC bond to register as arbitrator ($100 = 100e6)
    uint256 public constant MIN_ARBITRATOR_BOND = 100_000_000;

    /// @notice 48-hour decision window after assignment
    uint64 public constant ARBITRATION_DEADLINE = 172_800;

    /// @notice Bond cooldown before a removed arbitrator can reclaim ($100 = 100e6)
    uint64 public constant ARBITRATOR_BOND_COOLDOWN = 604_800; // 7 days

    /// @notice Disputes below this amount go to admin tier ($100 = 100e6 USDC)
    uint96 public constant ADMIN_AMOUNT_THRESHOLD = 100_000_000;

    /// @notice Disputes above this amount require pool arbitration ($1,000 = 1000e6 USDC)
    uint96 public constant POOL_REQUIRED_THRESHOLD = 1_000_000_000;

    /// @notice Arbitrator fee as basis points (5% = 500)
    uint96 public constant ARBITRATION_FEE_BPS = 500;

    /// @notice New arbitrators start at 75% reputation
    uint256 public constant INITIAL_REPUTATION = 7_500;

    /// @notice Arbitrators below this score are removed from the pool (20%)
    uint256 public constant MIN_REPUTATION_SCORE = 2_000;

    /// @notice Ideal turnaround: 24h or less = full speed score
    uint256 internal constant IDEAL_TURNAROUND = 86_400;

    // =========================================================================
    // State
    // =========================================================================

    IERC20 public immutable usdc;

    /// @dev wallet → Arbitrator profile
    mapping(address => Arbitrator) private _arbitrators;

    /// @dev Active arbitrator addresses (for pool enumeration during selection)
    address[] private _pool;

    /// @dev invoiceId → ArbitrationCase
    mapping(bytes32 => ArbitrationCase) private _cases;

    /// @dev Authorized escrow contracts that can call routeDispute()
    mapping(address => bool) private _authorizedEscrows;

    /// @dev Round-robin counter for arbitrator selection. Eliminates block.prevrandao dependency.
    uint256 private _nextArbitratorIndex;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _usdc USDC token address
    /// @param initialOwner Protocol admin address (resolves admin-tier disputes)
    constructor(address _usdc, address initialOwner) Ownable(initialOwner) {
        if (_usdc == address(0)) revert RemitErrors.ZeroAddress();
        usdc = IERC20(_usdc);
    }

    // =========================================================================
    // Arbitrator Management
    // =========================================================================

    /// @inheritdoc IRemitArbitration
    /// @dev CEI: validate → record → transfer bond in
    function registerArbitrator(string calldata metadataUri) external override nonReentrant {
        address wallet = msg.sender;

        // --- Checks ---
        Arbitrator storage arb = _arbitrators[wallet];
        if (arb.wallet != address(0) && arb.active) revert RemitErrors.ArbitratorAlreadyRegistered(wallet);

        uint256 bond = MIN_ARBITRATOR_BOND;
        // If re-registering after removal, re-use existing (already-returned) bond requirement
        // (former arb must have claimed their old bond first — wallet is clean)
        if (arb.wallet != address(0) && !arb.active && arb.bondAmount > 0) {
            // Bond was not yet claimed — refuse re-registration until claimed
            revert RemitErrors.ArbitratorAlreadyRegistered(wallet);
        }

        // --- Effects ---
        _arbitrators[wallet] = Arbitrator({
            wallet: wallet,
            bondAmount: bond,
            metadataUri: metadataUri,
            decisionCount: 0,
            totalTurnaroundSeconds: 0,
            reputationScore: INITIAL_REPUTATION,
            removedAt: 0,
            active: true
        });
        _pool.push(wallet);

        // --- Interactions ---
        usdc.safeTransferFrom(wallet, address(this), bond);

        emit RemitEvents.ArbitratorRegistered(wallet, bond, metadataUri);
    }

    /// @inheritdoc IRemitArbitration
    function removeArbitrator() external override {
        address wallet = msg.sender;
        Arbitrator storage arb = _arbitrators[wallet];

        if (arb.wallet == address(0) || !arb.active) revert RemitErrors.ArbitratorNotFound(wallet);

        // --- Effects ---
        arb.active = false;
        arb.removedAt = uint64(block.timestamp);
        _removeFromPool(wallet);

        emit RemitEvents.ArbitratorRemoved(wallet, uint64(block.timestamp) + ARBITRATOR_BOND_COOLDOWN);
    }

    /// @inheritdoc IRemitArbitration
    /// @dev CEI: validate cooldown → clear bond → transfer out
    function claimArbitratorBond() external override nonReentrant {
        address wallet = msg.sender;
        Arbitrator storage arb = _arbitrators[wallet];

        if (arb.wallet == address(0)) revert RemitErrors.ArbitratorNotFound(wallet);
        if (arb.active) revert RemitErrors.ArbitratorAlreadyRegistered(wallet); // still active, can't claim

        uint64 releaseAt = arb.removedAt + ARBITRATOR_BOND_COOLDOWN;
        if (block.timestamp < releaseAt) revert RemitErrors.ArbitrationCooldownNotMet(releaseAt);

        uint256 bond = arb.bondAmount;
        if (bond == 0) revert RemitErrors.ZeroAmount();

        // --- Effects ---
        arb.bondAmount = 0;
        arb.removedAt = 0;

        // --- Interactions ---
        usdc.safeTransfer(wallet, bond);
    }

    // =========================================================================
    // Dispute Routing
    // =========================================================================

    /// @inheritdoc IRemitArbitration
    /// @dev Only callable by authorized escrow contracts. Routes dispute to correct tier.
    function routeDispute(bytes32 invoiceId, address payer, address payee, uint96 disputedAmount) external override {
        if (!_authorizedEscrows[msg.sender]) revert RemitErrors.NotArbitrationContract(msg.sender);
        if (_cases[invoiceId].escrowContract != address(0)) revert RemitErrors.ArbitrationCaseAlreadyExists(invoiceId);
        if (payer == address(0) || payee == address(0)) revert RemitErrors.ZeroAddress();

        DisputeTier tier = _determineTier(disputedAmount);

        // --- Effects ---
        ArbitrationCase storage c = _cases[invoiceId];
        c.escrowContract = msg.sender;
        c.payer = payer;
        c.payee = payee;
        c.disputedAmount = disputedAmount;
        c.payerStrike = -1;
        c.payeeStrike = -1;
        c.proposedAt = uint64(block.timestamp);
        c.tier = tier;

        if (tier == DisputeTier.Admin) {
            // Admin tier: owner is the assigned arbitrator directly
            c.assignedArbitrator = owner();
            c.assignedAt = uint64(block.timestamp);
            c.deadlineAt = uint64(block.timestamp) + ARBITRATION_DEADLINE;
            emit RemitEvents.ArbitratorAssigned(invoiceId, owner(), c.deadlineAt);
        } else {
            // Pool tier: propose 3 arbitrators (with fallback to admin if pool insufficient)
            _proposeArbitrators(invoiceId);
        }

        emit RemitEvents.DisputeEscalatedToArbitration(invoiceId, msg.sender, uint8(tier));
    }

    // =========================================================================
    // Strike Phase
    // =========================================================================

    /// @inheritdoc IRemitArbitration
    function strikeArbitrator(bytes32 invoiceId, uint8 index) external override {
        ArbitrationCase storage c = _cases[invoiceId];
        if (c.escrowContract == address(0)) revert RemitErrors.ArbitrationCaseNotFound(invoiceId);
        if (c.decided) revert RemitErrors.ArbitrationAlreadyDecided(invoiceId);
        if (c.assignedArbitrator != address(0)) revert RemitErrors.ArbitrationAlreadyDecided(invoiceId); // already assigned
        if (index > 2) revert RemitErrors.InvalidPercentageSum(index, 2); // reuse error, index must be 0-2
        if (c.proposedArbitrators[index] == address(0)) revert RemitErrors.ArbitratorNotFound(address(0));

        bool isPayer = (msg.sender == c.payer);
        bool isPayee = (msg.sender == c.payee);
        if (!isPayer && !isPayee) revert RemitErrors.Unauthorized(msg.sender);

        if (isPayer) {
            if (c.payerStrike != -1) revert RemitErrors.StrikeAlreadyCast(invoiceId);
            c.payerStrike = int8(int256(uint256(index)));
        } else {
            if (c.payeeStrike != -1) revert RemitErrors.StrikeAlreadyCast(invoiceId);
            c.payeeStrike = int8(int256(uint256(index)));
        }

        emit RemitEvents.ArbitratorStruck(invoiceId, msg.sender, index);

        // Both strikes cast — assign final arbitrator
        if (c.payerStrike != -1 && c.payeeStrike != -1) {
            _assignArbitrator(invoiceId);
        }
    }

    // =========================================================================
    // Decision Rendering
    // =========================================================================

    /// @inheritdoc IRemitArbitration
    /// @dev Only callable by the assigned arbitrator before the deadline.
    function renderDecision(bytes32 invoiceId, uint8 payerPercent, uint8 payeePercent, string calldata reasoning)
        external
        override
        nonReentrant
    {
        ArbitrationCase storage c = _cases[invoiceId];
        if (c.escrowContract == address(0)) revert RemitErrors.ArbitrationCaseNotFound(invoiceId);
        if (c.decided) revert RemitErrors.ArbitrationAlreadyDecided(invoiceId);
        if (c.assignedArbitrator == address(0)) revert RemitErrors.ArbitratorNotFound(msg.sender);
        if (msg.sender != c.assignedArbitrator) revert RemitErrors.ArbitratorNotAssigned(invoiceId, msg.sender);
        if (block.timestamp > c.deadlineAt) revert RemitErrors.ArbitrationDeadlinePassed(invoiceId);
        if (uint256(payerPercent) + uint256(payeePercent) != 100) {
            revert RemitErrors.InvalidPercentageSum(payerPercent, payeePercent);
        }

        _executeDecision(invoiceId, payerPercent, payeePercent, reasoning, msg.sender);
    }

    /// @inheritdoc IRemitArbitration
    /// @dev Only callable by protocol admin. Used for admin-tier disputes or fallback.
    function renderAdminDecision(bytes32 invoiceId, uint8 payerPercent, uint8 payeePercent, string calldata reasoning)
        external
        override
        nonReentrant
    {
        if (msg.sender != owner()) revert RemitErrors.Unauthorized(msg.sender);

        ArbitrationCase storage c = _cases[invoiceId];
        if (c.escrowContract == address(0)) revert RemitErrors.ArbitrationCaseNotFound(invoiceId);
        if (c.decided) revert RemitErrors.ArbitrationAlreadyDecided(invoiceId);
        if (uint256(payerPercent) + uint256(payeePercent) != 100) {
            revert RemitErrors.InvalidPercentageSum(payerPercent, payeePercent);
        }
        // Admin can only render decisions for admin-tier cases OR when assigned as fallback
        if (c.tier != DisputeTier.Admin && c.assignedArbitrator != owner()) {
            revert RemitErrors.Unauthorized(msg.sender);
        }

        _executeDecision(invoiceId, payerPercent, payeePercent, reasoning, owner());
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @inheritdoc IRemitArbitration
    function authorizeEscrow(address escrowContract) external override onlyOwner {
        if (escrowContract == address(0)) revert RemitErrors.ZeroAddress();
        _authorizedEscrows[escrowContract] = true;
        emit RemitEvents.EscrowContractAuthorized(escrowContract);
    }

    /// @inheritdoc IRemitArbitration
    /// @dev Used when decommissioning old escrow contract versions.
    function deauthorizeEscrow(address escrowContract) external override onlyOwner {
        if (escrowContract == address(0)) revert RemitErrors.ZeroAddress();
        _authorizedEscrows[escrowContract] = false;
        emit RemitEvents.EscrowContractDeauthorized(escrowContract);
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @inheritdoc IRemitArbitration
    function getArbitrator(address wallet) external view override returns (Arbitrator memory) {
        return _arbitrators[wallet];
    }

    /// @inheritdoc IRemitArbitration
    function getCase(bytes32 invoiceId) external view override returns (ArbitrationCase memory) {
        return _cases[invoiceId];
    }

    /// @inheritdoc IRemitArbitration
    function getArbitratorReputation(address wallet) external view override returns (uint256 score) {
        return _arbitrators[wallet].reputationScore;
    }

    /// @inheritdoc IRemitArbitration
    function getPoolSize() external view override returns (uint256) {
        return _pool.length;
    }

    /// @inheritdoc IRemitArbitration
    function isAuthorizedEscrow(address escrow) external view override returns (bool) {
        return _authorizedEscrows[escrow];
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @dev Determine the dispute tier based on the disputed amount.
    function _determineTier(uint96 amount) internal pure returns (DisputeTier) {
        if (amount < ADMIN_AMOUNT_THRESHOLD) return DisputeTier.Admin;
        if (amount < POOL_REQUIRED_THRESHOLD) return DisputeTier.Pool;
        return DisputeTier.Required;
    }

    /// @dev Propose 3 arbitrators from the active pool using round-robin selection.
    ///      Picks 3 consecutive pool indices starting at _nextArbitratorIndex (wrapping).
    ///      Falls back to admin if pool has < 3 members and tier allows.
    function _proposeArbitrators(bytes32 invoiceId) internal {
        ArbitrationCase storage c = _cases[invoiceId];
        uint256 poolLen = _pool.length;

        if (poolLen < 3) {
            if (c.tier == DisputeTier.Required) {
                // Required tier — cannot fall back. Escalate to admin as last resort.
                // In production: this triggers operator notification to recruit arbitrators.
                // For now: assign admin with a note that this is a last-resort.
                c.assignedArbitrator = owner();
                c.assignedAt = uint64(block.timestamp);
                c.deadlineAt = uint64(block.timestamp) + ARBITRATION_DEADLINE;
                emit RemitEvents.ArbitratorAssigned(invoiceId, owner(), c.deadlineAt);
                return;
            }
            // Pool tier — fall back to admin
            c.assignedArbitrator = owner();
            c.assignedAt = uint64(block.timestamp);
            c.deadlineAt = uint64(block.timestamp) + ARBITRATION_DEADLINE;
            emit RemitEvents.ArbitratorAssigned(invoiceId, owner(), c.deadlineAt);
            return;
        }

        // Round-robin selection: pick 3 consecutive indices starting at _nextArbitratorIndex.
        // Wraps via modulo. Ensures fair distribution without block-variable manipulation risk.
        uint256 start = _nextArbitratorIndex % poolLen;
        _nextArbitratorIndex += 3;

        c.proposedArbitrators[0] = _pool[start % poolLen];
        c.proposedArbitrators[1] = _pool[(start + 1) % poolLen];
        c.proposedArbitrators[2] = _pool[(start + 2) % poolLen];

        emit RemitEvents.ArbitratorsProposed(
            invoiceId, c.proposedArbitrators[0], c.proposedArbitrators[1], c.proposedArbitrators[2]
        );
    }

    /// @dev Assign the final arbitrator after both strikes are cast.
    ///      If both parties struck the same index: round-robin pick from remaining 2.
    function _assignArbitrator(bytes32 invoiceId) internal {
        ArbitrationCase storage c = _cases[invoiceId];

        int8 ps = c.payerStrike;
        int8 qs = c.payeeStrike;

        address assigned;

        if (ps == qs) {
            // Both struck the same arbitrator — round-robin pick from the other 2
            // Find the two remaining indices
            uint8[2] memory remaining;
            uint8 idx;
            for (uint8 i; i < 3; ++i) {
                if (int8(int256(uint256(i))) != ps) {
                    remaining[idx++] = i;
                }
            }
            // Round-robin tiebreak: alternate between the two remaining candidates.
            uint8 chosen = remaining[_nextArbitratorIndex % 2];
            _nextArbitratorIndex += 1;
            assigned = c.proposedArbitrators[chosen];
        } else {
            // Find the one not struck by either
            for (uint8 i; i < 3; ++i) {
                if (int8(int256(uint256(i))) != ps && int8(int256(uint256(i))) != qs) {
                    assigned = c.proposedArbitrators[i];
                    break;
                }
            }
        }

        c.assignedArbitrator = assigned;
        c.assignedAt = uint64(block.timestamp);
        c.deadlineAt = uint64(block.timestamp) + ARBITRATION_DEADLINE;

        emit RemitEvents.ArbitratorAssigned(invoiceId, assigned, c.deadlineAt);
    }

    /// @dev Execute a decision: update case state, update arbitrator reputation,
    ///      then call back to the escrow contract to distribute funds.
    function _executeDecision(
        bytes32 invoiceId,
        uint8 payerPercent,
        uint8 payeePercent,
        string calldata reasoning,
        address arbitrator
    ) internal {
        ArbitrationCase storage c = _cases[invoiceId];

        // --- Effects ---
        c.decided = true;
        c.payerPercent = payerPercent;
        c.payeePercent = payeePercent;

        // Update arbitrator reputation (only for pool/required tier real arbitrators, not admin)
        if (arbitrator != owner() || c.tier != DisputeTier.Admin) {
            _updateReputation(arbitrator, c.assignedAt);
        }

        // Calculate arbitrator fee: 5% of disputed amount
        uint96 arbitratorFee;
        if (arbitrator != owner()) {
            arbitratorFee = uint96((uint256(c.disputedAmount) * ARBITRATION_FEE_BPS) / 10_000);
        }
        // Admin renders decisions for free (no fee)

        address escrowAddr = c.escrowContract;
        c.reasoning = reasoning;

        emit RemitEvents.ArbitrationDecisionRendered(invoiceId, arbitrator, payerPercent, payeePercent);

        // --- Interactions ---
        // Call back to the escrow to distribute funds
        IDisputeResolvable(escrowAddr)
            .resolveDisputeArbitration(invoiceId, payerPercent, payeePercent, arbitrator, arbitratorFee);
    }

    /// @dev Update arbitrator reputation after a decision.
    ///      Speed score: 0–5000 based on turnaround vs 24h ideal.
    ///      Activity bonus: each decision contributes to sustained score.
    function _updateReputation(address arbitrator, uint64 assignedAt) internal {
        Arbitrator storage arb = _arbitrators[arbitrator];
        if (arb.wallet == address(0)) return; // admin or non-registered (skip)

        uint256 turnaround = block.timestamp > uint256(assignedAt) ? block.timestamp - uint256(assignedAt) : 0;
        arb.totalTurnaroundSeconds += turnaround;
        arb.decisionCount++;

        // Speed score: 5000 max, decays linearly from 24h to 48h, 0 at/beyond 48h
        bool decidedOnTime = turnaround <= IDEAL_TURNAROUND;
        bool decidedWithinDeadline = turnaround < ARBITRATION_DEADLINE;
        uint256 speedScore;
        if (decidedOnTime) {
            speedScore = 5_000;
        } else if (decidedWithinDeadline) {
            // Linear decay from 5000 to 0 between 24h and 48h
            uint256 excess = turnaround - IDEAL_TURNAROUND;
            uint256 window = ARBITRATION_DEADLINE - IDEAL_TURNAROUND;
            speedScore = 5_000 - (5_000 * excess) / window;
        } else {
            speedScore = 0;
        }

        // Activity score: 5000 base (all active arbitrators who decide get this)
        uint256 activityScore = 5_000;

        // Rolling average reputation: (prevScore * (n-1) + newScore) / n
        uint256 n = arb.decisionCount;
        uint256 newScore = speedScore + activityScore;
        uint256 prevScore = arb.reputationScore;
        arb.reputationScore = (prevScore * (n - 1) + newScore) / n;

        // Remove from pool if reputation drops below threshold
        if (arb.reputationScore < MIN_REPUTATION_SCORE && arb.active) {
            arb.active = false;
            arb.removedAt = uint64(block.timestamp);
            _removeFromPool(arbitrator);
            emit RemitEvents.ArbitratorRemoved(arbitrator, uint64(block.timestamp) + ARBITRATOR_BOND_COOLDOWN);
        }
    }

    /// @dev Remove an arbitrator from the pool array (swap-and-pop).
    function _removeFromPool(address wallet) internal {
        uint256 len = _pool.length;
        for (uint256 i; i < len; ++i) {
            if (_pool[i] == wallet) {
                _pool[i] = _pool[len - 1];
                _pool.pop();
                return;
            }
        }
    }
}
