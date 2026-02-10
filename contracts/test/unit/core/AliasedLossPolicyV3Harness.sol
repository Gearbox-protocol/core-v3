/*
// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AliasedLossPolicyV3} from "../../../core/AliasedLossPolicyV3.sol";
import {PriceFeedParams} from "../../../interfaces/IPriceOracleV3.sol";

/// @title Aliased Loss Policy V3 Harness
/// @notice Exposes internal functions for testing
contract AliasedLossPolicyV3Harness is AliasedLossPolicyV3 {
    using EnumerableSet for EnumerableSet.AddressSet;

    constructor(address pool_, address addressProvider_) AliasedLossPolicyV3(pool_, addressProvider_) {}

    function exposed_adjustForAliases(address creditAccount, uint256 twvUSD) external view returns (uint256) {
        return _adjustForAliases(creditAccount, twvUSD);
    }

    function exposed_getSharedInfo(address creditAccount) external view returns (SharedInfo memory) {
        return _getSharedInfo(creditAccount);
    }

    function exposed_getTokenInfo(address creditAccount, uint256 tokenMask, SharedInfo memory sharedInfo)
        external
        view
        returns (TokenInfo memory)
    {
        return _getTokenInfo(creditAccount, tokenMask, sharedInfo);
    }

    function exposed_getWeightedValueUSD(
        TokenInfo memory tokenInfo,
        SharedInfo memory sharedInfo,
        PriceFeedType priceFeedType
    ) external view returns (uint256) {
        return _getWeightedValueUSD(tokenInfo, sharedInfo, priceFeedType);
    }

    function exposed_convertToUSDAlias(PriceFeedParams memory aliasParams, uint256 amount)
        external
        view
        returns (uint256)
    {
        return _convertToUSDAlias(aliasParams, amount);
    }

    function hackAccessMode(AccessMode mode) external {
        accessMode = mode;
    }

    function hackChecksEnabled(bool enabled) external {
        checksEnabled = enabled;
    }

    function hackAddTokenWithAlias(address token, PriceFeedParams memory params) external {
        _tokensWithAliasSet.add(token);
        _aliasPriceFeedParams[token] = params;
    }
}
*/
