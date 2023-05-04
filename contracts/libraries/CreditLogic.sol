// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {CollateralDebtData} from "../interfaces/ICreditManagerV3.sol";

/// @title Quota Library
library CreditLogic {
    function calcClosePayments(CollateralDebtData memory collateralDebtData, uint16 feeInterest)
        internal
        returns (uint256 amountToPool, uint256 profit)
    {
        uint256 totalValue = collateralDebtData.totalValue;
        uint256 debtWithInterest = collateralDebtData.debtWithInterest;
        // The amount to be paid to pool is computed with fees included
        // The pool will compute the amount of Diesel tokens to treasury
        // based on profit
        amountToPool =
            debtWithInterest + ((debtWithInterest - collateralDebtData.debt) * feeInterest) / PERCENTAGE_FACTOR; // F:[CM-43]

        if (
            closureAction == ClosureAction.LIQUIDATE_ACCOUNT || closureAction == ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT
        ) {
            // LIQUIDATION CASE

            // During liquidation, totalValue of the account is discounted
            // by (1 - liquidationPremium). This means that totalValue * liquidationPremium
            // is removed from all calculations and can be claimed by the liquidator at the end of transaction

            // The liquidation premium depends on liquidation type:
            // * For normal unhealthy account or emergency liquidations, usual premium applies
            // * For expiry liquidations, the premium is typically reduced,
            //   since the account does not risk bad debt, so the liquidation
            //   is not as urgent

            uint256 totalFunds = (
                totalValue
                    * (closureAction == ClosureAction.LIQUIDATE_ACCOUNT ? liquidationDiscount : liquidationDiscountExpired)
            ) / PERCENTAGE_FACTOR; // F:[CM-43]

            amountToPool += (
                totalValue * (closureAction == ClosureAction.LIQUIDATE_ACCOUNT ? feeLiquidation : feeLiquidationExpired)
            ) / PERCENTAGE_FACTOR; // F:[CM-43]

            /// Adding fee here
            // amountToPool = _amountWithFee(amountToPool);

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

            unchecked {
                if (totalFunds > amountToPool) {
                    remainingFunds = totalFunds - amountToPool - 1; // F:[CM-43]
                } else {
                    amountToPool = totalFunds; // F:[CM-43]
                }

                if (totalFunds >= debtWithInterest) {
                    profit = amountToPool - debtWithInterest; // F:[CM-43]
                } else {
                    loss = debtWithInterest - amountToPool; // F:[CM-43]
                }
            }
        } else {
            // CLOSURE CASE

            // During closure, it is assumed that the user has enough to cover
            // the principal + interest + fees. closeCreditAccount, thus, will
            // attempt to charge them the entire amount.

            // Since in this case amountToPool + debtWithInterest + fee,
            // this block can be marked as unchecked

            unchecked {
                profit = amountToPool - debtWithInterest; // F:[CM-43]
            }
        }
    }
}
