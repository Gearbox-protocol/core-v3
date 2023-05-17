// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUSDT} from "../interfaces/external/IUSDT.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

contract USDT_Transfer {
    address private immutable usdt;

    constructor(address _usdt) {
        usdt = _usdt;
    }

    /// @dev Computes how much usdt you should send to get exact amount on destination account
    function _amountUSDTWithFee(uint256 amount) internal view virtual returns (uint256) {
        uint256 amountWithBP = (amount * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR - IUSDT(usdt).basisPointsRate()); // U:[UTT_01]
        uint256 maximumFee = IUSDT(usdt).maximumFee(); // U:[UTT_01]
        unchecked {
            uint256 amountWithMaxFee = maximumFee > type(uint256).max - amount ? maximumFee : amount + maximumFee;
            return Math.min(amountWithMaxFee, amountWithBP); // U:[UTT_01]
        }
    }

    /// @dev Computes how much usdt you should send to get exact amount on destination account
    function _amountUSDTMinusFee(uint256 amount) internal view virtual returns (uint256) {
        uint256 fee = amount * IUSDT(usdt).basisPointsRate() / PERCENTAGE_FACTOR;
        uint256 maximumFee = IUSDT(usdt).maximumFee();
        fee = Math.min(maximumFee, fee);
        return amount - fee;
    }
}
