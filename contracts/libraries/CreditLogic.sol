// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {CollateralDebtData, CollateralTokenData} from "../interfaces/ICreditManagerV3.sol";
import {SECONDS_PER_YEAR, PERCENTAGE_FACTOR} from "./Constants.sol";

uint256 constant INDEX_PRECISION = 10 ** 9;

/// @title  Credit logic library
/// @notice Implements functions used for borrowing and repayment calculations
library CreditLogic {
    // ----------------- //
    // DEBT AND INTEREST //
    // ----------------- //

    /// @notice Computes growth since last update given yearly growth
    function calcLinearGrowth(uint256 value, uint256 timestampLastUpdate) internal view returns (uint256) {
        return value * (block.timestamp - timestampLastUpdate) / SECONDS_PER_YEAR;
    }

    /// @notice Computes interest accrued since the last update
    /// @custom:tests U:[CL-1]
    function calcAccruedInterest(uint256 amount, uint256 cumulativeIndexLastUpdate, uint256 cumulativeIndexNow)
        internal
        pure
        returns (uint256)
    {
        if (amount == 0) return 0;
        return (amount * cumulativeIndexNow) / cumulativeIndexLastUpdate - amount;
    }

    /// @notice Computes total debt, given raw debt data
    function calcTotalDebt(CollateralDebtData memory collateralDebtData) internal pure returns (uint256) {
        return collateralDebtData.debt + collateralDebtData.accruedInterest + collateralDebtData.accruedFees;
    }

    // ----------- //
    // LIQUIDATION //
    // ----------- //

    /// @dev Computes the amount of underlying tokens to send to the pool on credit account liquidation
    ///      - First, liquidation premium and fee are subtracted from account's total value
    ///      - The resulting value is then used to repay the debt to the pool, and any remaining fudns
    ///        are send back to the account owner
    ///      - If, however, funds are insufficient to fully repay the debt, the function will first reduce
    ///        protocol profits before finally reporting a bad debt liquidation with loss
    /// @param collateralDebtData See `CollateralDebtData` (must have both collateral and debt data filled)
    /// @param feeLiquidation Liquidation fee charged by the DAO on the account collateral
    /// @param liquidationDiscount Percentage to discount account collateral by (equals 1 - liquidation premium)
    /// @param amountWithFeeFn Function that, given the exact amount of underlying tokens to receive,
    ///        returns the amount that needs to be sent
    /// @param amountWithFeeFn Function that, given the exact amount of underlying tokens to send,
    ///        returns the amount that will be received
    /// @return amountToPool Amount of underlying tokens to send to the pool
    /// @return remainingFunds Amount of underlying tokens to send to the credit account owner
    /// @return profit Amount of underlying tokens received as fees by the DAO
    /// @return loss Portion of account's debt that can't be repaid
    /// @custom:tests U:[CL-4]
    function calcLiquidationPayments(
        CollateralDebtData memory collateralDebtData,
        uint16 feeLiquidation,
        uint16 liquidationDiscount,
        function (uint256) view returns (uint256) amountWithFeeFn,
        function (uint256) view returns (uint256) amountMinusFeeFn
    ) internal view returns (uint256 amountToPool, uint256 remainingFunds, uint256 profit, uint256 loss) {
        amountToPool = calcTotalDebt(collateralDebtData);

        uint256 debtWithInterest = collateralDebtData.debt + collateralDebtData.accruedInterest;

        uint256 totalValue = collateralDebtData.totalValue;

        uint256 totalFunds = totalValue * liquidationDiscount / PERCENTAGE_FACTOR;

        amountToPool += totalValue * feeLiquidation / PERCENTAGE_FACTOR;

        uint256 amountToPoolWithFee = amountWithFeeFn(amountToPool);
        unchecked {
            if (totalFunds > amountToPoolWithFee) {
                remainingFunds = totalFunds - amountToPoolWithFee;
            } else {
                amountToPoolWithFee = totalFunds;
                amountToPool = amountMinusFeeFn(totalFunds);
            }

            if (amountToPool >= debtWithInterest) {
                profit = amountToPool - debtWithInterest;
            } else {
                loss = debtWithInterest - amountToPool;
            }
        }

        amountToPool = amountToPoolWithFee;
    }

    // --------------------- //
    // LIQUIDATION THRESHOLD //
    // --------------------- //

    /// @notice Returns the current liquidation threshold based on token data.
    ///         GearboxV3 supports liquidation threshold ramping, which means that the LT can be set to change from one
    ///         value to another over time. LT changes linearly, starting at `ltInitial` and ending at `ltFinal`.
    ///         To make LT static, set `ltInitial` and `ltFInal to the same value with ramp start far in the future.
    /// @custom:tests U:[CL-5]
    function getLiquidationThreshold(uint16 ltInitial, uint16 ltFinal, uint40 timestampRampStart, uint24 rampDuration)
        internal
        view
        returns (uint16)
    {
        if (block.timestamp <= timestampRampStart) return ltInitial;

        uint40 timestampRampEnd = timestampRampStart + rampDuration;
        if (block.timestamp >= timestampRampEnd) return ltFinal;

        // cast is safe since LT is between `ltInitial` and `ltFinal`, both of which are `uint16`
        return uint16(
            (ltInitial * (timestampRampEnd - block.timestamp) + ltFinal * (block.timestamp - timestampRampStart))
                / (timestampRampEnd - timestampRampStart)
        );
    }

    // ----------- //
    // MANAGE DEBT //
    // ----------- //

    /// @notice Computes new debt principal and interest index after increasing debt
    ///         - The new debt principal is simply `debt + amount`
    ///         - The new credit account's interest index is a solution to the equation
    ///         `debt * (indexNow / indexLastUpdate - 1) = (debt + amount) * (indexNow / indexNew - 1)`,
    ///         which essentially writes that interest accrued since last update remains the same
    /// @param  amount Amount to increase debt by
    /// @param  debt Debt principal before increase
    /// @param  cumulativeIndexNow The current interest index
    /// @param  cumulativeIndexLastUpdate Credit account's interest index as of last update
    /// @return newDebt Debt principal after increase
    /// @return newCumulativeIndex New credit account's interest index
    /// @custom:tests U:[CL-2]
    function calcIncrease(uint256 amount, uint256 debt, uint256 cumulativeIndexNow, uint256 cumulativeIndexLastUpdate)
        internal
        pure
        returns (uint256 newDebt, uint256 newCumulativeIndex)
    {
        if (debt == 0) return (amount, cumulativeIndexNow);
        newDebt = debt + amount;
        newCumulativeIndex = (
            (cumulativeIndexNow * newDebt * INDEX_PRECISION)
                / ((INDEX_PRECISION * cumulativeIndexNow * debt) / cumulativeIndexLastUpdate + INDEX_PRECISION * amount)
        );
    }

    /// @notice Computes new debt principal and interest index (and other values) after decreasing debt
    ///         - Debt comprises of multiple components which are repaid in the following order:
    ///         quota update fees => quota interest => base interest => debt principal.
    ///         New values for all these components depend on what portion of each was repaid.
    ///         - Debt principal, for example, only decreases if all previous components were fully repaid
    ///         - The new credit account's interest index stays the same if base interest was not repaid at all,
    ///         is set to the current interest index if base interest was repaid fully, and is a solution to
    ///         the equation `debt * (indexNow / indexLastUpdate - 1) - delta = debt * (indexNow / indexNew - 1)`
    ///         when only `delta` of accrued interest was repaid
    /// @param  amount Amount of debt to repay
    /// @param  debt Debt principal before repayment
    /// @param  cumulativeIndexNow The current interest index
    /// @param  cumulativeIndexLastUpdate Credit account's interest index as of last update
    /// @param  cumulativeQuotaInterest Credit account's quota interest before repayment
    /// @param  quotaFees Accrued quota fees
    /// @param  feeInterest Fee on accrued interest (both base and quota) charged by the DAO
    /// @return newDebt Debt principal after repayment
    /// @return newCumulativeIndex Credit account's quota interest after repayment
    /// @return profit Amount of underlying tokens received as fees by the DAO
    /// @return newCumulativeQuotaInterest Credit account's accrued quota interest after repayment
    /// @return newQuotaFees Amount of unpaid quota fees left after repayment
    /// @custom:tests U:[CL-3]
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

        unchecked {
            if (quotaFees != 0) {
                if (amountToRepay > quotaFees) {
                    newQuotaFees = 0;
                    amountToRepay -= quotaFees;
                    profit = quotaFees;
                } else {
                    newQuotaFees = quotaFees - uint128(amountToRepay);
                    profit = amountToRepay;
                    amountToRepay = 0;
                }
            }
        }

        if (cumulativeQuotaInterest != 0 && amountToRepay != 0) {
            uint256 quotaProfit = (cumulativeQuotaInterest * feeInterest) / PERCENTAGE_FACTOR;

            if (amountToRepay >= cumulativeQuotaInterest + quotaProfit) {
                amountToRepay -= cumulativeQuotaInterest + quotaProfit;
                profit += quotaProfit;

                newCumulativeQuotaInterest = 0;
            } else {
                // if amount is not enough to repay quota interest + DAO fee, then it is split pro-rata between them
                uint256 amountToPool = (amountToRepay * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest);

                profit += amountToRepay - amountToPool;
                amountToRepay = 0;

                newCumulativeQuotaInterest = uint128(cumulativeQuotaInterest - amountToPool);
            }
        } else {
            newCumulativeQuotaInterest = cumulativeQuotaInterest;
        }

        if (amountToRepay != 0) {
            uint256 interestAccrued = calcAccruedInterest({
                amount: debt,
                cumulativeIndexLastUpdate: cumulativeIndexLastUpdate,
                cumulativeIndexNow: cumulativeIndexNow
            });
            uint256 profitFromInterest = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR;

            if (amountToRepay >= interestAccrued + profitFromInterest) {
                amountToRepay -= interestAccrued + profitFromInterest;

                profit += profitFromInterest;

                newCumulativeIndex = cumulativeIndexNow;
            } else {
                // if amount is not enough to repay base interest + DAO fee, then it is split pro-rata between them
                uint256 amountToPool = (amountToRepay * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest);

                profit += amountToRepay - amountToPool;
                amountToRepay = 0;

                newCumulativeIndex = (INDEX_PRECISION * cumulativeIndexNow * cumulativeIndexLastUpdate)
                    / (
                        INDEX_PRECISION * cumulativeIndexNow
                            - (INDEX_PRECISION * amountToPool * cumulativeIndexLastUpdate) / debt
                    );
            }
        } else {
            newCumulativeIndex = cumulativeIndexLastUpdate;
        }
        newDebt = debt - amountToRepay;
    }
}
