// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {CreditManagerV3} from "./CreditManagerV3.sol";
import {USDT_Transfer} from "../traits/USDT_Transfer.sol";
import {IPoolV3} from "../interfaces/IPoolV3.sol";

/// @title Credit manager V3 USDT
/// @notice Credit manager variation for USDT underlying with enabled transfer fees
contract CreditManagerV3_USDT is CreditManagerV3, USDT_Transfer {
    /// @notice Contract type
    bytes32 public constant override contractType = "CM_USDT";

    constructor(
        address _pool,
        address _accountFactory,
        address _priceOracle,
        uint8 _maxEnabledTokens,
        uint16 _feeInterest,
        string memory _name
    )
        CreditManagerV3(_pool, _accountFactory, _priceOracle, _maxEnabledTokens, _feeInterest, _name)
        USDT_Transfer(IPoolV3(_pool).asset())
    {}

    function _amountWithFee(uint256 amount) internal view override returns (uint256) {
        return _amountUSDTWithFee(amount);
    }

    function _amountMinusFee(uint256 amount) internal view override returns (uint256) {
        return _amountUSDTMinusFee(amount);
    }
}
