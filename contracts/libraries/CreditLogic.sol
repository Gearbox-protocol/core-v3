// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Helper} from "./IERC20Helper.sol";
import {CollateralDebtData, CollateralTokenData, CreditAccountInfo} from "../interfaces/ICreditManagerV3.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";
import {SECONDS_PER_YEAR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import "../interfaces/IExceptions.sol";

import {BitMask} from "./BitMask.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RAY} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {Balance} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";

/// INTERFACES
import {IPoolQuotaKeeper} from "../interfaces/IPoolQuotaKeeper.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import {IWithdrawalManager} from "../interfaces/IWithdrawalManager.sol";

uint256 constant INDEX_PRECISION = 10 ** 9;

/// @title Credit Logic Library
library CreditLogic {
    using BitMask for uint256;
    using IERC20Helper for IERC20;

    function calcLinearGrowth(uint256 value, uint256 timestampLastUpdate) internal view returns (uint256) {
        // timeDifference = blockTime - previous timeStamp

        //                             timeDifference
        //  grownVluaed = value  *  -------------------
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
    /// @param delta Absolute value of total debt amount change
    /// @notice Handles two potential cases:
    ///         * Debt principal is increased by delta - in this case, the principal is changed
    ///           but the interest / fees have to stay the same
    ///         * Interest is decreased by delta - in this case, the principal stays the same,
    ///           but the interest changes. The delta is assumed to have fee repayment excluded.
    ///         The debt decrease case where delta > interest + fees is trivial and should be handled outside
    ///         this function.
    function calcIncrease(CollateralDebtData memory collateralDebtData, uint256 delta)
        internal
        pure
        returns (uint256 newDebt, uint256 newCumulativeIndex)
    {
        // In case of debt increase, the principal increases by exactly delta, but interest has to be kept unchanged
        // newCumulativeIndex is proven to be the solution to
        // debt * (cumulativeIndexNow / cumulativeIndexOpen - 1) ==
        // == (debt + delta) * (cumulativeIndexNow / newCumulativeIndex - 1)

        newDebt = collateralDebtData.debt + delta;

        newCumulativeIndex = (
            (collateralDebtData.cumulativeIndexNow * newDebt * INDEX_PRECISION)
                / (
                    (INDEX_PRECISION * collateralDebtData.cumulativeIndexNow * collateralDebtData.debt)
                        / collateralDebtData.cumulativeIndexLastUpdate + INDEX_PRECISION * delta
                )
        );
    }

    function calcDecrease(CollateralDebtData memory collateralDebtData, uint256 amount, uint16 feeInterest)
        internal
        pure
        returns (uint256 newDebt, uint256 newCumulativeIndex, uint256 amountToRepay, uint256 profit)
    {
        amountToRepay = amount;

        uint256 quotaInterestAccrued = collateralDebtData.cumulativeQuotaInterest;

        if (quotaInterestAccrued > 1) {
            uint256 quotaProfit = (quotaInterestAccrued * feeInterest) / PERCENTAGE_FACTOR;

            if (amountToRepay >= quotaInterestAccrued + quotaProfit) {
                amountToRepay -= quotaInterestAccrued + quotaProfit; // F: [CMQ-5]
                profit += quotaProfit; // F: [CMQ-5]
                collateralDebtData.cumulativeQuotaInterest = 1; // F: [CMQ-5]
            } else {
                uint256 amountToPool = (amountToRepay * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest);

                profit += amountToRepay - amountToPool; // F: [CMQ-4]
                amountToRepay = 0; // F: [CMQ-4]

                collateralDebtData.cumulativeQuotaInterest = quotaInterestAccrued - amountToPool + 1; // F: [CMQ-4]

                newDebt = collateralDebtData.debt;
                newCumulativeIndex = collateralDebtData.cumulativeIndexLastUpdate;
            }
        }

        if (amountToRepay > 0) {
            // Computes the interest accrued thus far
            uint256 interestAccrued = (collateralDebtData.debt * collateralDebtData.cumulativeIndexNow)
                / collateralDebtData.cumulativeIndexLastUpdate - collateralDebtData.debt; // F:[CM-21]

            // Computes profit, taken as a percentage of the interest rate
            uint256 profitFromInterest = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR; // F:[CM-21]

            if (amountToRepay >= interestAccrued + profitFromInterest) {
                // If the amount covers all of the interest and fees, they are
                // paid first, and the remainder is used to pay the principal

                amountToRepay -= interestAccrued + profitFromInterest;
                newDebt = collateralDebtData.debt - amountToRepay; //  + interestAccrued + profit - amount;

                profit += profitFromInterest;

                // Since interest is fully repaid, the Credit Account's cumulativeIndexLastUpdate
                // is set to the current cumulative index - which means interest starts accruing
                // on the new principal from zero
                newCumulativeIndex = collateralDebtData.cumulativeIndexNow; // F:[CM-21]
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
                newDebt = collateralDebtData.debt;

                // Since the interest was only repaid partially, we need to recompute the
                // cumulativeIndexLastUpdate, so that "debt * (indexNow / indexAtOpenNew - 1)"
                // is equal to interestAccrued - amountToInterest

                // In case of debt decrease, the principal is the same, but the interest is reduced exactly by delta
                // newCumulativeIndex is proven to be the solution to
                // debt * (cumulativeIndexNow / cumulativeIndexOpen - 1) - delta ==
                // == debt * (cumulativeIndexNow / newCumulativeIndex - 1)

                newCumulativeIndex = (
                    INDEX_PRECISION * collateralDebtData.cumulativeIndexNow
                        * collateralDebtData.cumulativeIndexLastUpdate
                )
                    / (
                        INDEX_PRECISION * collateralDebtData.cumulativeIndexNow
                            - (INDEX_PRECISION * amountToPool * collateralDebtData.cumulativeIndexLastUpdate)
                                / collateralDebtData.debt
                    );
            }
        } else {
            newDebt = collateralDebtData.debt;
            newCumulativeIndex = collateralDebtData.cumulativeIndexLastUpdate;
        }
    }

    //
    // COLLATERAL & DEBT COMPUTATION
    //

    // initCollateralDebtData({
    // ...
    // quotedTokenMask: supportsQuotas ? quotedTokenMask: 0,
    // ... });
    function initCollateralDebtData(
        CreditAccountInfo storage creditAccountInfo,
        uint256 cumulativeIndexNow,
        bool supportsQuotas,
        uint256 enabledTokensMask
    ) internal view returns (CollateralDebtData memory collateralDebtData) {
        // The total weighted value of a Credit Account has to be compared
        // with the entire debt sum, including interest and fees
        collateralDebtData.debt = creditAccountInfo.debt;
        collateralDebtData.cumulativeIndexLastUpdate = creditAccountInfo.cumulativeIndexLastUpdate;
        collateralDebtData.cumulativeIndexNow = cumulativeIndexNow;
        collateralDebtData.enabledTokensMask = enabledTokensMask;

        if (supportsQuotas) {
            collateralDebtData.cumulativeQuotaInterest = creditAccountInfo.cumulativeQuotaInterest - 1;
            // collateralDebtData._poolQuotaKeeper = address(poolQuotaKeeper());
        }
    }

    function getQuotaTokenData(
        CollateralDebtData memory collateralDebtData,
        address creditAccount,
        uint256 maxEnabledTokens,
        uint256 quotedTokenMask,
        function (uint256, bool) view returns (address, uint16) collateralTokensByMaskFn,
        function (address, address,address) view returns (uint256, uint256) getQuotaAndOutstandingInterestFn
    )
        internal
        view
        returns (
            address[] memory quotaTokens,
            uint256[] memory quotas,
            uint16[] memory lts,
            uint256 outstandingQuotaInterest
        )
    {
        uint256 j;
        quotedTokenMask = quotedTokenMask & collateralDebtData.enabledTokensMask;
        collateralDebtData.quotedTokenMask = quotedTokenMask;

        // uint256 underlyingPriceRAY =
        //     countCollateral ? convertToUSD(collateralDebtData._priceOracle, RAY, underlying) : 0;

        quotaTokens = new address[](maxEnabledTokens);
        quotas = new uint256[](maxEnabledTokens);
        lts = new uint16[](maxEnabledTokens);

        unchecked {
            for (uint256 tokenMask = 2; tokenMask <= quotedTokenMask; tokenMask <<= 1) {
                if (quotedTokenMask & tokenMask != 0) {
                    address token;
                    (token, lts[j]) = collateralTokensByMaskFn(tokenMask, true);

                    quotaTokens[j] = token;

                    uint256 outstandingInterestDelta;
                    (quotas[j], outstandingInterestDelta) =
                        getQuotaAndOutstandingInterestFn(collateralDebtData._poolQuotaKeeper, creditAccount, token);

                    // Safe because quotaInterest =  (quota is uint96) * APY * time, so even with 1000% APY, it will take 10**10 years for overflow
                    outstandingQuotaInterest += outstandingInterestDelta;

                    ++j;

                    if (j >= maxEnabledTokens) {
                        revert TooManyEnabledTokensException();
                    }
                }
            }
        }
    }

    /// @dev IMPLEMENTATION: calcAccruedInterestAndFees
    // / @param creditAccount Address of the Credit Account
    // / @param quotaInterest Total quota premiums accrued, computed elsewhere
    // / @return debt The debt principal
    // / @return accruedInterest Accrued interest
    // / @return accruedFees Accrued interest and protocol fees
    function calcAccruedInterestAndFees(CollateralDebtData memory collateralDebtData, uint16 feeInterest)
        internal
        pure
        returns (uint256 accruedInterest, uint256 accruedFees)
    {
        // Interest is never stored and is always computed dynamically
        // as the difference between the current cumulative index of the pool
        // and the cumulative index recorded in the Credit Account
        accruedInterest = calcAccruedInterest(
            collateralDebtData.debt, collateralDebtData.cumulativeIndexLastUpdate, collateralDebtData.cumulativeIndexNow
        ) + collateralDebtData.cumulativeQuotaInterest; // F:[CM-49]

        // Fees are computed as a percentage of interest
        accruedFees = collateralDebtData.accruedInterest * feeInterest / PERCENTAGE_FACTOR; // F: [CM-49]
    }

    function calcTotalDebtUSD(
        CollateralDebtData memory collateralDebtData,
        address underlying,
        function (address, uint256, address) view returns(uint256) convertToUSDFn
    ) internal view returns (uint256 totalDebtUSD) {
        totalDebtUSD = convertToUSDFn(
            collateralDebtData._priceOracle,
            calcTotalDebt(collateralDebtData), // F: [CM-42]
            underlying
        );
    }

    function calcHealthFactor(CollateralDebtData memory collateralDebtData) internal pure returns (uint16 hf) {
        hf = uint16(collateralDebtData.twvUSD * PERCENTAGE_FACTOR / collateralDebtData.totalDebtUSD);
    }

    function calcTotalValueInUnderlying(
        CollateralDebtData memory collateralDebtData,
        address underlying,
        function (address, uint256, address) view returns(uint256) convertFromUSDFn
    ) internal view returns (uint256 totalValue) {
        totalValue = convertFromUSDFn(collateralDebtData._priceOracle, collateralDebtData.totalValueUSD, underlying); // F:[FA-41]
    }

    function calcCollateral(
        CollateralDebtData memory collateralDebtData,
        address creditAccount,
        address underlying,
        bool lazy,
        uint16 minHealthFactor,
        uint256[] memory collateralHints,
        function (uint256, bool) view returns (address, uint16) collateralTokensByMaskFn,
        function (address, uint256, address) view returns(uint256) convertToUSDFn
    ) internal view returns (uint256 totalValueUSD, uint256 twvUSD, uint256 tokensToDisable) {
        uint256 limit = lazy ? collateralDebtData.totalDebtUSD * minHealthFactor / PERCENTAGE_FACTOR : type(uint256).max;

        if (collateralDebtData.quotedTokens.length != 0) {
            uint256 underlyingPriceRAY = convertToUSDFn(collateralDebtData._priceOracle, RAY, underlying);

            (totalValueUSD, twvUSD) = calcQuotedTokensCollateral({
                collateralDebtData: collateralDebtData,
                creditAccount: creditAccount,
                underlyingPriceRAY: underlyingPriceRAY,
                limit: limit,
                convertToUSDFn: convertToUSDFn
            });

            if (twvUSD > limit) {
                return (totalValueUSD, twvUSD, 0);
            } else {
                unchecked {
                    limit -= twvUSD;
                }
            }
        }
        {
            uint256 tokensToCheckMask = collateralDebtData.enabledTokensMask.disable(collateralDebtData.quotedTokenMask);
            address priceOracle = collateralDebtData._priceOracle;
            uint256 tvDelta;
            uint256 twvDelta;

            (tvDelta, twvDelta, tokensToDisable) = calcNonQuotedTokensCollateral({
                tokensToCheckMask: tokensToCheckMask,
                priceOracle: priceOracle,
                creditAccount: creditAccount,
                limit: limit,
                collateralHints: collateralHints,
                collateralTokensByMaskFn: collateralTokensByMaskFn,
                convertToUSDFn: convertToUSDFn
            });
        }
    }

    function calcQuotedTokensCollateral(
        CollateralDebtData memory collateralDebtData,
        address creditAccount,
        uint256 underlyingPriceRAY,
        uint256 limit,
        function (address, uint256, address) view returns(uint256) convertToUSDFn
    ) internal view returns (uint256 totalValueUSD, uint256 twvUSD) {
        uint256 len = collateralDebtData.quotedTokens.length;
        address priceOracle = collateralDebtData._priceOracle;

        for (uint256 i; i < len;) {
            address token = collateralDebtData.quotedTokens[i];
            if (token == address(0)) break;
            {
                uint16 lt = collateralDebtData.quotedLts[i];
                uint256 quotaUSD = collateralDebtData.quotas[i] * underlyingPriceRAY / RAY;
                (uint256 valueUSD, uint256 weightedValueUSD,) = calcOneTokenCollateral({
                    priceOracle: priceOracle,
                    creditAccount: creditAccount,
                    token: token,
                    liquidationThreshold: lt,
                    quotaUSD: quotaUSD,
                    convertToUSDFn: convertToUSDFn
                });

                totalValueUSD += valueUSD;
                twvUSD += weightedValueUSD;
            }
            if (twvUSD >= limit) {
                return (totalValueUSD, twvUSD);
            }

            unchecked {
                ++i;
            }
        }
    }

    function calcNonQuotedTokensCollateral(
        address creditAccount,
        uint256 limit,
        uint256[] memory collateralHints,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        function (uint256, bool) view returns (address, uint16) collateralTokensByMaskFn,
        uint256 tokensToCheckMask,
        address priceOracle
    ) internal view returns (uint256 totalValueUSD, uint256 twvUSD, uint256 tokensToDisable) {
        uint256 len = collateralHints.length;

        address ca = creditAccount;
        // TODO: add test that we check all values and it's always reachable
        for (uint256 i; tokensToCheckMask != 0;) {
            uint256 tokenMask;
            unchecked {
                // TODO: add check for super long collateralnhints and for double masks
                tokenMask = (i < len) ? collateralHints[i] : 1 << (i - len); // F: [CM-68]
            }
            // CASE enabledTokensMask & tokenMask == 0 F:[CM-38]
            if (tokensToCheckMask & tokenMask != 0) {
                bool nonZero;
                {
                    uint256 valueUSD;
                    uint256 weightedValueUSD;
                    (valueUSD, weightedValueUSD, nonZero) = calcOneNonQuotedCollateral({
                        priceOracle: priceOracle,
                        creditAccount: ca,
                        tokenMask: tokenMask,
                        convertToUSDFn: convertToUSDFn,
                        collateralTokensByMaskFn: collateralTokensByMaskFn
                    });
                    totalValueUSD += valueUSD;
                    twvUSD += weightedValueUSD;
                }
                if (nonZero) {
                    // Full collateral check evaluates a Credit Account's health factor lazily;
                    // Once the TWV computed thus far exceeds the debt, the check is considered
                    // successful, and the function returns without evaluating any further collateral
                    if (twvUSD >= limit) {
                        break;
                    }
                    // Zero-balance tokens are disabled; this is done by flipping the
                    // bit in enabledTokensMask, which is then written into storage at the
                    // very end, to avoid redundant storage writes
                } else {
                    tokensToDisable |= tokenMask;
                }
            }
            tokensToCheckMask = tokensToCheckMask.disable(tokenMask);

            unchecked {
                ++i;
            }
        }
    }

    function calcOneNonQuotedCollateral(
        address creditAccount,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        function (uint256, bool) view returns (address, uint16) collateralTokensByMaskFn,
        uint256 tokenMask,
        address priceOracle
    ) internal view returns (uint256 valueUSD, uint256 weightedValueUSD, bool nonZeroBalance) {
        (address token, uint16 liquidationThreshold) = collateralTokensByMaskFn(tokenMask, true);

        (valueUSD, weightedValueUSD, nonZeroBalance) = calcOneTokenCollateral({
            priceOracle: priceOracle,
            creditAccount: creditAccount,
            token: token,
            liquidationThreshold: liquidationThreshold,
            quotaUSD: type(uint256).max,
            convertToUSDFn: convertToUSDFn
        });
    }

    function calcOneTokenCollateral(
        address creditAccount,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        address priceOracle,
        address token,
        uint16 liquidationThreshold,
        uint256 quotaUSD
    ) internal view returns (uint256 valueUSD, uint256 weightedValueUSD, bool nonZeroBalance) {
        uint256 balance = IERC20Helper.balanceOf(token, creditAccount);

        // Collateral calculations are only done if there is a non-zero balance
        if (balance > 1) {
            valueUSD = convertToUSDFn(priceOracle, balance, token);
            weightedValueUSD = Math.min(valueUSD, quotaUSD) * liquidationThreshold / PERCENTAGE_FACTOR;
            nonZeroBalance = true;
        }
    }

    /// BALANCES

    /// @param creditAccount Credit Account to compute balances for
    function storeBalances(address creditAccount, Balance[] memory desired)
        internal
        view
        returns (Balance[] memory expected)
    {
        // Retrieves the balance list from calldata

        expected = desired; // F:[FA-45]
        uint256 len = expected.length; // F:[FA-45]

        for (uint256 i = 0; i < len;) {
            expected[i].balance += IERC20Helper.balanceOf(expected[i].token, creditAccount); // F:[FA-45]
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Compares current balances to previously saved expected balances.
    /// Reverts if at least one balance is lower than expected
    /// @param creditAccount Credit Account to check
    /// @param expected Expected balances after all operations

    function compareBalances(address creditAccount, Balance[] memory expected) internal view {
        uint256 len = expected.length; // F:[FA-45]
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                if (IERC20Helper.balanceOf(expected[i].token, creditAccount) < expected[i].balance) {
                    revert BalanceLessThanMinimumDesiredException(expected[i].token);
                } // F:[FA-45]
            }
        }
    }

    function storeForbiddenBalances(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256 forbiddenTokenMask,
        function (uint256) view returns (address) getTokenByMaskFn
    ) internal view returns (uint256[] memory forbiddenBalances) {
        uint256 forbiddenTokensOnAccount = enabledTokensMask & forbiddenTokenMask;

        if (forbiddenTokensOnAccount != 0) {
            forbiddenBalances = new uint256[](forbiddenTokensOnAccount.calcEnabledTokens());
            unchecked {
                uint256 i;
                for (uint256 tokenMask = 1; tokenMask < forbiddenTokensOnAccount; tokenMask <<= 1) {
                    if (forbiddenTokensOnAccount & tokenMask != 0) {
                        address token = getTokenByMaskFn(tokenMask);
                        forbiddenBalances[i] = IERC20Helper.balanceOf(token, creditAccount);
                        ++i;
                    }
                }
            }
        }
    }

    function checkForbiddenBalances(
        address creditAccount,
        uint256 enabledTokensMaskBefore,
        uint256 enabledTokensMaskAfter,
        uint256[] memory forbiddenBalances,
        uint256 forbiddenTokenMask,
        function (uint256) view returns (address) getTokenByMaskFn
    ) internal view {
        uint256 forbiddenTokensOnAccount = enabledTokensMaskAfter & forbiddenTokenMask;
        if (forbiddenTokensOnAccount == 0) return;

        uint256 forbiddenTokensOnAccountBefore = enabledTokensMaskBefore & forbiddenTokenMask;
        if (forbiddenTokensOnAccount & ~forbiddenTokensOnAccountBefore != 0) revert ForbiddenTokensException();

        unchecked {
            uint256 i;
            for (uint256 tokenMask = 1; tokenMask < forbiddenTokensOnAccountBefore; tokenMask <<= 1) {
                if (forbiddenTokensOnAccountBefore & tokenMask != 0) {
                    if (forbiddenTokensOnAccount & tokenMask != 0) {
                        address token = getTokenByMaskFn(tokenMask);
                        uint256 balance = IERC20Helper.balanceOf(token, creditAccount);
                        if (balance > forbiddenBalances[i]) {
                            revert ForbiddenTokensException();
                        }
                    }

                    ++i;
                }
            }
        }
    }
}
