// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {CreditManagerV3} from "./CreditManagerV3.sol";
import {USDT_Transfer} from "../traits/USDT_Transfer.sol";
import {IPoolBase} from "../interfaces/IPoolV3.sol";
/// @title Credit Manager

contract CreditManagerV3_USDT is CreditManagerV3, USDT_Transfer {
    constructor(address _addressProvider, address _pool)
        CreditManagerV3(_addressProvider, _pool)
        USDT_Transfer(IPoolBase(_pool).underlyingToken())
    {}

    function _amountWithFee(uint256 amount) internal view override returns (uint256) {
        return _amountUSDTWithFee(amount);
    }

    function _amountMinusFee(uint256 amount) internal view override returns (uint256) {
        return _amountUSDTMinusFee(amount);
    }
}
