// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

/// @title USDT fees Library
library USDTFees {
    function amountUSDTWithFee(uint256 amount, uint256 basisPointsRate, uint256 maximumFee)
        internal
        pure
        returns (uint256)
    {
        uint256 amountWithBP = (amount * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR - basisPointsRate); // U:[UTT_01]
        unchecked {
            uint256 amountWithMaxFee = maximumFee > type(uint256).max - amount ? type(uint256).max : amount + maximumFee;
            return Math.min(amountWithMaxFee, amountWithBP); // U:[UTT_01]
        }
    }

    /// @dev Computes how much usdt you should send to get exact amount on destination account
    function amountUSDTMinusFee(uint256 amount, uint256 basisPointsRate, uint256 maximumFee)
        internal
        pure
        returns (uint256)
    {
        uint256 fee = amount * basisPointsRate / PERCENTAGE_FACTOR;
        fee = Math.min(maximumFee, fee);
        return amount - fee;
    }
}
