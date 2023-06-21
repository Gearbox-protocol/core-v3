// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {CollateralDebtData, CollateralTokenData} from "../interfaces/ICreditManagerV3.sol";
import {SECONDS_PER_YEAR, PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

import {BitMask} from "./BitMask.sol";

uint256 constant INDEX_PRECISION = 10 ** 9;

/// @title Credit Logic Library
/// @dev Implements functions used for debt and repayment calculations
library CreditLogic {
    using BitMask for uint256;
    using SafeCast for uint256;

    //
    // DEBT AND REPAYMENT CALCULATIONS
    //

    /// @dev Computes the amount a linearly growing value increased by in a given timeframe
    /// @dev Usually, the value is some sort of an interest rate per year, and the function is used to compute
    ///      the growth of an index over aribtrary time
    /// @param value Target growth per year
    /// @param timestampLastUpdate Timestamp to compute the growth since
    function calcLinearGrowth(uint256 value, uint256 timestampLastUpdate) internal view returns (uint256) {
        // timeDifference = blockTime - previous timeStamp

        //                             timeDifference
        //  valueGrowth = value  *  -------------------
        //                           SECONDS_PER_YEAR
        //
        return value * (block.timestamp - timestampLastUpdate) / SECONDS_PER_YEAR;
    }

    /// @dev Calculates outstanding interest, given the principal and current and previous interest index values
    /// @param amount Amount of debt principal
    /// @param cumulativeIndexLastUpdate Interest index at the start of target period
    /// @param cumulativeIndexNow Current interest index
    function calcAccruedInterest(uint256 amount, uint256 cumulativeIndexLastUpdate, uint256 cumulativeIndexNow)
        internal
        pure
        returns (uint256)
    {
        return (amount * cumulativeIndexNow) / cumulativeIndexLastUpdate - amount; // U:[CL-1]
    }

    /// @dev Computes total debt, given raw debt data
    /// @param collateralDebtData Struct containing debt data
    function calcTotalDebt(CollateralDebtData memory collateralDebtData) internal pure returns (uint256) {
        return collateralDebtData.debt + collateralDebtData.accruedInterest + collateralDebtData.accruedFees;
    }

    /// @dev Computes the amount to send to pool on normal account closure, and fees
    /// @param collateralDebtData Struct containing debt data
    /// @param amountWithFeeFn Function that returns the amount to send in order for target amount to be delivered
    /// @return amountToPool Amount of the underlying asset to send to pool
    /// @return profit Amount of underlying received as fees by the DAO (if any)
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

    /// @dev Computes the amounts to send to pool and borrower on account liquidation, as well as profit or loss
    /// @param collateralDebtData Struct containing debt data
    /// @param feeLiquidation Fee charged by the DAO on the liquidation amount
    /// @param liquidationDiscount Percentage to discount the total value of account by. All value beyond the discounted amount can be
    ///                            taken by the liquidator. Equal to (1 - liquidationPremium).
    /// @param amountWithFeeFn Function that returns the amount to send, given the target amount that must be received
    /// @param amountMinusFeeFn Function that returns the amount that will be received, given the amount that will be sent
    /// @return amountToPool Amount of the underlying asset to send to pool
    /// @return remainingFunds Leftover amount to send to the account owner
    /// @return profit Amount of underlying received as fees by the DAO (if any)
    /// @return loss Shortfall between account value and total debt (if any)
    function calcLiquidationPayments(
        CollateralDebtData memory collateralDebtData,
        uint16 feeLiquidation,
        uint16 liquidationDiscount,
        function (uint256) view returns (uint256) amountWithFeeFn,
        function (uint256) view returns (uint256) amountMinusFeeFn
    ) internal view returns (uint256 amountToPool, uint256 remainingFunds, uint256 profit, uint256 loss) {
        amountToPool = calcTotalDebt(collateralDebtData); // U:[CL-4]

        uint256 debtWithInterest = collateralDebtData.debt + collateralDebtData.accruedInterest;

        uint256 totalValue = collateralDebtData.totalValue;

        /// Value of recoverable funds is totalValue * (1 - liquidationPremium)
        uint256 totalFunds = totalValue * liquidationDiscount / PERCENTAGE_FACTOR;

        amountToPool += totalValue * feeLiquidation / PERCENTAGE_FACTOR;

        uint256 amountToPoolWithFee = amountWithFeeFn(amountToPool);
        // Since values are compared to each other before subtracting,
        // this can be marked as unchecked to optimize gas
        unchecked {
            if (totalFunds > amountToPoolWithFee) {
                // If there are any funds left after all respective payments (this
                // includes the liquidation premium, since totalFunds is already
                // discounted from totalValue), they are recorded to remainingFunds
                // and will later be sent to the borrower. This accounts for sent amount
                // being inflated due to token transfer fees
                remainingFunds = totalFunds - amountToPoolWithFee - 1; // U:[CL-4]
            } else {
                // If totalFunds is not sufficient to cover the entire payment to pool,
                // the Credit Manager will repay what it can. When totalFunds >= debt + interest,
                // this simply means that part of protocol fees will be waived (profit is reduced). Otherwise,
                // there is bad debt (loss > 0). amountToPool has possible token transfer fees accounted for
                amountToPoolWithFee = totalFunds;
                amountToPool = amountMinusFeeFn(totalFunds); // U:[CL-4]
            }

            if (amountToPool >= debtWithInterest) {
                profit = amountToPool - debtWithInterest; // U:[CL-4]
            } else {
                loss = debtWithInterest - amountToPool; // U:[CL-4]
            }
        }

        amountToPool = amountToPoolWithFee; // U:[CL-4]
    }

    //
    // TOKEN AND LT
    //

    /// @dev Returns the current liquidation threshold based on token data
    /// @dev GearboxV3 supports liquidation threshold ramping, which means that the LT
    ///      can be set to change dynamically from one value to another over a period
    ///      The rate of change is linear, with LT starting at ltInitial at ramping period start
    ///      and ending at ltFinal at ramping period end. In case a static LT value is set,
    ///      it is written to ltInitial and ramping start is set to far future, which results
    ///      in the same LT value always being returned
    function getLiquidationThreshold(uint16 ltInitial, uint16 ltFinal, uint40 timestampRampStart, uint24 rampDuration)
        internal
        view
        returns (uint16)
    {
        if (block.timestamp < timestampRampStart) {
            return ltInitial; // U:[CL-05]
        }
        if (block.timestamp < timestampRampStart + rampDuration) {
            return _getRampingLiquidationThreshold(
                ltInitial, ltFinal, timestampRampStart, timestampRampStart + rampDuration
            ); // U:[CL-05]
        }
        return ltFinal; // U:[CL-05]
    }

    /// @dev Computes the LT in the middle of a ramp
    /// @param ltInitial LT value at the start of the ramp
    /// @param ltFinal LT value at the end of the ramp
    /// @param timestampRampStart Timestamp at which the ramp started
    /// @param timestampRampEnd Timestamp at which the ramp is scheduled to end
    function _getRampingLiquidationThreshold(
        uint16 ltInitial,
        uint16 ltFinal,
        uint40 timestampRampStart,
        uint40 timestampRampEnd
    ) internal view returns (uint16) {
        return uint16(
            (ltInitial * (timestampRampEnd - block.timestamp) + ltFinal * (block.timestamp - timestampRampStart))
                / (timestampRampEnd - timestampRampStart)
        ); // U:[CL-05]
    }

    //
    // INTEREST CALCULATIONS ON CHANGING DEBT
    //

    /// @dev Computes the new debt principal and interest index after increasing debt
    /// @param amount Amount to increase debt by
    /// @param debt The debt principal before increase
    /// @param cumulativeIndexNow The current interest index
    /// @param cumulativeIndexLastUpdate The last recorded interest index of the Credit Account
    /// @return newDebt The debt principal after decrease
    /// @return newCumulativeIndex The new recorded interest index of the Credit Account
    function calcIncrease(uint256 amount, uint256 debt, uint256 cumulativeIndexNow, uint256 cumulativeIndexLastUpdate)
        internal
        pure
        returns (uint256 newDebt, uint256 newCumulativeIndex)
    {
        newDebt = debt + amount; // U:[CL-02]

        /// In case of debt increase, the principal increases by exactly delta, but interest has to be kept unchanged
        /// The returned newCumulativeIndex is proven to be the solution to
        /// debt * (cumulativeIndexNow / cumulativeIndexOpen - 1) ==
        /// == (debt + delta) * (cumulativeIndexNow / newCumulativeIndex - 1)

        newCumulativeIndex = (
            (cumulativeIndexNow * newDebt * INDEX_PRECISION)
                / ((INDEX_PRECISION * cumulativeIndexNow * debt) / cumulativeIndexLastUpdate + INDEX_PRECISION * amount)
        ); // U:[CL-02]
    }

    /// @dev Computes new debt values after partially repaying debt
    /// @param amount Amount to decrease total debt by
    /// @param debt The debt principal before decrease
    /// @param cumulativeIndexNow The current interest index
    /// @param cumulativeIndexLastUpdate The last recorded interest index of the Credit Account
    /// @param cumulativeQuotaInterest Total quota interest of the account before decrease
    /// @param quotaFees Fees for updating quotas
    /// @param feeInterest Fee on accrued interest charged by the DAO
    /// @return newDebt Debt principal after repayment
    /// @return newCumulativeIndex The new recorded interest index of the Credit Account
    /// @return profit Amount going towards DAO fees
    /// @return newCumulativeQuotaInterest Quota interest of the Credit Account after repayment
    function calcDecrease(
        uint256 amount,
        uint256 debt,
        uint256 cumulativeIndexNow,
        uint256 cumulativeIndexLastUpdate,
        uint128 cumulativeQuotaInterest,
        uint128 quotaFees,
        uint16 feeInterest
    )
        internal
        pure
        returns (
            uint256 newDebt,
            uint256 newCumulativeIndex,
            uint256 profit,
            uint128 newCumulativeQuotaInterest,
            uint128 newQuotaFees
        )
    {
        uint256 amountToRepay = amount;

        /// The debt is repaid in the order of: quota fees -> quota interest -> base interest -> debt
        /// I.e., first the amount is subtracted from quota fees. If there is a remainder, it goes
        /// to repay quota interest, and so on. If the repayment amount only partially covers quota interest, then that will be
        /// partially repaid (with part of payment going to fees pro-rata), while base interest
        /// and debt remain inchanged. If the amount covers quota interest fully, then the same logic
        /// applies to the remaining amount and base interest/debt.
        unchecked {
            if (quotaFees != 0) {
                if (amountToRepay > quotaFees) {
                    newQuotaFees = 0;
                    amountToRepay -= quotaFees;
                    profit = quotaFees;
                } else {
                    newQuotaFees = quotaFees - amountToRepay.toUint128();
                    profit = amountToRepay;
                    amountToRepay = 0;
                }
            }
        }

        if (cumulativeQuotaInterest != 0 && amountToRepay != 0) {
            uint256 quotaProfit = (cumulativeQuotaInterest * feeInterest) / PERCENTAGE_FACTOR;

            if (amountToRepay >= cumulativeQuotaInterest + quotaProfit) {
                amountToRepay -= cumulativeQuotaInterest + quotaProfit; // U:[CL-03B]
                profit += quotaProfit; // U:[CL-03B]

                /// Since all the quota interest is repaid, the returned value is 0, which is then
                /// expected to be set in the CM. Since the CM is also expected to accrue all quota interest
                /// in PQK before the decrease, the quota interest value are consistent between the CM and PQK.
                newCumulativeQuotaInterest = 0; // U:[CL-03A]
            } else {
                /// If the amount is not enough to cover quota interest + fee, then it is split pro-rata
                /// between the two. This preserves correct fee computations.
                uint256 amountToPool = (amountToRepay * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest);

                profit += amountToRepay - amountToPool; // U:[CL-03B]
                amountToRepay = 0; // U:[CL-03B]

                newCumulativeQuotaInterest = uint128(cumulativeQuotaInterest - amountToPool); // U:[CL-03A]

                newDebt = debt; // U:[CL-03A]
                newCumulativeIndex = cumulativeIndexLastUpdate; // U:[CL-03A]
            }
        } else {
            newCumulativeQuotaInterest = cumulativeQuotaInterest;
        }

        if (amountToRepay != 0) {
            uint256 interestAccrued = calcAccruedInterest({
                amount: debt,
                cumulativeIndexLastUpdate: cumulativeIndexLastUpdate,
                cumulativeIndexNow: cumulativeIndexNow
            }); // U:[CL-03A]
            uint256 profitFromInterest = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR; // U:[CL-03A]

            if (amountToRepay >= interestAccrued + profitFromInterest) {
                amountToRepay -= interestAccrued + profitFromInterest;

                profit += profitFromInterest; // U:[CL-03B]

                // Since interest is fully repaid, the Credit Account's cumulativeIndexLastUpdate
                // is set to the current cumulative index - which means interest starts accruing
                // on the new principal from zero
                newCumulativeIndex = cumulativeIndexNow; // U:[CL-03A]
            } else {
                uint256 amountToPool = (amountToRepay * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest);

                profit += amountToRepay - amountToPool; // U:[CL-03B]
                amountToRepay = 0; // U:[CL-03B]

                // Since the interest was only repaid partially, we need to recompute the
                // cumulativeIndexLastUpdate, so that "debt * (indexNow / indexAtOpenNew - 1)"
                // is equal to interestAccrued - amountToInterest

                // newCumulativeIndex is proven to be the solution to
                // debt * (cumulativeIndexNow / cumulativeIndexOpen - 1) - delta ==
                // == debt * (cumulativeIndexNow / newCumulativeIndex - 1)

                newCumulativeIndex = (INDEX_PRECISION * cumulativeIndexNow * cumulativeIndexLastUpdate)
                    / (
                        INDEX_PRECISION * cumulativeIndexNow
                            - (INDEX_PRECISION * amountToPool * cumulativeIndexLastUpdate) / debt
                    ); // U:[CL-03A]
            }
        } else {
            newCumulativeIndex = cumulativeIndexLastUpdate; // U:[CL-03A]
        }
        newDebt = debt - amountToRepay;
    }
}
