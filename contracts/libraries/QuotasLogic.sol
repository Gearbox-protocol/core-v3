// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {RAY, SECONDS_PER_YEAR, PERCENTAGE_FACTOR} from "../libraries/Constants.sol";

uint192 constant RAY_DIVIDED_BY_PERCENTAGE = uint192(RAY / PERCENTAGE_FACTOR);

/// @title Quotas logic library
library QuotasLogic {
    /// @dev Computes the new interest index value, given the previous value, the interest rate, and time delta
    /// @dev Unlike pool's base interest, interest on quotas is not compounding, so additive index is used
    function cumulativeIndexSince(uint192 cumulativeIndexLU, uint16 rate, uint256 lastQuotaRateUpdate)
        internal
        view
        returns (uint192)
    {
        // cast is safe since both summands are of the same order as `RAY` which is roughly `2**90`
        return uint192(
            uint256(cumulativeIndexLU)
                + RAY_DIVIDED_BY_PERCENTAGE * (block.timestamp - lastQuotaRateUpdate) * rate / SECONDS_PER_YEAR
        ); // U:[QL-1]
    }

    /// @dev Computes interest accrued on the quota since the last update
    function calcAccruedQuotaInterest(uint96 quoted, uint192 cumulativeIndexNow, uint192 cumulativeIndexLU)
        internal
        pure
        returns (uint128)
    {
        // cast is safe since `quoted` is `uint96` and index change is of the same order as `RAY`
        return uint128(uint256(quoted) * (cumulativeIndexNow - cumulativeIndexLU) / RAY); // U:[QL-2]
    }

    /// @dev Computes the pool quota revenue change given the current rate and the quota change
    function calcQuotaRevenueChange(uint16 rate, int256 change) internal pure returns (int256) {
        return change * int256(uint256(rate)) / int16(PERCENTAGE_FACTOR);
    }

    /// @dev Upper-bounds requested quota increase such that the resulting total quota doesn't exceed the limit
    function calcActualQuotaChange(uint96 totalQuoted, uint96 limit, int96 requestedChange)
        internal
        pure
        returns (int96 quotaChange)
    {
        if (totalQuoted >= limit) {
            return 0;
        }

        unchecked {
            uint96 maxQuotaCapacity = limit - totalQuoted;
            // The function is never called with `requestedChange < 0`, so casting it to `uint96` is safe
            // `limit` is at most `type(int96).max`, so casting `maxQuotaCapacity` to `int96` is safe
            return uint96(requestedChange) > maxQuotaCapacity ? int96(maxQuotaCapacity) : requestedChange;
        }
    }
}
