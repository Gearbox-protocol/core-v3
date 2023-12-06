// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {CollateralDebtData} from "../interfaces/ICreditManagerV3.sol";
import {PERCENTAGE_FACTOR, RAY} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

import {BitMask} from "./BitMask.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Collateral logic Library
/// @notice Implements functions that compute value of collateral on a credit account
library CollateralLogic {
    using BitMask for uint256;
    using SafeERC20 for IERC20;

    /// @dev Computes USD-denominated total value and TWV of a credit account.
    ///      If finite TWV target is specified, the function will stop processing tokens after cumulative TWV reaches
    ///      the target, in which case the returned values will be smaller than actual collateral.
    ///      This is useful to check whether account is sufficiently collateralized. To speed up this check, collateral
    ///      hints can be used to specify the order to scan tokens in.
    /// @param collateralDebtData See `CollateralDebtData` (must have enabled and quoted tokens filled)
    /// @param creditAccount Credit account to compute collateral for
    /// @param underlying The underlying token of the corresponding credit manager
    /// @param twvUSDTarget Target twvUSD value to stop calculation after
    /// @param collateralHints Array of token masks denoting the order to scan tokens in
    /// @param quotasPacked Array of packed values (quota, LT), in the same order as `collateralDebtData.quotedTokens`
    /// @param collateralTokenByMaskFn A function that returns collateral token data by its mask. Must accept inputs:
    ///        * `mask` - mask of the token
    ///        * `computeLT` - whether to compute the token's LT
    /// @param convertToUSDFn A function that returns token value in USD and accepts the following inputs:
    ///        * `priceOracle` - price oracle to convert assets in
    ///        * `amount` - amount of token to convert
    ///        * `token` - token to convert
    /// @param priceOracle Price oracle to convert assets, passed to `convertToUSDFn`
    /// @return totalValueUSD Total value of credit account's assets
    /// @return twvUSD Total LT-weighted value of credit account's assets
    /// @return tokensToDisable Mask of non-quoted tokens that have zero balances and can be disabled
    function calcCollateral(
        CollateralDebtData memory collateralDebtData,
        address creditAccount,
        address underlying,
        uint256 twvUSDTarget,
        uint256[] memory collateralHints,
        uint256[] memory quotasPacked,
        function (uint256, bool) view returns (address, uint16) collateralTokenByMaskFn,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        address priceOracle
    ) internal view returns (uint256 totalValueUSD, uint256 twvUSD, uint256 tokensToDisable) {
        // Quoted tokens collateral value
        if (collateralDebtData.quotedTokens.length != 0) {
            // The underlying price is required for quotas but only needs to be computed once
            uint256 underlyingPriceRAY = convertToUSDFn(priceOracle, RAY, underlying);

            (totalValueUSD, twvUSD) = calcQuotedTokensCollateral({
                quotedTokens: collateralDebtData.quotedTokens,
                quotasPacked: quotasPacked,
                creditAccount: creditAccount,
                underlyingPriceRAY: underlyingPriceRAY,
                twvUSDTarget: twvUSDTarget,
                convertToUSDFn: convertToUSDFn,
                priceOracle: priceOracle
            }); // U:[CLL-5]

            if (twvUSD >= twvUSDTarget) {
                return (totalValueUSD, twvUSD, 0); // U:[CLL-5]
            } else {
                unchecked {
                    twvUSDTarget -= twvUSD; // U:[CLL-5]
                }
            }
        }

        // Non-quoted tokens collateral value
        {
            uint256 tokensToCheckMask =
                collateralDebtData.enabledTokensMask.disable(collateralDebtData.quotedTokensMask); // U:[CLL-5]

            uint256 tvDelta;
            uint256 twvDelta;

            (tvDelta, twvDelta, tokensToDisable) = calcNonQuotedTokensCollateral({
                tokensToCheckMask: tokensToCheckMask,
                priceOracle: priceOracle,
                creditAccount: creditAccount,
                twvUSDTarget: twvUSDTarget,
                collateralHints: collateralHints,
                collateralTokenByMaskFn: collateralTokenByMaskFn,
                convertToUSDFn: convertToUSDFn
            }); // U:[CLL-5]

            totalValueUSD += tvDelta; // U:[CLL-5]
            twvUSD += twvDelta; // U:[CLL-5]
        }
    }

    /// @dev Computes USD value of quoted tokens on a credit account
    /// @param quotedTokens Array of quoted tokens on the account
    /// @param quotasPacked Array of (quota, LT) tuples packed into uint256
    /// @param creditAccount Address of the credit account
    /// @param underlyingPriceRAY USD price of 1 RAY of underlying
    /// @param twvUSDTarget The twvUSD threshold to stop the computation at
    /// @param convertToUSDFn Function to convert asset amounts to USD
    /// @param priceOracle Address of the price oracle
    /// @return totalValueUSD Total value of credit account's quoted assets
    /// @return twvUSD Total LT-weighted value of credit account's quoted assets
    function calcQuotedTokensCollateral(
        address[] memory quotedTokens,
        uint256[] memory quotasPacked,
        address creditAccount,
        uint256 underlyingPriceRAY,
        uint256 twvUSDTarget,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        address priceOracle
    ) internal view returns (uint256 totalValueUSD, uint256 twvUSD) {
        uint256 len = quotedTokens.length; // U:[CLL-4]

        for (uint256 i; i < len;) {
            address token = quotedTokens[i]; // U:[CLL-4]

            {
                (uint256 quota, uint16 liquidationThreshold) = unpackQuota(quotasPacked[i]); // U:[CLL-4]
                uint256 quotaUSD = quota * underlyingPriceRAY / RAY; // U:[CLL-4]

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
            if (twvUSD >= twvUSDTarget) {
                return (totalValueUSD, twvUSD); // U:[CLL-4]
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @dev Computes USD value of non-quoted tokens on a credit account
    /// @param creditAccount Address of the credit account
    /// @param twvUSDTarget The twvUSD threshold to stop the computation at
    /// @param collateralHints Array of token masks for order of priority during collateral computation
    /// @param convertToUSDFn Function to convert asset amounts to USD
    /// @param collateralTokenByMaskFn Function to retrieve the token's address and LT by its mask
    /// @param tokensToCheckMask Mask of tokens that need to be included into the computation
    /// @param priceOracle Address of the price oracle
    /// @return totalValueUSD Total value of credit account's quoted assets
    /// @return twvUSD Total LT-weighted value of credit account's quoted assets
    /// @return tokensToDisable Mask of non-quoted tokens that have zero balances and can be disabled
    function calcNonQuotedTokensCollateral(
        address creditAccount,
        uint256 twvUSDTarget,
        uint256[] memory collateralHints,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        function (uint256, bool) view returns (address, uint16) collateralTokenByMaskFn,
        uint256 tokensToCheckMask,
        address priceOracle
    ) internal view returns (uint256 totalValueUSD, uint256 twvUSD, uint256 tokensToDisable) {
        uint256 len = collateralHints.length; // U:[CLL-3]

        address ca = creditAccount; // U:[CLL-3]
        uint256 i;
        while (tokensToCheckMask != 0) {
            uint256 tokenMask;

            if (i < len) {
                tokenMask = collateralHints[i];
                unchecked {
                    ++i;
                }
                if (tokensToCheckMask & tokenMask == 0) continue;
            } else {
                tokenMask = tokensToCheckMask & uint256(-int256(tokensToCheckMask));
            }

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
                if (twvUSD >= twvUSDTarget) {
                    break; // U:[CLL-3]
                }
            } else {
                // Zero balance tokens are disabled after the collateral computation
                tokensToDisable = tokensToDisable.enable(tokenMask); // U:[CLL-3]
            }
            tokensToCheckMask = tokensToCheckMask.disable(tokenMask);
        }
    }

    /// @dev Computes value of a single non-quoted asset on a credit account
    /// @param creditAccount Address of the credit account
    /// @param convertToUSDFn Function to convert asset amounts to USD
    /// @param collateralTokenByMaskFn Function to retrieve the token's address and LT by its mask
    /// @param tokenMask Mask of the token
    /// @param priceOracle Address of the price oracle
    /// @return valueUSD Value of the token
    /// @return weightedValueUSD LT-weighted value of the token
    /// @return nonZeroBalance Whether the token has a zero balance
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

    /// @dev Computes USD value of a single asset on a credit account
    /// @param creditAccount Address of the credit account
    /// @param convertToUSDFn Function to convert asset amounts to USD
    /// @param priceOracle Address of the price oracle
    /// @param token Address of the token
    /// @param liquidationThreshold LT of the token
    /// @param quotaUSD Quota of the token converted to USD
    /// @return valueUSD Value of the token
    /// @return weightedValueUSD LT-weighted value of the token
    /// @return nonZeroBalance Whether the token has a zero balance
    function calcOneTokenCollateral(
        address creditAccount,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        address priceOracle,
        address token,
        uint16 liquidationThreshold,
        uint256 quotaUSD
    ) internal view returns (uint256 valueUSD, uint256 weightedValueUSD, bool nonZeroBalance) {
        uint256 balance = IERC20(token).safeBalanceOf({account: creditAccount}); // U:[CLL-1]

        if (balance > 1) {
            unchecked {
                valueUSD = convertToUSDFn(priceOracle, balance - 1, token); // U:[CLL-1]
            }
            weightedValueUSD = Math.min(valueUSD * liquidationThreshold / PERCENTAGE_FACTOR, quotaUSD); // U:[CLL-1]
            nonZeroBalance = true; // U:[CLL-1]
        }
    }

    /// @dev Packs quota and LT into one word
    function packQuota(uint96 quota, uint16 lt) internal pure returns (uint256) {
        return (uint256(lt) << 96) | quota;
    }

    /// @dev Unpacks one word into quota and LT
    function unpackQuota(uint256 packedQuota) internal pure returns (uint256 quota, uint16 lt) {
        lt = uint16(packedQuota >> 96);
        quota = uint96(packedQuota);
    }
}
