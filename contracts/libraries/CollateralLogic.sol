// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20Helper} from "./IERC20Helper.sol";
import {CollateralDebtData} from "../interfaces/ICreditManagerV3.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

import {BitMask} from "./BitMask.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RAY} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

/// @title Collateral logic Library
/// @dev Implements functions that compute value of collateral on a Credit Account
library CollateralLogic {
    using BitMask for uint256;

    /// @dev Computes USD-denominated total value and TWV of a Credit Account
    /// @param collateralDebtData A struct containing data on the Credit Account's debt and quoted tokens
    ///                           Note: Debt and quoted token data are filled in by `CreditManager.calcDebtAndCollateral()` with
    ///                           DEBT_ONLY task or higher
    /// @param creditAccount Credit Account to compute collateral for
    /// @param underlying The underlying token of the corresponding Credit Manager
    /// @param lazy Whether to stop computing collateral on reaching the minimal HF threshold
    /// @param minHealthFactor The minimal health factor to reach before stopping (if lazy)
    /// @param collateralHints Array of token masks denoting the order to check collateral in.
    ///                        Note that this is only used for non-quoted tokens
    /// @param collateralTokenByMaskFn A function to return collateral token data by its mask. Must accept inputs:
    ///                                * uint256 mask - mask of the token
    ///                                * bool computeLT - whether to compute the token's LT
    /// @param convertToUSDFn A function to return collateral value in USD. Must accept inputs:
    ///                       * address priceOracle - price oracle to convert assets in
    ///                       * uint256 amount - amount of token to convert
    ///                       * address token - token to convert
    /// @param priceOracle Price Oracle to convert assets in. This is always passed to `convertToUSDFn`
    /// @return totalValueUSD Total value of Credit Account's assets (NB: an underestimated value can be returned if `lazy == true`)
    /// @return twvUSD Total LT-weighted value of Credit Account's assets (NB: an underestimated value can be returned if `lazy == true`)
    /// @return tokensToDisable Mask of tokens that have zero balances and need to be disabled
    function calcCollateral(
        CollateralDebtData memory collateralDebtData,
        address creditAccount,
        address underlying,
        bool lazy,
        uint16 minHealthFactor,
        uint256[] memory collateralHints,
        function (uint256, bool) view returns (address, uint16) collateralTokenByMaskFn,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        address priceOracle
    ) internal view returns (uint256 totalValueUSD, uint256 twvUSD, uint256 tokensToDisable) {
        /// The limit is a TWV threshold at which lazy computation stops. Normally, it happens when TWV
        /// exceeds the total debt, but the user can also configure a custom HF threshold (above 1),
        /// in order to maintain a desired level of position health
        uint256 limit = lazy ? collateralDebtData.totalDebtUSD * minHealthFactor / PERCENTAGE_FACTOR : type(uint256).max;

        //
        // QUOTED TOKENS COMPUTATION
        //
        if (collateralDebtData.quotedTokens.length != 0) {
            /// The underlying price is required for quotas but only needs to be computed once
            uint256 underlyingPriceRAY = convertToUSDFn(priceOracle, RAY, underlying);

            (totalValueUSD, twvUSD) = calcQuotedTokensCollateral({
                collateralDebtData: collateralDebtData,
                creditAccount: creditAccount,
                underlyingPriceRAY: underlyingPriceRAY,
                limit: limit,
                convertToUSDFn: convertToUSDFn,
                priceOracle: priceOracle
            }); // U:[CLL-5]

            if (twvUSD >= limit) {
                return (totalValueUSD, twvUSD, 0); // U:[CLL-5]
            } else {
                unchecked {
                    limit -= twvUSD; // U:[CLL-5]
                }
            }
        }

        //
        // NON QUOTED TOKENS COMPUTATION
        //
        {
            uint256 tokensToCheckMask =
                collateralDebtData.enabledTokensMask.disable(collateralDebtData.quotedTokensMask); // U:[CLL-5]

            uint256 tvDelta;
            uint256 twvDelta;

            (tvDelta, twvDelta, tokensToDisable) = calcNonQuotedTokensCollateral({
                tokensToCheckMask: tokensToCheckMask,
                priceOracle: priceOracle,
                creditAccount: creditAccount,
                limit: limit,
                collateralHints: collateralHints,
                collateralTokenByMaskFn: collateralTokenByMaskFn,
                convertToUSDFn: convertToUSDFn
            }); // U:[CLL-5]

            totalValueUSD += tvDelta; // U:[CLL-5]
            twvUSD += twvDelta; // U:[CLL-5]
        }
    }

    /// @dev Computes USD value of quoted tokens an a Credit Account
    /// @param collateralDebtData A struct containing information on debt and collateral
    ///                           Quota-related data must be filled in for this function to work
    /// @param creditAccount A Credit Account to compute value for
    /// @param underlyingPriceRAY Price of the underlying token, in RAY format
    /// @param limit TWV threshold to stop computing at
    /// @param convertToUSDFn A function to return collateral value in USD. Must accept inputs:
    ///                       * address priceOracle - price oracle to convert assets in
    ///                       * uint256 amount - amount of token to convert
    ///                       * address token - token to convert
    /// @param priceOracle Price Oracle to convert assets in. This is always passed to `convertToUSDFn`
    /// @return totalValueUSD Total value of Credit Account's assets (NB: an underestimated value can be returned if `lazy == true`)
    /// @return twvUSD Total LT-weighted value of Credit Account's assets (NB: an underestimated value can be returned if `lazy == true`)
    function calcQuotedTokensCollateral(
        CollateralDebtData memory collateralDebtData,
        address creditAccount,
        uint256 underlyingPriceRAY,
        uint256 limit,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        address priceOracle
    ) internal view returns (uint256 totalValueUSD, uint256 twvUSD) {
        uint256 len = collateralDebtData.quotedTokens.length; // U:[CLL-4]

        for (uint256 i; i < len;) {
            address token = collateralDebtData.quotedTokens[i]; // U:[CLL-4]
            /// The quoted token array is either 0-length (in which case this function is not entered),
            /// or has length of maxEnabledTokens. Therefore, encountering address(0) means that all
            /// quoted tokens have been processed
            if (token == address(0)) break; // U:[CLL-4]
            {
                uint16 liquidationThreshold = collateralDebtData.quotedLts[i]; // U:[CLL-4]
                /// Since Chainlink oracles always price token amounts linearly, the price only
                /// needs to be queried once, and then quota values can be computed locally
                uint256 quotaUSD = collateralDebtData.quotas[i] * underlyingPriceRAY / RAY; // U:[CLL-4]

                (uint256 valueUSD, uint256 weightedValueUSD,) = calcOneTokenCollateral({
                    priceOracle: priceOracle,
                    creditAccount: creditAccount,
                    token: token,
                    liquidationThreshold: liquidationThreshold,
                    quotaUSD: quotaUSD,
                    convertToUSDFn: convertToUSDFn
                }); // U:[CLL-4]

                totalValueUSD += valueUSD; // U:[CLL-4]
                twvUSD += weightedValueUSD; // U:[CLL-4]
            }
            if (twvUSD >= limit) {
                return (totalValueUSD, twvUSD); // U:[CLL-4]
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @dev Computes USD value of non-quoted tokens an a Credit Account
    /// @param creditAccount A Credit Account to compute value for
    /// @param limit TWV threshold to stop computing at
    /// @param collateralHints Array of token masks denoting the order to check collateral in.
    /// @param convertToUSDFn A function to return collateral value in USD. Must accept inputs:
    ///                       * address priceOracle - price oracle to convert assets in
    ///                       * uint256 amount - amount of token to convert
    ///                       * address token - token to convert
    /// @param collateralTokenByMaskFn A function to return collateral token data by its mask. Must accept inputs:
    ///                                * uint256 mask - mask of the token
    ///                                * bool computeLT - whether to compute the token's LT
    /// @param tokensToCheckMask Mask of tokens to consider during computation (should be equal to enabled token mask with
    ///                          quoted tokens removed, since they were processed earlier)
    /// @param priceOracle Price Oracle to convert assets in. This is always passed to `convertToUSDFn`
    /// @return totalValueUSD Total value of Credit Account's assets (NB: an underestimated value can be returned if `lazy == true`)
    /// @return twvUSD Total LT-weighted value of Credit Account's assets (NB: an underestimated value can be returned if `lazy == true`)
    /// @return tokensToDisable Mask of tokens that have zero balances and need to be disabled
    function calcNonQuotedTokensCollateral(
        address creditAccount,
        uint256 limit,
        uint256[] memory collateralHints,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        function (uint256, bool) view returns (address, uint16) collateralTokenByMaskFn,
        uint256 tokensToCheckMask,
        address priceOracle
    ) internal view returns (uint256 totalValueUSD, uint256 twvUSD, uint256 tokensToDisable) {
        uint256 len = collateralHints.length; // U:[CLL-3]

        address ca = creditAccount; // U:[CLL-3]
        for (uint256 i; tokensToCheckMask != 0;) {
            uint256 tokenMask;

            /// To ensure that no erroneous mask can be passed in collateralHints
            /// (e.g., masks with more than 1 bit enabled), `collateralTokenByMaskFn`
            /// must revert upon encountering an unknown mask
            unchecked {
                tokenMask = (i < len) ? collateralHints[i] : 1 << (i - len); // U:[CLL-3]
            }

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
                        collateralTokenByMaskFn: collateralTokenByMaskFn
                    }); // U:[CLL-3]
                    totalValueUSD += valueUSD; // U:[CLL-3]
                    twvUSD += weightedValueUSD; // U:[CLL-3]
                }
                if (nonZero) {
                    if (twvUSD >= limit) {
                        break; // U:[CLL-3]
                    }
                } else {
                    /// Zero balance tokens are recorded and removed from enabledTokenMask
                    /// after the collateral computation
                    tokensToDisable |= tokenMask; // U:[CLL-3]
                }
            }
            tokensToCheckMask = tokensToCheckMask.disable(tokenMask); // U:[CLL-3]

            unchecked {
                ++i;
            }
        }
    }

    /// @dev Computes value of a single non-quoted asset on a Credit Account
    /// @param creditAccount Address of the Credit Account to compute value for
    /// @param convertToUSDFn A function to return collateral value in USD. Must accept inputs:
    ///                       * address priceOracle - price oracle to convert assets in
    ///                       * uint256 amount - amount of token to convert
    ///                       * address token - token to convert
    /// @param collateralTokenByMaskFn A function to return collateral token data by its mask. Must accept inputs:
    ///                                * uint256 mask - mask of the token
    /// @param tokenMask Mask of the token to compute value for
    /// @param priceOracle Price Oracle to convert assets in. This is always passed to `convertToUSDFn`
    /// @return valueUSD Value of the asset
    /// @return weightedValueUSD LT-weighted value of the asset
    /// @return nonZeroBalance Whether the token has a non-zero balance
    function calcOneNonQuotedCollateral(
        address creditAccount,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        function (uint256, bool) view returns (address, uint16) collateralTokenByMaskFn,
        uint256 tokenMask,
        address priceOracle
    ) internal view returns (uint256 valueUSD, uint256 weightedValueUSD, bool nonZeroBalance) {
        (address token, uint16 liquidationThreshold) = collateralTokenByMaskFn(tokenMask, true); // U:[CLL-2]

        /// The general function accept quota value as a parameter, which will always
        /// be uint256.max for non-quoted tokens
        (valueUSD, weightedValueUSD, nonZeroBalance) = calcOneTokenCollateral({
            priceOracle: priceOracle,
            creditAccount: creditAccount,
            token: token,
            liquidationThreshold: liquidationThreshold,
            quotaUSD: type(uint256).max,
            convertToUSDFn: convertToUSDFn
        }); // U:[CLL-2]
    }

    /// @dev Computes value of a single asset on a Credit Account
    /// @param creditAccount Address of the Credit Account to compute value for
    /// @param convertToUSDFn A function to return collateral value in USD. Must accept inputs:
    ///                       * address priceOracle - price oracle to convert assets in
    ///                       * uint256 amount - amount of token to convert
    ///                       * address token - token to convert
    /// @param priceOracle Price Oracle to convert assets in. This is always passed to `convertToUSDFn`
    /// @param token Address of the token
    /// @param liquidationThreshold LT of the token
    /// @param quotaUSD USD-denominated quota of a token (always uint256.max for non-quoted tokens)
    /// @return valueUSD Value of the asset
    /// @return weightedValueUSD LT-weighted value of the asset
    /// @return nonZeroBalance Whether the token has a non-zero balance
    function calcOneTokenCollateral(
        address creditAccount,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        address priceOracle,
        address token,
        uint16 liquidationThreshold,
        uint256 quotaUSD
    ) internal view returns (uint256 valueUSD, uint256 weightedValueUSD, bool nonZeroBalance) {
        uint256 balance = IERC20Helper.balanceOf(token, creditAccount); // U:[CLL-1]

        /// Collateral computations are skipped if the balance is 0
        /// and nonZeroBalance will be equal to false
        if (balance > 1) {
            unchecked {
                valueUSD = convertToUSDFn(priceOracle, balance - 1, token); // U:[CLL-1]
            }
            /// For quoted tokens, the value of an asset that is counted towards collateral is capped
            /// by the value of the quota set for the account. For more info in quotas, see `PoolQuotaKeeper` and `QuotasLogic`
            weightedValueUSD = Math.min(valueUSD, quotaUSD) * liquidationThreshold / PERCENTAGE_FACTOR; // U:[CLL-1]
            nonZeroBalance = true; // U:[CLL-1]
        }
    }
}
