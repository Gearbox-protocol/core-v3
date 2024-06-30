// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PERCENTAGE_FACTOR, RAY} from "../libraries/Constants.sol";

/// @title  Collateral logic library
/// @notice Implements functions that compute value of collateral on a credit account
library CollateralLogic {
    using SafeERC20 for IERC20;

    /// @notice Computes USD-denominated total value and TWV of a credit account.
    ///         If finite TWV target is specified, the function will stop processing tokens after cumulative TWV
    ///         reaches the target, in which case the returned values might be smaller than actual collateral.
    ///         This is useful to check whether account is sufficiently collateralized.
    /// @param  quotedTokens Array of quoted tokens on the credit account
    /// @param  quotasPacked Array of packed values (quota, LT), in the same order as `quotedTokens`
    /// @param  creditAccount Credit account to compute collateral for
    /// @param  underlying The underlying token of the corresponding credit manager
    /// @param  ltUnderlying The underlying token's LT
    /// @param  twvUSDTarget Target twvUSD value to stop calculation after
    /// @param  convertToUSDFn A function that returns token value in USD and accepts the following inputs:
    ///         * `priceOracle` - price oracle to convert assets in
    ///         * `amount` - amount of token to convert
    ///         * `token` - token to convert
    /// @param  priceOracle Price oracle to convert assets, passed to `convertToUSDFn`
    /// @return totalValueUSD Total value of credit account's assets
    /// @return twvUSD Total LT-weighted value of credit account's assets
    /// @custom:tests U:[CLL-2]
    function calcCollateral(
        address[] memory quotedTokens,
        uint256[] memory quotasPacked,
        address creditAccount,
        address underlying,
        uint16 ltUnderlying,
        uint256 twvUSDTarget,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        address priceOracle
    ) internal view returns (uint256 totalValueUSD, uint256 twvUSD) {
        uint256 underlyingPriceRAY = convertToUSDFn(priceOracle, RAY, underlying);

        uint256 len = quotedTokens.length;
        for (uint256 i; i < len; ++i) {
            (uint256 quota, uint16 liquidationThreshold) = unpackQuota(quotasPacked[i]);

            // puts variables on top of the stack to avoid the "stack too deep" error
            address _quotedToken = quotedTokens[i];
            address _creditAccount = creditAccount;

            (uint256 valueUSD, uint256 weightedValueUSD) = calcOneTokenCollateral({
                token: _quotedToken,
                creditAccount: _creditAccount,
                liquidationThreshold: liquidationThreshold,
                quotaUSD: quota * underlyingPriceRAY / RAY,
                priceOracle: priceOracle,
                convertToUSDFn: convertToUSDFn
            });
            totalValueUSD += valueUSD;
            twvUSD += weightedValueUSD;

            if (twvUSD >= twvUSDTarget) return (totalValueUSD, twvUSD);
        }

        (uint256 underlyingValueUSD, uint256 underlyingWeightedValueUSD) = calcOneTokenCollateral({
            token: underlying,
            creditAccount: creditAccount,
            liquidationThreshold: ltUnderlying,
            quotaUSD: type(uint256).max,
            priceOracle: priceOracle,
            convertToUSDFn: convertToUSDFn
        });
        totalValueUSD += underlyingValueUSD;
        twvUSD += underlyingWeightedValueUSD;
    }

    /// @notice Computes USD value of a single asset on a credit account
    /// @param  creditAccount Address of the credit account
    /// @param  convertToUSDFn Function to convert asset amounts to USD
    /// @param  priceOracle Address of the price oracle
    /// @param  token Address of the token
    /// @param  liquidationThreshold LT of the token
    /// @param  quotaUSD Quota of the token converted to USD
    /// @return valueUSD Value of the token
    /// @return weightedValueUSD LT-weighted value of the token
    /// @custom:tests U:[CLL-1]
    function calcOneTokenCollateral(
        address creditAccount,
        function (address, uint256, address) view returns(uint256) convertToUSDFn,
        address priceOracle,
        address token,
        uint16 liquidationThreshold,
        uint256 quotaUSD
    ) internal view returns (uint256 valueUSD, uint256 weightedValueUSD) {
        uint256 balance = IERC20(token).safeBalanceOf(creditAccount);

        if (balance > 1) {
            valueUSD = convertToUSDFn(priceOracle, balance, token);
            weightedValueUSD = Math.min(valueUSD * liquidationThreshold / PERCENTAGE_FACTOR, quotaUSD);
        }
    }

    /// @notice Packs quota and LT into one word
    function packQuota(uint96 quota, uint16 lt) internal pure returns (uint256) {
        return (uint256(lt) << 96) | quota;
    }

    /// @notice Unpacks one word into quota and LT
    function unpackQuota(uint256 packedQuota) internal pure returns (uint256 quota, uint16 lt) {
        lt = uint16(packedQuota >> 96);
        quota = uint96(packedQuota);
    }
}
