// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {CreditManagerV3} from "./CreditManagerV3.sol";
import {USDT_Transfer} from "../traits/USDT_Transfer.sol";
import {IPoolV3} from "../interfaces/IPoolV3.sol";

/// @title Credit manager V3 USDT
/// @notice Credit manager variation for USDT underlying with enabled transfer fees
contract CreditManagerV3_USDT is CreditManagerV3, USDT_Transfer {
    constructor(address _addressProvider, address _pool, string memory _name)
        CreditManagerV3(_addressProvider, _pool, _name)
        USDT_Transfer(IPoolV3(_pool).asset())
    {}

    function _amountWithFee(uint256 amount) internal view override returns (uint256) {
        return _amountUSDTWithFee(amount);
    }

    function _amountMinusFee(uint256 amount) internal view override returns (uint256) {
        return _amountUSDTMinusFee(amount);
    }
}
