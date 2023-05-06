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
    function isTokenRegistered(TokenQuotaParams memory q) internal pure returns (bool) {
        return q.cumulativeIndexLU_RAY != 0;
    }

    function cumulativeIndexSince(TokenQuotaParams storage tq, uint256 lastQuotaRateUpdate)
        internal
        view
        returns (uint192)
    {
        return calcLinearCumulativeIndex(tq, tq.rate, (block.timestamp - lastQuotaRateUpdate));
    }

    function calcLinearCumulativeIndex(TokenQuotaParams storage tq, uint16 rate, uint256 deltaTimestamp)
        internal
        view
        returns (uint192)
    {
        return uint192(
            (
                uint256(tq.cumulativeIndexLU_RAY)
                    * (RAY + (RAY_DIVIDED_BY_PERCENTAGE * (deltaTimestamp) * rate) / SECONDS_PER_YEAR) / RAY
            )
        );
    }

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

    function changeQuota(
        TokenQuotaParams storage tokenQuotaParams,
        AccountQuota storage accountQuota,
        uint256 lastQuotaRateUpdate,
        int96 quotaChange
    )
        internal
        returns (uint256 caQuotaInterestChange, int128 quotaRevenueChange, bool enableToken, bool disableToken)
    {
        if (!isTokenRegistered(tokenQuotaParams)) {
            revert TokenIsNotQuotedException(); // F:[PQK-13]
        }

        caQuotaInterestChange = accrueAccountQuotaInterest({
            tokenQuotaParams: tokenQuotaParams,
            accountQuota: accountQuota,
            lastQuotaRateUpdate: lastQuotaRateUpdate
        });

        uint96 change;
        if (quotaChange > 0) {
            uint96 maxQuotaAllowed = tokenQuotaParams.limit - tokenQuotaParams.totalQuoted;

            if (maxQuotaAllowed == 0) {
                return (caQuotaInterestChange, 0, false, false);
            }

            change = uint96(quotaChange);
            change = change > maxQuotaAllowed ? maxQuotaAllowed : change; // F:[CMQ-08,10]

            // if quota was 0 and change > 0, we enable token
            if (accountQuota.quota <= 1) {
                enableToken = true;
            }

            accountQuota.quota += change;
            tokenQuotaParams.totalQuoted += change;

            quotaRevenueChange = int128(int16(tokenQuotaParams.rate)) * int96(change);
        } else {
            change = uint96(-quotaChange);

            tokenQuotaParams.totalQuoted -= change;
            accountQuota.quota -= change; // F:[CMQ-03]

            if (accountQuota.quota <= 1) {
                disableToken = true;
            }

            quotaRevenueChange = -int128(int16(tokenQuotaParams.rate)) * int96(change);
        }
    }

    function accrueAccountQuotaInterest(
        TokenQuotaParams storage tokenQuotaParams,
        AccountQuota storage accountQuota,
        uint256 lastQuotaRateUpdate
    ) internal returns (uint256 caQuotaInterestChange) {
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
    function removeQuota(TokenQuotaParams storage tokenQuotaParams, AccountQuota storage accountQuota)
        internal
        returns (int128 quotaRevenueChange)
    {
        uint96 quoted = accountQuota.quota;

        if (quoted > 1) {
            quoted--;

            tokenQuotaParams.totalQuoted -= quoted;
            accountQuota.quota = 1;
            quotaRevenueChange = -int128(int16(tokenQuotaParams.rate)) * int96(quoted);
        }
    }
}
