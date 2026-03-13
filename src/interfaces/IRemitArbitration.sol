// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRemitArbitration
/// @notice Third-party arbitration system for Remit protocol disputes.
/// @dev Non-fund-holding contract — manages arbitration logic only. Bond stakes held here (arbitrator bonds).
///      Escrow funds remain in RemitEscrow until renderDecision() triggers resolution.
interface IRemitArbitration {
    // =========================================================================
    // Enums
    // =========================================================================

    /// @notice Tier of arbitration routing based on dispute amount
    enum DisputeTier {
        Admin, // 0: <$100 — remit.md staff arbitrate directly
        Pool, // 1: $100–$1,000 — third-party pool, fallback to admin if pool empty
        Required // 2: >$1,000 — third-party required, 50/50 only as absolute last resort
    }

    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Arbitrator profile and reputation state
    struct Arbitrator {
        address wallet; // arbitrator's Ethereum address
        uint256 bondAmount; // USDC staked as collateral (6 decimals)
        string metadataUri; // IPFS URI or URL with credentials/profile
        uint256 decisionCount; // total decisions rendered
        uint256 totalTurnaroundSeconds; // cumulative seconds from assignment to decision
        uint256 reputationScore; // 0–10000 (basis points), higher = better
        uint64 removedAt; // unix timestamp of removal (0 = still active)
        bool active; // whether currently in the pool
    }

    /// @notice Arbitration case for a specific dispute
    struct ArbitrationCase {
        address escrowContract; // RemitEscrow holding the funds
        address payer; // payer party in the dispute
        address payee; // payee party in the dispute
        uint96 disputedAmount; // total USDC escrowed (determines tier)
        address[3] proposedArbitrators; // 3 candidates (address(0) = slot unused)
        int8 payerStrike; // -1 = not yet cast, 0–2 = index struck
        int8 payeeStrike; // -1 = not yet cast, 0–2 = index struck
        address assignedArbitrator; // final assigned arbitrator (address(0) until assigned)
        uint64 proposedAt; // timestamp when candidates were proposed
        uint64 assignedAt; // timestamp when arbitrator was assigned
        uint64 deadlineAt; // assignment + 48h — arbitrator must decide by this
        uint8 payerPercent; // percentage of escrow returned to payer (0–100)
        uint8 payeePercent; // percentage of escrow paid to payee (0–100)
        string reasoning; // arbitrator's reasoning for the decision
        bool decided; // true after renderDecision() is called
        DisputeTier tier; // tier determined at routing time
    }

    // =========================================================================
    // External Write Functions
    // =========================================================================

    /// @notice Register as an arbitrator by staking USDC bond.
    /// @param metadataUri IPFS URI or URL with arbitrator credentials
    /// @dev Caller must have approved at least MIN_ARBITRATOR_BOND USDC.
    ///      Emits ArbitratorRegistered.
    function registerArbitrator(string calldata metadataUri) external;

    /// @notice Leave the arbitrator pool. Bond enters cooldown before it can be claimed.
    /// @dev Only callable by active arbitrator. Must not have an open (non-decided) case.
    ///      Emits ArbitratorRemoved.
    function removeArbitrator() external;

    /// @notice Claim staked bond after cooldown period following removal.
    /// @dev Reverts if cooldown has not passed. Emits ArbitratorBondClaimed.
    function claimArbitratorBond() external;

    /// @notice Route a dispute to arbitration. Called by an authorized escrow contract.
    /// @param invoiceId The escrow's invoice ID
    /// @param payer Payer address in the dispute
    /// @param payee Payee address in the dispute
    /// @param disputedAmount Total USDC escrowed (determines tier)
    /// @dev Only callable by authorized escrow contracts. Emits ArbitratorsProposed or auto-assigns admin.
    function routeDispute(bytes32 invoiceId, address payer, address payee, uint96 disputedAmount) external;

    /// @notice Strike (eliminate) one of the proposed arbitrators.
    /// @param invoiceId The escrow's invoice ID
    /// @param index Index of arbitrator to strike (0, 1, or 2)
    /// @dev Only callable by payer or payee. Each party gets one strike.
    ///      Once both parties have struck, the remaining arbitrator is assigned.
    ///      If both strike the same, one of the remaining two is randomly selected.
    ///      Emits ArbitratorStruck and (when both done) ArbitratorAssigned.
    function strikeArbitrator(bytes32 invoiceId, uint8 index) external;

    /// @notice Render a binding decision on a dispute.
    /// @param invoiceId The escrow's invoice ID
    /// @param payerPercent Percentage of escrowed funds returned to payer (0–100)
    /// @param payeePercent Percentage of escrowed funds released to payee (0–100)
    /// @param reasoning Free-text reasoning for the decision (stored as event)
    /// @dev Only callable by the assigned arbitrator before the 48h deadline.
    ///      payerPercent + payeePercent must equal 100. Triggers fund distribution in RemitEscrow.
    ///      Emits ArbitrationDecisionRendered.
    function renderDecision(bytes32 invoiceId, uint8 payerPercent, uint8 payeePercent, string calldata reasoning)
        external;

    /// @notice Admin renders a decision for admin-tier disputes (<$100) or fallback.
    /// @param invoiceId The escrow's invoice ID
    /// @param payerPercent Percentage returned to payer
    /// @param payeePercent Percentage released to payee
    /// @param reasoning Free-text reasoning
    /// @dev Only callable by the protocol admin. Used when tier = Admin or when pool unavailable.
    function renderAdminDecision(bytes32 invoiceId, uint8 payerPercent, uint8 payeePercent, string calldata reasoning)
        external;

    /// @notice Authorize an escrow contract to call routeDispute().
    /// @param escrowContract Address of the escrow contract to authorize
    /// @dev Only callable by owner (protocol admin). Emits EscrowAuthorized.
    function authorizeEscrow(address escrowContract) external;

    /// @notice Revoke an escrow contract's authorization to call routeDispute().
    /// @param escrowContract Address of the escrow contract to deauthorize
    /// @dev Only callable by owner (protocol admin). Used when decommissioning old escrow versions.
    function deauthorizeEscrow(address escrowContract) external;

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @notice Get arbitrator profile by wallet address.
    function getArbitrator(address wallet) external view returns (Arbitrator memory);

    /// @notice Get arbitration case by invoice ID.
    function getCase(bytes32 invoiceId) external view returns (ArbitrationCase memory);

    /// @notice Get arbitrator's reputation score (0–10000 basis points).
    function getArbitratorReputation(address wallet) external view returns (uint256 score);

    /// @notice Get the current number of active arbitrators in the pool.
    function getPoolSize() external view returns (uint256);

    /// @notice Check whether an address is an authorized escrow contract.
    function isAuthorizedEscrow(address escrow) external view returns (bool);

    /// @notice Get the minimum USDC bond required to register as arbitrator.
    function MIN_ARBITRATOR_BOND() external view returns (uint256);

    /// @notice Get the 48-hour decision deadline duration in seconds.
    function ARBITRATION_DEADLINE() external view returns (uint64);

    /// @notice Get the amount threshold below which admin arbitrates (100 USDC in 6 decimals).
    function ADMIN_AMOUNT_THRESHOLD() external view returns (uint96);

    /// @notice Get the amount threshold above which pool arbitration is required (1000 USDC in 6 decimals).
    function POOL_REQUIRED_THRESHOLD() external view returns (uint96);
}
