// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {CollateralTokenData} from "../interfaces/ICreditManagerV3.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {PERCENTAGE_FACTOR, RAY} from "../libraries/Constants.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Collateral logic Library
/// @notice Implements functions that compute value of collateral on a credit account
library CollateralLogic {
    using SafeERC20 for IERC20;

    /// @dev Computes USD-denominated total value and TWV of a credit account.
    ///      If finite TWV target is specified, the function will stop processing tokens after cumulative TWV reaches
    ///      the target, in which case the returned values might be smaller than actual collateral.
    ///      This is useful to check whether account is sufficiently collateralized.
    /// @param creditAccount Credit account to compute collateral for
    /// @param underlying The underlying token of the corresponding credit manager
    /// @param ltUnderlying The underlying token's LT
    /// @param twvUSDTarget Target twvUSD value to stop calculation after
    /// @param convertToUSDFn A function that returns token value in USD and accepts the following inputs:
    ///        * `priceOracle` - price oracle to convert assets in
    ///        * `amount` - amount of token to convert
    ///        * `token` - token to convert
    /// @param priceOracle Price oracle to convert assets, passed to `convertToUSDFn`
    /// @return totalValueUSD Total value of credit account's assets
    /// @return twvUSD Total LT-weighted value of credit account's assets
    /// @custom:tests U:[CLL-2]
    function calcCollateral(
        CollateralTokenData[] memory collateralTokens,
        address creditAccount,
        address underlying,
        uint16 ltUnderlying,
        uint256 twvUSDTarget,
        function(address, uint256, address) view returns (uint256) convertToUSDFn,
        address priceOracle
    ) internal view returns (uint256 totalValueUSD, uint256 twvUSD) {
        uint256 len = collateralTokens.length;
        for (uint256 i; i < len;) {
            // puts variables on top of the stack to avoid the "stack too deep" error
            address _quotedToken = collateralTokens[i].token;
            uint16 _liquidationThreshold = collateralTokens[i].lt;
            address _creditAccount = creditAccount;

            (uint256 valueUSD, uint256 weightedValueUSD) = calcOneTokenCollateral({
                token: _quotedToken,
                creditAccount: _creditAccount,
                liquidationThreshold: _liquidationThreshold,
                priceOracle: priceOracle,
                convertToUSDFn: convertToUSDFn
            });
            totalValueUSD += valueUSD;
            twvUSD += weightedValueUSD;

            if (twvUSD >= twvUSDTarget) return (totalValueUSD, twvUSD);
            unchecked {
                ++i;
            }
        }

        (uint256 underlyingValueUSD, uint256 underlyingWeightedValueUSD) = calcOneTokenCollateral({
            token: underlying,
            creditAccount: creditAccount,
            liquidationThreshold: ltUnderlying,
            priceOracle: priceOracle,
            convertToUSDFn: convertToUSDFn
        });
        totalValueUSD += underlyingValueUSD;
        twvUSD += underlyingWeightedValueUSD;
    }

    /// @dev Computes USD value of a single asset on a credit account
    /// @param creditAccount Address of the credit account
    /// @param convertToUSDFn Function to convert asset amounts to USD
    /// @param priceOracle Address of the price oracle
    /// @param token Address of the token
    /// @param liquidationThreshold LT of the token
    /// @return valueUSD Value of the token
    /// @return weightedValueUSD LT-weighted value of the token
    function calcOneTokenCollateral(
        address creditAccount,
        function(address, uint256, address) view returns (uint256) convertToUSDFn,
        address priceOracle,
        address token,
        uint16 liquidationThreshold
    ) internal view returns (uint256 valueUSD, uint256 weightedValueUSD) {
        uint256 balance = IERC20(token).safeBalanceOf(creditAccount);

        if (balance != 0) {
            valueUSD = convertToUSDFn(priceOracle, balance, token);
            weightedValueUSD = valueUSD * liquidationThreshold / PERCENTAGE_FACTOR;
        }
    }
}
