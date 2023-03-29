// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {TokenQuotaParams} from "../interfaces/IPoolQuotaKeeper.sol";

import {RAY, SECONDS_PER_YEAR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

uint192 constant RAY_DIVIDED_BY_PERCENTAGE = uint192(RAY / PERCENTAGE_FACTOR);

/// @title Quota Library
library Quotas {
    function isTokenRegistered(TokenQuotaParams memory q) internal pure returns (bool) {
        return q.cumulativeIndexLU_RAY != 0;
    }

    function cumulativeIndexSince(TokenQuotaParams memory tq, uint256 lastQuotaRateUpdate)
        internal
        view
        returns (uint192)
    {
        return calcLinearCumulativeIndex(tq, tq.rate, (block.timestamp - lastQuotaRateUpdate));
    }

    function calcLinearCumulativeIndex(TokenQuotaParams memory tq, uint16 rate, uint256 deltaTimestamp)
        internal
        pure
        returns (uint192)
    {
        return uint192(
            (
                uint256(tq.cumulativeIndexLU_RAY)
                    * (RAY + (RAY_DIVIDED_BY_PERCENTAGE * (deltaTimestamp) * rate) / SECONDS_PER_YEAR) / RAY
            )
        );
    }
}
