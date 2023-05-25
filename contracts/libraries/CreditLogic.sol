// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {CollateralDebtData, CollateralTokenData} from "../interfaces/ICreditManagerV3.sol";
import {IERC20Helper} from "./IERC20Helper.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";
import {SECONDS_PER_YEAR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import "../interfaces/IExceptions.sol";

import {BitMask} from "./BitMask.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RAY} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {Balance} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";

uint256 constant INDEX_PRECISION = 10 ** 9;

import "forge-std/console.sol";

/// @title Credit Logic Library
library CreditLogic {
    using BitMask for uint256;

    function calcLinearGrowth(uint256 value, uint256 timestampLastUpdate) internal view returns (uint256) {
        // timeDifference = blockTime - previous timeStamp

        //                             timeDifference
        //  valueGrowth = value  *  -------------------
        //                           SECONDS_PER_YEAR
        //
        return value * (block.timestamp - timestampLastUpdate) / SECONDS_PER_YEAR;
    }

    function calcAccruedInterest(uint256 amount, uint256 cumulativeIndexLastUpdate, uint256 cumulativeIndexNow)
        internal
        pure
        returns (uint256)
    {
        return (amount * cumulativeIndexNow) / cumulativeIndexLastUpdate - amount;
    }

    function calcTotalDebt(CollateralDebtData memory collateralDebtData) internal pure returns (uint256) {
        return collateralDebtData.debt + collateralDebtData.accruedInterest + collateralDebtData.accruedFees;
    }

    function calcClosePayments(
        CollateralDebtData memory collateralDebtData,
        function (uint256) view returns (uint256) amountWithFeeFn
    ) internal view returns (uint256 amountToPool, uint256 profit) {
        // The amount to be paid to pool is computed with fees included
        // The pool will compute the amount of Diesel tokens to treasury
        // based on profit
        amountToPool = amountWithFeeFn(calcTotalDebt(collateralDebtData));

        profit = collateralDebtData.accruedFees;
    }

    function calcLiquidationPayments(
        CollateralDebtData memory collateralDebtData,
        uint16 feeLiquidation,
        uint16 liquidationDiscount,
        function (uint256) view returns (uint256) amountWithFeeFn,
        function (uint256) view returns (uint256) amountMinusFeeFn
    ) internal view returns (uint256 amountToPool, uint256 remainingFunds, uint256 profit, uint256 loss) {
        // The amount to be paid to pool is computed with fees included
        // The pool will compute the amount of Diesel tokens to treasury
        // based on profit
        amountToPool = calcTotalDebt(collateralDebtData);

        uint256 debtWithInterest = collateralDebtData.debt + collateralDebtData.accruedInterest;

        // LIQUIDATION CASE
        uint256 totalValue = collateralDebtData.totalValue;

        uint256 totalFunds = totalValue * liquidationDiscount / PERCENTAGE_FACTOR; // F:[CM-43]

        amountToPool += totalValue * feeLiquidation / PERCENTAGE_FACTOR; // F:[CM-43]

        // If there are any funds left after all respective payments (this
        // includes the liquidation premium, since totalFunds is already
        // discounted from totalValue), they are recorded to remainingFunds
        // and will later be sent to the borrower.

        // If totalFunds is not sufficient to cover the entire payment to pool,
        // the Credit Manager will repay what it can. When totalFunds >= debt + interest,
        // this simply means that part of protocol fees will be waived (profit is reduced). Otherwise,
        // there is bad debt (loss > 0).

        // Since values are compared to each other before subtracting,
        // this can be marked as unchecked to optimize gas

        uint256 amountToPoolWithFee = amountWithFeeFn(amountToPool);
        unchecked {
            if (totalFunds > amountToPoolWithFee) {
                remainingFunds = totalFunds - amountToPoolWithFee - 1; // F:[CM-43]
            } else {
                amountToPoolWithFee = totalFunds;
                amountToPool = amountMinusFeeFn(totalFunds); // F:[CM-43]
            }

            if (amountToPool >= debtWithInterest) {
                profit = amountToPool - debtWithInterest; // F:[CM-43]
            } else {
                loss = debtWithInterest - amountToPool; // F:[CM-43]
            }
        }

        amountToPool = amountToPoolWithFee;
    }

    function getTokenOrRevert(CollateralTokenData storage tokenData) internal view returns (address token) {
        token = tokenData.token;

        if (token == address(0)) {
            revert TokenNotAllowedException();
        }
    }

    function getLiquidationThreshold(CollateralTokenData storage tokenData) internal view returns (uint16) {
        if (block.timestamp < tokenData.timestampRampStart) {
            return tokenData.ltInitial; // F:[CM-47]
        }
        if (block.timestamp < tokenData.timestampRampStart + tokenData.rampDuration) {
            return _getRampingLiquidationThreshold(
                tokenData.ltInitial,
                tokenData.ltFinal,
                tokenData.timestampRampStart,
                tokenData.timestampRampStart + tokenData.rampDuration
            );
        }
        return tokenData.ltFinal;
    }

    function _getRampingLiquidationThreshold(
        uint16 ltInitial,
        uint16 ltFinal,
        uint40 timestampRampStart,
        uint40 timestampRampEnd
    ) internal view returns (uint16) {
        return uint16(
            (ltInitial * (timestampRampEnd - block.timestamp) + ltFinal * (block.timestamp - timestampRampStart))
                / (timestampRampEnd - timestampRampStart)
        ); // F: [CM-72]
    }

    /// MANAGE DEBT

    function calcIncrease(uint256 amount, uint256 debt, uint256 cumulativeIndexNow, uint256 cumulativeIndexLastUpdate)
        internal
        pure
        returns (uint256 newDebt, uint256 newCumulativeIndex)
    {
        // In case of debt increase, the principal increases by exactly delta, but interest has to be kept unchanged
        // newCumulativeIndex is proven to be the solution to
        // debt * (cumulativeIndexNow / cumulativeIndexOpen - 1) ==
        // == (debt + delta) * (cumulativeIndexNow / newCumulativeIndex - 1)

        newDebt = debt + amount;

        newCumulativeIndex = (
            (cumulativeIndexNow * newDebt * INDEX_PRECISION)
                / ((INDEX_PRECISION * cumulativeIndexNow * debt) / cumulativeIndexLastUpdate + INDEX_PRECISION * amount)
        );
    }

    function calcDecrease(
        uint256 amount,
        uint256 debt,
        uint256 cumulativeIndexNow,
        uint256 cumulativeIndexLastUpdate,
        uint256 cumulativeQuotaInterest,
        uint16 feeInterest
    )
        internal
        pure
        returns (
            uint256 newDebt,
            uint256 newCumulativeIndex,
            uint256 amountToRepay,
            uint256 profit,
            uint256 newCumulativeQuotaInterest
        )
    {
        amountToRepay = amount;

        if (cumulativeQuotaInterest != 0) {
            uint256 quotaProfit = (cumulativeQuotaInterest * feeInterest) / PERCENTAGE_FACTOR;

            if (amountToRepay >= cumulativeQuotaInterest + quotaProfit) {
                amountToRepay -= cumulativeQuotaInterest + quotaProfit; // I:[CMQ-5]
                profit += quotaProfit; // I:[CMQ-5]
                newCumulativeQuotaInterest = 0; // I:[CMQ-5]
            } else {
                uint256 amountToPool = (amountToRepay * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest);

                profit += amountToRepay - amountToPool; // I:[CMQ-4]
                amountToRepay = 0; // I:[CMQ-4]

                newCumulativeQuotaInterest = cumulativeQuotaInterest - amountToPool; // I:[CMQ-4]

                newDebt = debt;
                newCumulativeIndex = cumulativeIndexLastUpdate;
            }
        }

        if (amountToRepay > 0) {
            // Computes the interest accrued thus far
            uint256 interestAccrued = (debt * cumulativeIndexNow) / cumulativeIndexLastUpdate - debt; // F:[CM-21]

            // Computes profit, taken as a percentage of the interest rate
            uint256 profitFromInterest = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR; // F:[CM-21]

            if (amountToRepay >= interestAccrued + profitFromInterest) {
                // If the amount covers all of the interest and fees, they are
                // paid first, and the remainder is used to pay the principal

                amountToRepay -= interestAccrued + profitFromInterest;
                newDebt = debt - amountToRepay; //  + interestAccrued + profit - amount;

                profit += profitFromInterest;

                // Since interest is fully repaid, the Credit Account's cumulativeIndexLastUpdate
                // is set to the current cumulative index - which means interest starts accruing
                // on the new principal from zero
                newCumulativeIndex = cumulativeIndexNow; // F:[CM-21]
            } else {
                // If the amount is not enough to cover interest and fees,
                // then the sum is split between dao fees and pool profits pro-rata. Since the fee is the percentage
                // of interest, this ensures that the new fee is consistent with the
                // new pending interest

                uint256 amountToPool = (amountToRepay * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest);

                profit += amountToRepay - amountToPool;
                amountToRepay = 0;

                // Since interest and fees are paid out first, the principal
                // remains unchanged
                newDebt = debt;

                // Since the interest was only repaid partially, we need to recompute the
                // cumulativeIndexLastUpdate, so that "debt * (indexNow / indexAtOpenNew - 1)"
                // is equal to interestAccrued - amountToInterest

                // In case of debt decrease, the principal is the same, but the interest is reduced exactly by delta
                // newCumulativeIndex is proven to be the solution to
                // debt * (cumulativeIndexNow / cumulativeIndexOpen - 1) - delta ==
                // == debt * (cumulativeIndexNow / newCumulativeIndex - 1)

                newCumulativeIndex = (INDEX_PRECISION * cumulativeIndexNow * cumulativeIndexLastUpdate)
                    / (
                        INDEX_PRECISION * cumulativeIndexNow
                            - (INDEX_PRECISION * amountToPool * cumulativeIndexLastUpdate) / debt
                    );
            }
        } else {
            newDebt = debt;
            newCumulativeIndex = cumulativeIndexLastUpdate;
        }
    }
}
