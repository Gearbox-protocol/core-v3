// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

/// @title USDT fees library
/// @notice Helps to calculate USDT amounts adjusted for fees
library USDTFees {
    /// @dev Computes amount of USDT that should be sent to receive `amount`
    function amountUSDTWithFee(uint256 amount, uint256 basisPointsRate, uint256 maximumFee)
        internal
        pure
        returns (uint256)
    {
        uint256 fee = amount * basisPointsRate / (PERCENTAGE_FACTOR - basisPointsRate); // U:[UTT_01]
        fee = Math.min(maximumFee, fee); // U:[UTT_01]
        unchecked {
            return fee > type(uint256).max - amount ? type(uint256).max : amount + fee; // U:[UTT_01]
        }
    }

    /// @dev Computes amount of USDT that would be received if `amount` is sent
    function amountUSDTMinusFee(uint256 amount, uint256 basisPointsRate, uint256 maximumFee)
        internal
        pure
        returns (uint256)
    {
        uint256 fee = amount * basisPointsRate / PERCENTAGE_FACTOR; // U:[UTT_01]
        fee = Math.min(maximumFee, fee); // U:[UTT_01]
        return amount - fee; // U:[UTT_01]
    }
}
