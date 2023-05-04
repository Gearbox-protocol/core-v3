// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {CollateralDebtData} from "../interfaces/ICreditManagerV3.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

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
}
