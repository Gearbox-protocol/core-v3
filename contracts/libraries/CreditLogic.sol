// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {CollateralDebtData, CollateralTokenData} from "../interfaces/ICreditManagerV3.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";
import "../interfaces/IExceptions.sol";

uint256 constant INDEX_PRECISION = 10 ** 9;

/// @title Quota Library
library CreditLogic {
    function calcClosePayments(
        CollateralDebtData memory collateralDebtData,
        uint16 feeInterest,
        function (uint256) view returns (uint256) amountWithFeeFn
    ) internal view returns (uint256 amountToPool, uint256 profit) {
        uint256 debtWithInterest = collateralDebtData.debtWithInterest;
        // The amount to be paid to pool is computed with fees included
        // The pool will compute the amount of Diesel tokens to treasury
        // based on profit
        amountToPool = _calcAmountToPool(collateralDebtData.debt, debtWithInterest, feeInterest);

        unchecked {
            profit = amountToPool - debtWithInterest; // F:[CM-43]
        }

        amountToPool = amountWithFeeFn(amountToPool);
    }

    function calcLiquidationPayments(
        CollateralDebtData memory collateralDebtData,
        uint16 feeInterest,
        uint16 feeLiquidation,
        uint16 liquidationDiscount,
        function (uint256) view returns (uint256) amountWithFeeFn,
        function (uint256) view returns (uint256) amountMinusFeeFn
    ) internal view returns (uint256 amountToPool, uint256 remainingFunds, uint256 profit, uint256 loss) {
        uint256 debtWithInterest = collateralDebtData.debtWithInterest;
        // The amount to be paid to pool is computed with fees included
        // The pool will compute the amount of Diesel tokens to treasury
        // based on profit
        amountToPool = _calcAmountToPool(collateralDebtData.debt, debtWithInterest, feeInterest);

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
                amountToPool = amountMinusFeeFn(totalFunds); // F:[CM-43]
            }

            if (amountToPool >= debtWithInterest) {
                profit = amountToPool - debtWithInterest; // F:[CM-43]
            } else {
                loss = debtWithInterest - amountToPool; // F:[CM-43]
            }
        }

        amountToPool = amountWithFeeFn(amountToPool);
    }

    function _calcAmountToPool(uint256 debt, uint256 debtWithInterest, uint16 feeInterest)
        internal
        pure
        returns (uint256 amountToPool)
    {
        amountToPool = debtWithInterest + ((debtWithInterest - debt) * feeInterest) / PERCENTAGE_FACTOR;
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

    /// @dev Calculates the new cumulative index when debt is updated
    /// @param debt Current debt principal
    /// @param delta Absolute value of total debt amount change
    /// @param cumulativeIndexNow Current cumulative index of the pool
    /// @param cumulativeIndexOpen Last updated cumulative index recorded for the corresponding debt position
    /// @notice Handles two potential cases:
    ///         * Debt principal is increased by delta - in this case, the principal is changed
    ///           but the interest / fees have to stay the same
    ///         * Interest is decreased by delta - in this case, the principal stays the same,
    ///           but the interest changes. The delta is assumed to have fee repayment excluded.
    ///         The debt decrease case where delta > interest + fees is trivial and should be handled outside
    ///         this function.
    function calcIncrease(uint256 debt, uint256 delta, uint256 cumulativeIndexNow, uint256 cumulativeIndexOpen)
        internal
        pure
        returns (uint256 newDebt, uint256 newCumulativeIndex)
    {
        // In case of debt increase, the principal increases by exactly delta, but interest has to be kept unchanged
        // newCumulativeIndex is proven to be the solution to
        // debt * (cumulativeIndexNow / cumulativeIndexOpen - 1) ==
        // == (debt + delta) * (cumulativeIndexNow / newCumulativeIndex - 1)

        newDebt = debt + delta;

        newCumulativeIndex = (
            (cumulativeIndexNow * newDebt * INDEX_PRECISION)
                / ((INDEX_PRECISION * cumulativeIndexNow * debt) / cumulativeIndexOpen + INDEX_PRECISION * delta)
        );
    }

    function calcDescrease(
        uint256 amount,
        uint256 quotaInterestAccrued,
        uint16 feeInterest,
        uint256 debt,
        uint256 cumulativeIndexNow_RAY,
        uint256 cumulativeIndexAtOpen_RAY
    )
        internal
        pure
        returns (
            uint256 newDebt,
            uint256 newCumulativeIndex,
            uint256 amountRepaid,
            uint256 amountProfit,
            uint256 cumulativeQuotaInterest
        )
    {
        amountRepaid = amount;

        if (quotaInterestAccrued > 1) {
            uint256 quotaProfit = (quotaInterestAccrued * feeInterest) / PERCENTAGE_FACTOR;

            if (amountRepaid >= quotaInterestAccrued + quotaProfit) {
                amountRepaid -= quotaInterestAccrued + quotaProfit; // F: [CMQ-5]
                amountProfit += quotaProfit; // F: [CMQ-5]
                cumulativeQuotaInterest = 1; // F: [CMQ-5]
            } else {
                uint256 amountToPool = (amountRepaid * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest);

                amountProfit += amountRepaid - amountToPool; // F: [CMQ-4]
                amountRepaid = 0; // F: [CMQ-4]

                cumulativeQuotaInterest = quotaInterestAccrued - amountToPool + 1; // F: [CMQ-4]

                newDebt = debt;
                newCumulativeIndex = cumulativeIndexAtOpen_RAY;
            }
        }

        if (amountRepaid > 0) {
            // Computes the interest accrued thus far
            uint256 interestAccrued = (debt * newCumulativeIndex) / cumulativeIndexAtOpen_RAY - debt; // F:[CM-21]

            // Computes profit, taken as a percentage of the interest rate
            uint256 profit = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR; // F:[CM-21]

            if (amountRepaid >= interestAccrued + profit) {
                // If the amount covers all of the interest and fees, they are
                // paid first, and the remainder is used to pay the principal

                amountRepaid -= interestAccrued + profit;
                newDebt = debt - amountRepaid; //  + interestAccrued + profit - amount;

                amountProfit += profit;

                // Since interest is fully repaid, the Credit Account's cumulativeIndexAtOpen
                // is set to the current cumulative index - which means interest starts accruing
                // on the new principal from zero
                newCumulativeIndex = cumulativeIndexNow_RAY; // F:[CM-21]
            } else {
                // If the amount is not enough to cover interest and fees,
                // then the sum is split between dao fees and pool profits pro-rata. Since the fee is the percentage
                // of interest, this ensures that the new fee is consistent with the
                // new pending interest

                uint256 amountToPool = (amountRepaid * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest);

                amountProfit += amountRepaid - amountToPool;
                amountRepaid = 0;

                // Since interest and fees are paid out first, the principal
                // remains unchanged
                newDebt = debt;

                // Since the interest was only repaid partially, we need to recompute the
                // cumulativeIndexAtOpen, so that "debt * (indexNow / indexAtOpenNew - 1)"
                // is equal to interestAccrued - amountToInterest

                // In case of debt decrease, the principal is the same, but the interest is reduced exactly by delta
                // newCumulativeIndex is proven to be the solution to
                // debt * (cumulativeIndexNow / cumulativeIndexOpen - 1) - delta ==
                // == debt * (cumulativeIndexNow / newCumulativeIndex - 1)

                newCumulativeIndex = (INDEX_PRECISION * cumulativeIndexNow_RAY * cumulativeIndexAtOpen_RAY)
                    / (
                        INDEX_PRECISION * cumulativeIndexNow_RAY
                            - (INDEX_PRECISION * amountToPool * cumulativeIndexAtOpen_RAY) / debt
                    );

                // newCumulativeIndex =
                //     calcNewCumulativeIndex(debt, amountToPool, cumulativeIndexNow_RAY, cumulativeIndexAtOpen_RAY, false);
            }
        }
    }
}