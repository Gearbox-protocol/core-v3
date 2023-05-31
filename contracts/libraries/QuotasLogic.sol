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
    ) internal view returns (uint128 caQuotaInterestChange) {
        uint96 quoted = accountQuota.quota;
        if (quoted > 1) {
            return calcAccruedQuotaInterest(
                quoted, cumulativeIndexSince(tokenQuotaParams, lastQuotaRateUpdate), accountQuota.cumulativeIndexLU
            );
        }
    }

    /// @dev Changes the quota on a token for an account, and recomputes adjacent parameters
    /// @param tokenQuotaParams Quota parameters for a token
    /// @param accountQuota Quota data for a Credit Account to compute for
    /// @param lastQuotaRateUpdate Timestamp of the last time quota rates were updated
    /// @param quotaChange The amount to change quota for: negative to decrease, positive to increase
    /// @return caQuotaInterestChange Outstanding quota interest before the update. It is expected that this
    ///                               value is cached somewhere else (e.g., in Credit Manager), otherwise it
    ///                               will be lost.
    /// @return tradingFees Trading fees computed during increasing quota
    /// @return quotaRevenueChange Amount to update quota revenue by.
    /// @return realQuotaChange Amount the quota actually changed by after taking
    ///                         capacity into account
    /// @return enableToken Whether to enable the quoted token.
    /// @return disableToken Whether to disable the quoted token
    function changeQuota(
        TokenQuotaParams storage tokenQuotaParams,
        AccountQuota storage accountQuota,
        uint256 lastQuotaRateUpdate,
        int96 quotaChange
    )
        internal
        initializedQuotasOnly(tokenQuotaParams) // U: [QL-9]
        returns (
            uint128 caQuotaInterestChange,
            uint128 tradingFees,
            int256 quotaRevenueChange,
            int96 realQuotaChange,
            bool enableToken,
            bool disableToken
        )
    {
        /// Since interest is computed dynamically as a multiplier of current quota amount,
        /// the outstanding interest has to be saved beforehand so that interest doesn't change
        /// with quota amount

        caQuotaInterestChange = accrueAccountQuotaInterest({
            tokenQuotaParams: tokenQuotaParams,
            accountQuota: accountQuota,
            lastQuotaRateUpdate: lastQuotaRateUpdate
        });

        uint96 change;
        if (quotaChange > 0) {
            //
            // INCREASE QUOTA
            //

            // When the quota is increased, the new amount is checked against the global limit on quotas
            // If the amount is larger than the existing capacity, then the quota is only increased
            // by capacity. This is done instead of reverting to avoid unexpected reverts due to race conditions

            {
                uint96 totalQuoted = tokenQuotaParams.totalQuoted;
                uint96 limit = tokenQuotaParams.limit;

                if (totalQuoted >= limit) {
                    return (caQuotaInterestChange, 0, 0, 0, false, false); // U: [QL-3]
                }
                unchecked {
                    uint96 maxQuotaCapacity = limit - totalQuoted;

                    change = uint96(quotaChange);
                    change = change > maxQuotaCapacity ? maxQuotaCapacity : change; // I:[CMQ-08,10] U: [QL-3]
                    realQuotaChange = int96(change); // U: [QL-3]
                }
            }

            // Quoted tokens are only enabled in the CM when their quotas are changed
            // from zero to non-zero. This is done to correctly
            // update quotas on closing the account - if a token ends up disabled while having a non-zero quota,
            // the CM will fail to zero it on closing an account, which will break quota interest computations.
            // This value is returned in order for Credit Manager to update enabled tokens locally.
            if (accountQuota.quota <= 1) {
                enableToken = true; // U: [QL-3]
            }

            accountQuota.quota += change; // U: [QL-3]
            tokenQuotaParams.totalQuoted += change; // U: [QL-3]

            // For some tokens, a one-time quota increase fee may be charged. This is a proxy for
            // trading fees for tokens with high volume but short position duration, in which
            // case trading fees are a more effective pricing policy than charging interest over time
            tradingFees = uint128(change) * tokenQuotaParams.quotaIncreaseFee / PERCENTAGE_FACTOR; // U: [QL-3]
            caQuotaInterestChange += tradingFees;

            // Quota revenue is a global sum of all quota interest received from all tokens and accounts
            // per year. It is used by the pool to effectively compute expected quota revenue with just one value
            quotaRevenueChange = (uint256(change) * tokenQuotaParams.rate / PERCENTAGE_FACTOR).toInt256(); // U: [QL-3]
        } else {
            //
            // DECREASE QUOTA
            //
            change = uint96(-quotaChange);
            realQuotaChange = quotaChange; // U: [QL-3]

            tokenQuotaParams.totalQuoted -= change; // U: [QL-3]
            accountQuota.quota -= change; // I:[CMQ-03] U: [QL-3]

            // Quoted tokens are only disabled in the CM when their quotas are changed
            // from non-zero to zero. This is done to correctly
            // update quotas on closing the account - if a token ends up disabled while having a non-zero quota,
            // the CM will fail to zero it on closing an account, which will break quota interest computations.
            // This value is returned in order for Credit Manager to update enabled tokens locally.
            if (accountQuota.quota <= 1) {
                disableToken = true; // U: [QL-3]
            }

            quotaRevenueChange = -(uint256(change) * tokenQuotaParams.rate / PERCENTAGE_FACTOR).toInt256(); // U: [QL-3]
        }
    }

    /// @dev Computes outstanding quota interest for a Credit Account,
    ///      and updates the interest index to set outstanding interest to 0
    /// @param tokenQuotaParams Quota parameters for a token
    /// @param accountQuota Quota data for a Credit Account to compute for
    /// @param lastQuotaRateUpdate Timestamp of the last time quota rates were updated
    /// @return caQuotaInterestChange Outstanding quota interest before the update. It is expected that this
    ///                               value is cached somewhere else (e.g., in Credit Manager), otherwise it
    ///                               will be lost.
    function accrueAccountQuotaInterest(
        TokenQuotaParams storage tokenQuotaParams,
        AccountQuota storage accountQuota,
        uint256 lastQuotaRateUpdate
    )
        internal
        initializedQuotasOnly(tokenQuotaParams) // U: [QL-9]
        returns (uint128 caQuotaInterestChange)
    {
        uint96 quoted = accountQuota.quota;
        uint192 cumulativeIndexNow = cumulativeIndexSince(tokenQuotaParams, lastQuotaRateUpdate);
        if (quoted > 1) {
            caQuotaInterestChange = calcAccruedQuotaInterest(quoted, cumulativeIndexNow, accountQuota.cumulativeIndexLU); // U: [QL-4]
        }
        accountQuota.cumulativeIndexLU = cumulativeIndexNow; // U: [QL-4]
    }

    /// @dev Internal function to zero the quota for a single quoted token
    /// @param tokenQuotaParams Quota parameters for a token
    /// @param accountQuota Quota data for a Credit Account to compute for
    /// @return quotaRevenueChange Amount to update quota revenue by.
    function removeQuota(TokenQuotaParams storage tokenQuotaParams, AccountQuota storage accountQuota)
        internal
        initializedQuotasOnly(tokenQuotaParams) // U: [QL-9]
        returns (int256 quotaRevenueChange)
    {
        uint96 quoted = accountQuota.quota;

        // Unlike general quota updates, quota removals do not update accountQuota.cumulativeIndexLU to save gas (i.e., do not accrue interest)
        // This is safe, since the quota is set to 1 and the index will be updated to the correct value on next change from
        // zero to non-zero, without breaking any interest calculations.
        if (quoted > 1) {
            quoted--;

            tokenQuotaParams.totalQuoted -= quoted; // U: [QL-5]
            accountQuota.quota = 1; // U: [QL-5]
            quotaRevenueChange = -(uint256(quoted) * tokenQuotaParams.rate / PERCENTAGE_FACTOR).toInt256(); // U: [QL-5]
        }
    }

    /// @dev Sets the total quota limit on a token
    /// @param tokenQuotaParams Quota parameters for a token
    /// @param limit The new limit on total quotas for a token
    function setLimit(TokenQuotaParams storage tokenQuotaParams, uint96 limit)
        internal
        initializedQuotasOnly(tokenQuotaParams) // U: [QL-9]
        returns (bool changed)
    {
        if (tokenQuotaParams.limit != limit) {
            tokenQuotaParams.limit = limit; // U: [QL-6]
            changed = true; // U: [QL-6]
        }
    }

    /// @dev Sets the percentage fee on quota increase
    /// @param tokenQuotaParams Quota parameters for a token
    /// @param fee The new fee
    function setQuotaIncreaseFee(TokenQuotaParams storage tokenQuotaParams, uint16 fee)
        internal
        initializedQuotasOnly(tokenQuotaParams) // U: [QL-9]
        returns (bool changed)
    {
        if (tokenQuotaParams.quotaIncreaseFee != fee) {
            tokenQuotaParams.quotaIncreaseFee = fee; // U: [QL-7]
            changed = true; // U: [QL-7]
        }
    }

    /// @dev Saves the current quota interest on a token and updates the interest rate
    /// @param tokenQuotaParams Quota parameters for a token
    /// @param lastQuotaRateUpdate Timestamp of the last quota rate update
    /// @param rate The new interest rate for a token
    /// @return quotaRevenue The new annual quota revenue for the token. Used to recompute quote revenue for the pool
    function updateRate(TokenQuotaParams storage tokenQuotaParams, uint256 lastQuotaRateUpdate, uint16 rate)
        internal
        initializedQuotasOnly(tokenQuotaParams) // U: [QL-9]
        returns (uint256 quotaRevenue)
    {
        tokenQuotaParams.cumulativeIndexLU_RAY = cumulativeIndexSince(tokenQuotaParams, lastQuotaRateUpdate); // U: [QL-8]
        tokenQuotaParams.rate = rate; // U: [QL-8]

        return uint256(tokenQuotaParams.totalQuoted) * rate / PERCENTAGE_FACTOR; // U: [QL-8]
    }
}
