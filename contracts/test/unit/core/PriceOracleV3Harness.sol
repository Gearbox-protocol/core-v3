// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {PriceOracleV3, PriceFeedParams} from "../../../core/PriceOracleV3.sol";

contract PriceOracleV3Harness is PriceOracleV3 {
    constructor(address addressProvider) PriceOracleV3(addressProvider) {}

    function hackPriceFeedParams(address token, PriceFeedParams memory params) external {
        _priceFeedsParams[token] = params;
    }

    function hackReservePriceFeedParams(address token, PriceFeedParams memory params) external {
        _priceFeedsParams[_getTokenReserveKey(token)] = params;
    }

    function exposed_getTokenReserveKey(address token) external pure returns (address) {
        return _getTokenReserveKey(token);
    }

    function exposed_validateToken(address token) external view returns (uint8 decimals) {
        return _validateToken(token);
    }

    function exposed_validatePriceFeed(address priceFeed, uint32 stalenessPeriod)
        external
        view
        returns (bool skipCheck)
    {
        return _validatePriceFeed(priceFeed, stalenessPeriod);
    }

    function exposed_getValidatedPrice(address priceFeed, uint32 stalenessPeriod, bool skipCheck)
        external
        view
        returns (int256 answer)
    {
        return _getValidatedPrice(priceFeed, stalenessPeriod, skipCheck);
    }
}
