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
library CollateralLogic {
    using BitMask for uint256;

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
        uint256 limit = lazy ? collateralDebtData.totalDebtUSD * minHealthFactor / PERCENTAGE_FACTOR : type(uint256).max;

        if (collateralDebtData.quotedTokens.length != 0) {
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

        // @notice Computes non-quotes collateral

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
            if (token == address(0)) break; // U:[CLL-4]
            {
                uint16 liquidationThreshold = collateralDebtData.quotedLts[i]; // U:[CLL-4]
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
        // TODO: add test that we check all values and it's always reachable
        for (uint256 i; tokensToCheckMask != 0;) {
            uint256 tokenMask;
            unchecked {
                // TODO: add check for super long collateralnhints and for double masks
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
                    // Full collateral check evaluates a Credit Account's health factor lazily;
                    // Once the TWV computed thus far exceeds the debt, the check is considered
                    // successful, and the function returns without evaluating any further collateral
                    if (twvUSD >= limit) {
                        break; // U:[CLL-3]
                    }
                    // Zero-balance tokens are disabled; this is done by flipping the
                    // bit in enabledTokensMask, which is then written into storage at the
                    // very end, to avoid redundant storage writes
                } else {
                    tokensToDisable |= tokenMask; // U:[CLL-3]
                }
            }
            tokensToCheckMask = tokensToCheckMask.disable(tokenMask); // U:[CLL-3]

            unchecked {
                ++i;
            }
        }
    }

    function calcOneNonQuotedCollateral(
        address creditAccount,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        function (uint256, bool) view returns (address, uint16) collateralTokenByMaskFn,
        uint256 tokenMask,
        address priceOracle
    ) internal view returns (uint256 valueUSD, uint256 weightedValueUSD, bool nonZeroBalance) {
        (address token, uint16 liquidationThreshold) = collateralTokenByMaskFn(tokenMask, true); // U:[CLL-2]

        (valueUSD, weightedValueUSD, nonZeroBalance) = calcOneTokenCollateral({
            priceOracle: priceOracle,
            creditAccount: creditAccount,
            token: token,
            liquidationThreshold: liquidationThreshold,
            quotaUSD: type(uint256).max,
            convertToUSDFn: convertToUSDFn
        }); // U:[CLL-2]
    }

    function calcOneTokenCollateral(
        address creditAccount,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        address priceOracle,
        address token,
        uint16 liquidationThreshold,
        uint256 quotaUSD
    ) internal view returns (uint256 valueUSD, uint256 weightedValueUSD, bool nonZeroBalance) {
        uint256 balance = IERC20Helper.balanceOf(token, creditAccount); // U:[CLL-1]

        // Collateral calculations are only done if there is a non-zero balance
        if (balance > 1) {
            unchecked {
                valueUSD = convertToUSDFn(priceOracle, balance - 1, token); // U:[CLL-1]
            }
            weightedValueUSD = Math.min(valueUSD, quotaUSD) * liquidationThreshold / PERCENTAGE_FACTOR; // U:[CLL-1]
            nonZeroBalance = true; // U:[CLL-1]
        }
    }
}
