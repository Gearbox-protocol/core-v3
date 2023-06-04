// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {RAY, SECONDS_PER_YEAR, PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

uint192 constant RAY_DIVIDED_BY_PERCENTAGE = uint192(RAY / PERCENTAGE_FACTOR);

/// @title Quota Library
library QuotasLogic {
    using SafeCast for uint256;

    /// @dev Computes the new interest index value, given the previous value, the interest rate, and time delta
    /// @dev Unlike base pool interest, the interest on quotas is not compounding, so an additive index is used
    /// @param cumulativeIndexLU Cumulative index that was last written to storage
    /// @param rate The current interest rate on the token's quota
    /// @param lastQuotaRateUpdate Timestamp of the last time quota rates were updated
    function cumulativeIndexSince(uint192 cumulativeIndexLU, uint16 rate, uint256 lastQuotaRateUpdate)
        internal
        view
        returns (uint192)
    {
        return uint192(
            uint256(cumulativeIndexLU)
                + (RAY_DIVIDED_BY_PERCENTAGE * (block.timestamp - lastQuotaRateUpdate) * rate) / SECONDS_PER_YEAR
        ); // U: [QL-1]
    }

    /// @dev Computes the accrued quota interest based on the additive index
    /// @param quoted The quota amount
    /// @param cumulativeIndexNow The current value of the index
    /// @param cumulativeIndexLU Value of the index on last update
    function calcAccruedQuotaInterest(uint96 quoted, uint192 cumulativeIndexNow, uint192 cumulativeIndexLU)
        internal
        pure
        returns (uint128)
    {
        // Downcasting to uint128 should be safe, since quoted is uint96, and cumulativeIndex / RAY cannot grow
        // beyond 2 ** 32 in any reasonable time
        return uint128(uint256(quoted) * (cumulativeIndexNow - cumulativeIndexLU) / RAY); // U: [QL-2]
    }

    /// @dev Computes the pool quota revenue change given the current rate and the
    ///      actual quota change
    /// @param rate Rate for current token
    /// @param change Real change in quota
    function calcQuotaRevenueChange(uint16 rate, int256 change) internal pure returns (int256) {
        return change * int256(uint256(rate)) / int16(PERCENTAGE_FACTOR);
    }

    /// @dev Computes the actual quota change with respect to total limit on quotas
    /// When the quota is increased, the new amount is checked against the global limit on quotas
    /// If the amount is larger than the existing capacity, then the quota is only increased
    /// by capacity. This is done instead of reverting to avoid unexpected reverts due to race conditions
    /// @param totalQuoted Sum of all quotas for a token
    /// @param limit Quota limit for a token
    /// @param quotaChange The requested quota increase
    /// @return realQuotaChange Amount the quota actually changed by after taking
    ///                         capacity into account
    function calcRealQuotaIncreaseChange(uint96 totalQuoted, uint96 limit, int96 quotaChange)
        internal
        pure
        returns (int96 realQuotaChange)
    {
        if (totalQuoted >= limit) {
            return 0;
        }

        unchecked {
            uint96 maxQuotaCapacity = limit - totalQuoted;

            // Since limit should be less than int96.max under correct configuration, downcasting maxQuotaCapacity should
            // be safe
            return uint96(quotaChange) > maxQuotaCapacity ? int96(maxQuotaCapacity) : quotaChange; // I:[CMQ-08,10]
        }
    }
}
