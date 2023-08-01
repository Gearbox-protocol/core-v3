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
        return _priceFeedsParams[token];
    }

    function getReservePriceFeedParams(address token) external view returns (PriceFeedParams memory) {
        return _priceFeedsParams[_getTokenReserveKey(token)];
    }

    function hackPriceFeedParams(address token, PriceFeedParams memory params) external {
        _priceFeedsParams[token] = params;
    }

    function hackReservePriceFeedParams(address token, PriceFeedParams memory params) external {
        _priceFeedsParams[_getTokenReserveKey(token)] = params;
    }
}
