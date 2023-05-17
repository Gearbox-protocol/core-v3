// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {Pool4626} from "./Pool4626.sol";
import {USDT_Transfer} from "../traits/USDT_Transfer.sol";
import {IPool4626} from "../interfaces/IPool4626.sol";

/// @title Core pool contract compatible with ERC4626
/// @notice Implements pool & dieselUSDT_Transferogic

contract Pool4626_USDT is Pool4626, USDT_Transfer {
    constructor(
        address _addressProvider,
        address _underlyingToken,
        address _interestRateModel,
        uint256 _expectedLiquidityLimit,
        bool _supportsQuotas
    )
        Pool4626(_addressProvider, _underlyingToken, _interestRateModel, _expectedLiquidityLimit, _supportsQuotas)
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
