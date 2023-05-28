// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {TokenQuotaParams, AccountQuota} from "../interfaces/IPoolQuotaKeeper.sol";
import {CreditLogic} from "./CreditLogic.sol";

import {RAY, SECONDS_PER_YEAR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

import "../interfaces/IExceptions.sol";

uint192 constant RAY_DIVIDED_BY_PERCENTAGE = uint192(RAY / PERCENTAGE_FACTOR);

/// @title Quota Library
library QuotasLogic {
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
        return calcLinearCumulativeIndex(tq, tq.rate, (block.timestamp - lastQuotaRateUpdate));
    }

    /// @dev Computes the new interest index value, given the previous value, the interest rate, and time delta
    /// @param tokenQuotaParams Quota parameters for a token
    /// @param rate The current interest rate on the token's quota
    /// @param deltaTimestamp Time period that interest was accruing for
    function calcLinearCumulativeIndex(TokenQuotaParams storage tokenQuotaParams, uint16 rate, uint256 deltaTimestamp)
        internal
        view
        returns (uint192)
    {
        /// The interest rate is always stored in PERCENTAGE_FACTOR format as APY, so the increase needs to be divided by 1 year
        return uint192(
            (
                uint256(tokenQuotaParams.cumulativeIndexLU_RAY)
                    * (RAY + (RAY_DIVIDED_BY_PERCENTAGE * (deltaTimestamp) * rate) / SECONDS_PER_YEAR) / RAY
            )
        );
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
    ) internal view returns (uint256 caQuotaInterestChange) {
        uint96 quoted = accountQuota.quota;
        if (quoted > 1) {
            uint192 cumulativeIndexNow = cumulativeIndexSince(tokenQuotaParams, lastQuotaRateUpdate);

            return CreditLogic.calcAccruedInterest({
                amount: quoted,
                cumulativeIndexLastUpdate: accountQuota.cumulativeIndexLU,
                cumulativeIndexNow: cumulativeIndexNow
            });
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
    /// @return quotaRevenueChange Amount to update quota revenue by.
    /// @return enableToken Whether to enable the quoted token.
    /// @return disableToken Whether to disable the quoted token
    function changeQuota(
        TokenQuotaParams storage tokenQuotaParams,
        AccountQuota storage accountQuota,
        uint256 lastQuotaRateUpdate,
        int96 quotaChange
    )
        internal
        initializedQuotasOnly(tokenQuotaParams)
        returns (uint256 caQuotaInterestChange, int128 quotaRevenueChange, bool enableToken, bool disableToken)
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
            // If the amount is larger than the existing capacity, then only the quota is only increased
            // by capacity. This is done instead of reverting to avoid unexpected reverts due to race conditions
            uint96 maxQuotaAllowed = tokenQuotaParams.limit - tokenQuotaParams.totalQuoted;

            if (maxQuotaAllowed == 0) {
                return (caQuotaInterestChange, 0, false, false);
            }

            change = uint96(quotaChange);
            change = change > maxQuotaAllowed ? maxQuotaAllowed : change; // F:[CMQ-08,10]

            // Quoted tokens are only enabled in the CM when their quotas are changed
            // from zero to non-zero. This is done to correctly
            // update quotas on closing the account - if a token ends up disabled while having a non-zero quota,
            // the CM will fail to zero it on closing an account, which will break quota interest computations.
            // This value is returned in order for Credit Manager to update enabled tokens locally.
            if (accountQuota.quota <= 1) {
                enableToken = true;
            }

            accountQuota.quota += change;
            tokenQuotaParams.totalQuoted += change;

            // For some tokens, a one-time quota increase fee may be charged. This is a proxy for
            // trading fees for tokens with high volume but short position duration, in which
            // case trading fees are a more effective pricing policy than charging interest over time
            caQuotaInterestChange += change * tokenQuotaParams.quotaIncreaseFee / PERCENTAGE_FACTOR;

            // Quota revenue is a global sum of all quota interest received from all tokens and accounts
            // per year. It is used by the pool to effectively compute expected quota revenue with just one value
            quotaRevenueChange = int128(int16(tokenQuotaParams.rate)) * int96(change);
        } else {
            //
            // DECREASE QUOTA
            //
            change = uint96(-quotaChange);

            tokenQuotaParams.totalQuoted -= change;
            accountQuota.quota -= change; // F:[CMQ-03]

            // Quoted tokens are only disabled in the CM when their quotas are changed
            // from non-zero to zero. This is done to correctly
            // update quotas on closing the account - if a token ends up disabled while having a non-zero quota,
            // the CM will fail to zero it on closing an account, which will break quota interest computations.
            // This value is returned in order for Credit Manager to update enabled tokens locally.
            if (accountQuota.quota <= 1) {
                disableToken = true;
            }

            quotaRevenueChange = -int128(int16(tokenQuotaParams.rate)) * int96(change);
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
    ) internal initializedQuotasOnly(tokenQuotaParams) returns (uint256 caQuotaInterestChange) {
        uint192 cumulativeIndexNow = cumulativeIndexSince(tokenQuotaParams, lastQuotaRateUpdate); // F:[CMQ-03]

        uint96 quoted = accountQuota.quota;
        if (quoted > 1) {
            caQuotaInterestChange = CreditLogic.calcAccruedInterest({
                amount: quoted,
                cumulativeIndexLastUpdate: accountQuota.cumulativeIndexLU,
                cumulativeIndexNow: cumulativeIndexNow
            });
        }

        accountQuota.cumulativeIndexLU = cumulativeIndexNow;
    }

    /// @dev Internal function to zero the quota for a single quoted token
    /// @param tokenQuotaParams Quota parameters for a token
    /// @param accountQuota Quota data for a Credit Account to compute for
    /// @return quotaRevenueChange Amount to update quota revenue by.
    function removeQuota(TokenQuotaParams storage tokenQuotaParams, AccountQuota storage accountQuota)
        internal
        initializedQuotasOnly(tokenQuotaParams)
        returns (int128 quotaRevenueChange)
    {
        uint96 quoted = accountQuota.quota;

        // Unlike general quota updates, quota removals do not update accountQuota.cumulativeIndexLU to save gas (i.e., do not accrue interest)
        // This is safe, since the quota is set to 1 and the index will be updated to the correct value on next change from
        // zero to non-zero, without breaking any interest calculations.
        if (quoted > 1) {
            quoted--;

            tokenQuotaParams.totalQuoted -= quoted;
            accountQuota.quota = 1;
            quotaRevenueChange = -int128(int16(tokenQuotaParams.rate)) * int96(quoted);
        }
    }

    /// @dev Sets the total quota limit on a token
    /// @param tokenQuotaParams Quota parameters for a token
    /// @param limit The new limit on total quotas for a token
    function setLimit(TokenQuotaParams storage tokenQuotaParams, uint96 limit)
        internal
        initializedQuotasOnly(tokenQuotaParams)
        returns (bool changed)
    {
        if (tokenQuotaParams.limit != limit) {
            tokenQuotaParams.limit = limit; // F:[PQK-12]
            changed = true;
        }
    }

    /// @dev Sets the percentage fee on quota increase
    /// @param tokenQuotaParams Quota parameters for a token
    /// @param fee The new fee
    function setQuotaIncreaseFee(TokenQuotaParams storage tokenQuotaParams, uint16 fee)
        internal
        initializedQuotasOnly(tokenQuotaParams)
        returns (bool changed)
    {
        if (tokenQuotaParams.quotaIncreaseFee != fee) {
            tokenQuotaParams.quotaIncreaseFee = fee;
            changed = true;
        }
    }

    /// @dev Saves the current quota interest on a token and updates the interest rate
    /// @param tokenQuotaParams Quota parameters for a token
    /// @param timeFromLastUpdate Time since the last rate update
    /// @param rate The new interest rate for a token
    /// @return quotaRevenue The new annual quota revenue for the token. Used to recompute quote revenue for the pool
    function updateRate(TokenQuotaParams storage tokenQuotaParams, uint256 timeFromLastUpdate, uint16 rate)
        internal
        returns (uint128 quotaRevenue)
    {
        tokenQuotaParams.cumulativeIndexLU_RAY = calcLinearCumulativeIndex(tokenQuotaParams, rate, timeFromLastUpdate); // F:[PQK-7]
        tokenQuotaParams.rate = rate;

        return rate * tokenQuotaParams.totalQuoted;
    }
}
