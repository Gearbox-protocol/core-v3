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
        address addressProvider_,
        address underlyingToken_,
        address interestRateModel_,
        uint256 totalDebtLimit_,
        bool supportsQuotas_
    )
        PoolV3(addressProvider_, underlyingToken_, interestRateModel_, totalDebtLimit_, supportsQuotas_)
        USDT_Transfer(underlyingToken_)
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
