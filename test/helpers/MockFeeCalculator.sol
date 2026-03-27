// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRemitFeeCalculator} from "../../src/interfaces/IRemitFeeCalculator.sol";
import {RemitTypes} from "../../src/libraries/RemitTypes.sol";

/// @title MockFeeCalculator
/// @notice Simple fee calculator for testing - always returns 1% fee
contract MockFeeCalculator is IRemitFeeCalculator {
    mapping(address => uint256) public monthlyVolume;

    /// @inheritdoc IRemitFeeCalculator
    function calculateFee(
        address,
        /*wallet*/
        uint96 amount
    )
        external
        pure
        returns (uint96 fee)
    {
        return uint96((uint256(amount) * RemitTypes.FEE_RATE_BPS) / 10_000);
    }

    /// @inheritdoc IRemitFeeCalculator
    function getMonthlyVolume(address wallet) external view returns (uint256 volume) {
        return monthlyVolume[wallet];
    }

    /// @inheritdoc IRemitFeeCalculator
    function recordTransaction(address wallet, uint96 amount) external {
        monthlyVolume[wallet] += amount;
    }

    /// @inheritdoc IRemitFeeCalculator
    function getFeeRate(address) external pure returns (uint96 rateBps) {
        return RemitTypes.FEE_RATE_BPS;
    }
}
