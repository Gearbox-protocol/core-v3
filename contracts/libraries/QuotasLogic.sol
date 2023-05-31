// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {TokenQuotaParams, AccountQuota} from "../interfaces/IPoolQuotaKeeperV3.sol";
import {CreditLogic} from "./CreditLogic.sol";

import {RAY, SECONDS_PER_YEAR, PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

import "../interfaces/IExceptions.sol";
import "forge-std/console.sol";

uint192 constant RAY_DIVIDED_BY_PERCENTAGE = uint192(RAY / PERCENTAGE_FACTOR);

/// @title Quota Library
library QuotasLogic {
    using SafeCast for uint256;

    /// @dev Only allows quoted tokens (with initialized data) to be passed to a function
    modifier initializedQuotasOnly(TokenQuotaParams storage tokenQuotaParams) {
        if (!isInitialised(tokenQuotaParams)) {
            revert TokenIsNotQuotedException(); // F:[PQK-13]
        }
        _;
    }

    /// @dev Returns whether the quoted token data is initialized
    /// @dev Since for initialized quoted token the interest index starts at RAY,
    ///      it is sufficient to check that it is not equal to 0
    function isInitialised(TokenQuotaParams storage tokenQuotaParams) internal view returns (bool) {
        return tokenQuotaParams.cumulativeIndexLU_RAY != 0;
    }

    /// @dev Initializes data for a new quoted token
    function initialise(TokenQuotaParams storage tokenQuotaParams) internal {
        tokenQuotaParams.cumulativeIndexLU_RAY = uint192(RAY); // F:[PQK-5]
    }

    /// @dev Computes the current quota interest index for a token
    /// @param tq Quota parameters for a token
    /// @param lastQuotaRateUpdate Timestamp of the last time quota rates were updated
    function cumulativeIndexSince(TokenQuotaParams storage tq, uint256 lastQuotaRateUpdate)
        internal
        view
        returns (uint192)
    {
        return calcAdditiveCumulativeIndex(tq, tq.rate, (block.timestamp - lastQuotaRateUpdate));
    }

    /// @dev Computes the new interest index value, given the previous value, the interest rate, and time delta
    /// @dev Unlike base pool interest, the interest on quotas is not compounding, so an additive index is used
    /// @param tokenQuotaParams Quota parameters for a token
    /// @param rate The current interest rate on the token's quota
    /// @param deltaTimestamp Time period that interest was accruing for
    function calcAdditiveCumulativeIndex(TokenQuotaParams storage tokenQuotaParams, uint16 rate, uint256 deltaTimestamp)
        internal
        view
        returns (uint192)
    {
        /// The interest rate is always stored in PERCENTAGE_FACTOR format as APY, so the increase needs to be divided by 1 year
        return uint192(
            uint256(tokenQuotaParams.cumulativeIndexLU_RAY)
                + (RAY_DIVIDED_BY_PERCENTAGE * (deltaTimestamp) * rate) / SECONDS_PER_YEAR
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
        // downcast to uint128 is safe, because quoted is uint96 and cumulativeIndex / RAY could no be bigger > 2**32
        return uint128(uint256(quoted) * (cumulativeIndexNow - cumulativeIndexLU) / RAY); // U: [QL-2]
    }

    /// @dev Calculates interest accrued on quota since last update
    /// @param tokenQuotaParams Quota parameters for a token
    /// @param accountQuota Quota data for a Credit Account to compute for
    /// @param lastQuotaRateUpdate Timestamp of the last time quota rates were updated
    /// @return caQuotaInterestChange Quota interest accrued since last update
    function calcOutstandingQuotaInterest(
        TokenQuotaParams storage tokenQuotaParams,
        AccountQuota storage accountQuota,
        uint256 lastQuotaRateUpdate
    ) internal view returns (uint128 caQuotaInterestChange, uint96 quoted, uint192 cumulativeIndexNow) {
        quoted = accountQuota.quota;

        cumulativeIndexNow = cumulativeIndexSince(tokenQuotaParams, lastQuotaRateUpdate);

        if (quoted > 1) {
            caQuotaInterestChange = calcAccruedQuotaInterest(quoted, cumulativeIndexNow, accountQuota.cumulativeIndexLU); // U: [QL-4]
        }
    }

    function calcQuotaInterestChange(TokenQuotaParams storage tokenQuotaParams, int96 change)
        internal
        view
        returns (int256)
    {
        return int256(change) * int256(uint256(tokenQuotaParams.rate)) / int16(PERCENTAGE_FACTOR);
    }

    /// @return tradingFees Trading fees computed during increasing quota
    function calcQuotaTradingFees(TokenQuotaParams storage tokenQuotaParams, int96 change)
        internal
        view
        returns (uint128 tradingFees)
    {
        // For some tokens, a one-time quota increase fee may be charged. This is a proxy for
        // trading fees for tokens with high volume but short position duration, in which
        // case trading fees are a more effective pricing policy than charging interest over time
        return uint128(uint96(change)) * tokenQuotaParams.quotaIncreaseFee / PERCENTAGE_FACTOR; // U: [QL-3]
    }

    /// @dev Changes the quota on a token for an account, and recomputes adjacent parameters
    /// When the quota is increased, the new amount is checked against the global limit on quotas
    /// If the amount is larger than the existing capacity, then the quota is only increased
    /// by capacity. This is done instead of reverting to avoid unexpected reverts due to race conditions
    /// @param tokenQuotaParams Quota parameters for a token
    /// @param quotaChange The amount to change quota for: negative to decrease, positive to increase

    /// @return realQuotaChange Amount the quota actually changed by after taking
    ///                         capacity into account
    function calcIncreaseQuotaChange(TokenQuotaParams storage tokenQuotaParams, int96 quotaChange)
        internal
        view
        initializedQuotasOnly(tokenQuotaParams) // U: [QL-9]
        returns (int96 realQuotaChange)
    {
        uint96 totalQuoted = tokenQuotaParams.totalQuoted;
        uint96 limit = tokenQuotaParams.limit;

        if (totalQuoted >= limit) {
            return 0; // U: [QL-3]
        }

        unchecked {
            uint96 maxQuotaCapacity = limit - totalQuoted;

            // Downcasting maxQuotaCapacity to int96 is safe. because maxQuotaCapacity < int96 quotaChange
            realQuotaChange = uint96(quotaChange) > maxQuotaCapacity ? int96(maxQuotaCapacity) : quotaChange; // I:[CMQ-08,10] U: [QL-3]
        }
    }
}
