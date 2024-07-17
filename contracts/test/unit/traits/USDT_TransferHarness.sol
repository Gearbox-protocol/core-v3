// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.23;

import {USDT_Transfer} from "../../../traits/USDT_Transfer.sol";

contract USDT_TransferHarness is USDT_Transfer {
    constructor(address _usdt) USDT_Transfer(_usdt) {}

    function amountUSDTWithFee(uint256 amount) external view returns (uint256) {
        return _amountUSDTWithFee(amount);
    }

    function amountUSDTMinusFee(uint256 amount) external view returns (uint256) {
        return _amountUSDTMinusFee(amount);
    }
}
