// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {PriceOracleV3, PriceFeedParams} from "../../../core/PriceOracleV3.sol";

contract PriceOracleV3Harness is PriceOracleV3 {
    constructor(address addressProvider) PriceOracleV3(addressProvider) {}

    function getTokenReserveKey(address token) external pure returns (address) {
        return _getTokenReserveKey(token);
    }

    function getPriceFeedParams(address token) external view returns (PriceFeedParams memory) {
        (address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals, bool useReserve, bool trusted) =
            _getPriceFeedParams(token);
        return PriceFeedParams(priceFeed, stalenessPeriod, skipCheck, decimals, useReserve, trusted);
    }

    function getReservePriceFeedParams(address token) external view returns (PriceFeedParams memory) {
        (address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals, bool useReserve, bool trusted) =
            _getPriceFeedParams(_getTokenReserveKey(token));
        return PriceFeedParams(priceFeed, stalenessPeriod, skipCheck, decimals, useReserve, trusted);
    }

    function getPrice(address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals)
        external
        view
        returns (uint256 price, uint256 scale)
    {
        return _getPrice(priceFeed, stalenessPeriod, skipCheck, decimals);
    }

    function hackPriceFeedParams(address token, PriceFeedParams memory params) external {
        _priceFeedsParams[token] = params;
    }

    function hackReservePriceFeedParams(address token, PriceFeedParams memory params) external {
        _priceFeedsParams[_getTokenReserveKey(token)] = params;
    }

    function validateToken(address token) external view returns (uint8 decimals) {
        return _validateToken(token);
    }

    function validatePriceFeed(address priceFeed, uint32 stalenessPeriod) external view returns (bool skipCheck) {
        return _validatePriceFeed(priceFeed, stalenessPeriod);
    }
}
