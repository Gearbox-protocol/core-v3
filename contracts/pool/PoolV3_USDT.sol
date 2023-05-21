// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {PoolV3} from "./PoolV3.sol";
import {USDT_Transfer} from "../traits/USDT_Transfer.sol";
import {IPoolV3} from "../interfaces/IPoolV3.sol";

/// @title Core pool contract compatible with ERC4626
/// @notice Implements pool & dieselUSDT_Transferogic

contract PoolV3_USDT is PoolV3, USDT_Transfer {
    constructor(
        address _addressProvider,
        address _underlyingToken,
        address _interestRateModel,
        uint256 _expectedLiquidityLimit,
        bool _supportsQuotas
    )
        PoolV3(_addressProvider, _underlyingToken, _interestRateModel, _expectedLiquidityLimit, _supportsQuotas)
        USDT_Transfer(_underlyingToken)
    {
        // Additional check that receiver is not address(0)
    }

    function _amountWithFee(uint256 amount) internal view override returns (uint256) {
        return _amountUSDTWithFee(amount);
    }

    function _amountMinusFee(uint256 amount) internal view override returns (uint256) {
        return _amountUSDTMinusFee(amount);
    }
}
