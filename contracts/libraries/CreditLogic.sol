// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {CollateralDebtData, CollateralTokenData} from "../interfaces/ICreditManagerV3.sol";
import {SECONDS_PER_YEAR, PERCENTAGE_FACTOR} from "../libraries/Constants.sol";

import {BitMask} from "./BitMask.sol";

uint256 constant INDEX_PRECISION = 10 ** 9;

/// @title Credit logic library
/// @notice Implements functions used for debt and repayment calculations
library CreditLogic {
    using BitMask for uint256;
    using SafeCast for uint256;

    // ----------------- //
    // DEBT AND INTEREST //
    // ----------------- //

    /// @dev Computes growth since last update given yearly growth
    function calcLinearGrowth(uint256 value, uint256 timestampLastUpdate) internal view returns (uint256) {
        return value * (block.timestamp - timestampLastUpdate) / SECONDS_PER_YEAR;
    }

    /// @dev Computes interest accrued since the last update
    function calcAccruedInterest(uint256 amount, uint256 cumulativeIndexLastUpdate, uint256 cumulativeIndexNow)
        internal
        pure
        returns (uint256)
    {
        if (amount == 0) return 0;
        return (amount * cumulativeIndexNow) / cumulativeIndexLastUpdate - amount; // U:[CL-1]
    }

    /// @dev Computes total debt, given raw debt data
    /// @param collateralDebtData See `CollateralDebtData` (must have debt data filled)
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
    function calcLiquidationPayments(
        CollateralDebtData memory collateralDebtData,
        uint16 feeLiquidation,
        uint16 liquidationDiscount,
        function(uint256) view returns (uint256) amountWithFeeFn,
        function(uint256) view returns (uint256) amountMinusFeeFn
    ) internal view returns (uint256 amountToPool, uint256 remainingFunds, uint256 profit, uint256 loss) {
        amountToPool = calcTotalDebt(collateralDebtData); // U:[CL-4]

        uint256 debtWithInterest = collateralDebtData.debt + collateralDebtData.accruedInterest;

        amountToPool += collateralDebtData.earlyClosurePenalty * amountToPool / PERCENTAGE_FACTOR;

        debtWithInterest += collateralDebtData.earlyClosurePenalty * debtWithInterest / PERCENTAGE_FACTOR;

        uint256 totalValue = collateralDebtData.totalValue;

        uint256 totalFunds = totalValue * liquidationDiscount / PERCENTAGE_FACTOR;

        amountToPool += totalValue * feeLiquidation / PERCENTAGE_FACTOR; // U:[CL-4]

        uint256 amountToPoolWithFee = amountWithFeeFn(amountToPool);
        unchecked {
            if (totalFunds > amountToPoolWithFee) {
                remainingFunds = totalFunds - amountToPoolWithFee; // U:[CL-4]
            } else {
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

    // ----------- //
    // MANAGE DEBT //
    // ----------- //

    /// @dev Computes new debt principal and interest index after increasing debt
    ///      - The new debt principal is simply `debt + amount`
    ///      - The new credit account's interest index is a solution to the equation
    ///        `debt * (indexNow / indexLastUpdate - 1) = (debt + amount) * (indexNow / indexNew - 1)`,
    ///        which essentially writes that interest accrued since last update remains the same
    /// @param amount Amount to increase debt by
    /// @param debt Debt principal before increase
    /// @param cumulativeIndexNow The current interest index
    /// @param cumulativeIndexLastUpdate Credit account's interest index as of last update
    /// @return newDebt Debt principal after increase
    /// @return newCumulativeIndex New credit account's interest index
    function calcIncrease(uint256 amount, uint256 debt, uint256 cumulativeIndexNow, uint256 cumulativeIndexLastUpdate)
        internal
        pure
        returns (uint256 newDebt, uint256 newCumulativeIndex)
    {
        if (debt == 0) return (amount, cumulativeIndexNow);
        newDebt = debt + amount; // U:[CL-2]
        newCumulativeIndex =
        ((cumulativeIndexNow * newDebt * INDEX_PRECISION)
                / ((INDEX_PRECISION * cumulativeIndexNow * debt)
                    / cumulativeIndexLastUpdate
                    + INDEX_PRECISION
                    * amount)); // U:[CL-2]
    }

    /// @dev Computes new debt principal and interest index (and other values) after decreasing debt
    ///      - Bast interest is repaid first, then debt principal.
    ///      - The new credit account's interest index
    ///        is set to the current interest index if base interest was repaid fully, and is a solution to
    ///        the equation `debt * (indexNow / indexLastUpdate - 1) - delta = debt * (indexNow / indexNew - 1)`
    ///        when only `delta` of accrued interest was repaid
    /// @param amount Amount of debt to repay
    /// @param debt Debt principal before repayment
    /// @param cumulativeIndexNow The current interest index
    /// @param cumulativeIndexLastUpdate Credit account's interest index as of last update
    /// @param feeInterest Fee on accrued interest (both base and quota) charged by the DAO
    /// @return newDebt Debt principal after repayment
    /// @return newCumulativeIndex Credit account's quota interest after repayment
    /// @return profit Amount of underlying tokens received as fees by the DAO
    function calcDecrease(
        uint256 amount,
        uint256 debt,
        uint256 cumulativeIndexNow,
        uint256 cumulativeIndexLastUpdate,
        uint16 feeInterest
    ) internal pure returns (uint256 newDebt, uint256 newCumulativeIndex, uint256 profit) {
        uint256 amountToRepay = amount;

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
                // If amount is not enough to repay base interest + DAO fee, then it is split pro-rata between them
                uint256 amountToPool = (amountToRepay * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest);

                profit += amountToRepay - amountToPool;
                amountToRepay = 0;

                newCumulativeIndex = (INDEX_PRECISION * cumulativeIndexNow * cumulativeIndexLastUpdate)
                    / (INDEX_PRECISION
                        * cumulativeIndexNow
                        - (INDEX_PRECISION * amountToPool * cumulativeIndexLastUpdate)
                        / debt); // U:[CL-3]
            }
        } else {
            newCumulativeIndex = cumulativeIndexLastUpdate;
        }
        newDebt = debt - amountToRepay;
    }

    /// @dev Computes new debt principal and interest index after decreasing debt by subtracting from principal
    ///      The new cumulative index is a solution to the equation
    ///      `debt * (indexNow / indexLastUpdate - 1) - amount = (debt - amount) * (indexNow / indexNew - 1)`
    /// @param amount Amount of debt to subtract
    /// @param debt Debt principal before repayment
    /// @param cumulativeIndexNow The current interest index
    /// @param cumulativeIndexLastUpdate Credit account's interest index as of last update
    function calcDecreaseNoFees(
        uint256 amount,
        uint256 debt,
        uint256 cumulativeIndexNow,
        uint256 cumulativeIndexLastUpdate
    ) internal pure returns (uint256 newDebt, uint256 newCumulativeIndex) {
        newDebt = debt - amount;
        newCumulativeIndex = (INDEX_PRECISION * cumulativeIndexNow * cumulativeIndexLastUpdate)
            / (INDEX_PRECISION
                * cumulativeIndexNow
                * debt
                / newDebt
                + INDEX_PRECISION
                * amount
                * cumulativeIndexLastUpdate
                / newDebt);
    }
}
