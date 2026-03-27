// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRemitKeyRegistry} from "../interfaces/IRemitKeyRegistry.sol";
import {RemitTypes} from "./RemitTypes.sol";
import {RemitErrors} from "./RemitErrors.sol";

/// @title RemitKeyValidator
/// @notice Library for validating session key delegations in Remit payment contracts
/// @dev Call _validateAndRecord before processing any payment. If keyRegistry is address(0),
///      all calls pass through (master-key-only mode, backwards compatible).
library RemitKeyValidator {
    /// @notice Validate that `signer` is authorized to make a payment of `amount` of `paymentType`.
    ///         If `signer` is a session key, checks delegation validity, model restrictions, and limits.
    ///         If `signer` is a master key (no delegation), passes through unconditionally.
    ///         Records spending against the session key's daily limit after validation.
    /// @param keyRegistry The KeyRegistry contract. If address(0), skip all checks.
    /// @param signer The transaction initiator (msg.sender in the calling contract)
    /// @param amount USDC amount (6 decimals)
    /// @param paymentType The payment model being used
    /// @dev Reverts with DelegationExpired, DelegationLimitExceeded, or DelegationNotFound on failure.
    function _validateAndRecord(
        IRemitKeyRegistry keyRegistry,
        address signer,
        uint96 amount,
        RemitTypes.PaymentType paymentType
    ) internal {
        if (address(keyRegistry) == address(0)) return; // key management not deployed

        IRemitKeyRegistry.Delegation memory d = keyRegistry.getDelegation(signer);
        if (d.masterKey == address(0)) return; // not a session key - master key, no limits

        // Session key: must be valid (not revoked, not expired, not just grace-period)
        if (!keyRegistry.isValidDelegation(signer)) {
            revert RemitErrors.DelegationExpired(signer);
        }

        // Check model restriction and spending limits (view, doesn't modify state)
        if (!keyRegistry.checkSpendingLimit(signer, amount, uint8(paymentType))) {
            revert RemitErrors.DelegationLimitExceeded(signer, amount, d.spendingLimit);
        }

        // Record spending (modifies state - must be called by authorized contract)
        keyRegistry.recordSpend(signer, amount);
    }
}
