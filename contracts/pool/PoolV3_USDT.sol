// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {PoolV3} from "./PoolV3.sol";
import {USDT_Transfer} from "../traits/USDT_Transfer.sol";

/// @title Pool V3 USDT
/// @notice Pool implementation for USDT which has optional transfer fee
contract PoolV3_USDT is PoolV3, USDT_Transfer {
    constructor(
        address addressProvider_,
        address underlyingToken_,
        address interestRateModel_,
        uint256 totalDebtLimit_,
        bool supportsQuotas_,
        string memory namePrefix_,
        string memory symbolPrefix_
    )
        PoolV3(
            addressProvider_,
            underlyingToken_,
            interestRateModel_,
            totalDebtLimit_,
            supportsQuotas_,
            namePrefix_,
            symbolPrefix_
        )
        USDT_Transfer(underlyingToken_)
    {}

    function _amountWithFee(uint256 amount) internal view override returns (uint256) {
        return _amountUSDTWithFee(amount);
    }

    function _amountMinusFee(uint256 amount) internal view override returns (uint256) {
        return _amountUSDTMinusFee(amount);
    }
}
