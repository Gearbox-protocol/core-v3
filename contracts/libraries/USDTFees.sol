// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PERCENTAGE_FACTOR} from "../libraries/Constants.sol";

/// @title  USDT fees library
/// @notice Helps to calculate USDT amounts adjusted for fees
library USDTFees {
    /// @notice Computes amount of USDT that should be sent to receive `amount`
    /// @custom:tests U:[UTT-1]
    function amountUSDTWithFee(uint256 amount, uint256 basisPointsRate, uint256 maximumFee)
        internal
        pure
        returns (uint256)
    {
        uint256 fee = amount * basisPointsRate / (PERCENTAGE_FACTOR - basisPointsRate);
        fee = Math.min(maximumFee, fee);
        unchecked {
            return fee > type(uint256).max - amount ? type(uint256).max : amount + fee;
        }
    }

    /// @notice Computes amount of USDT that would be received if `amount` is sent
    /// @custom:tests U:[UTT-1]
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
