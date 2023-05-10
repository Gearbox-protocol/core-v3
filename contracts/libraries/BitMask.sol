// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IncorrectParameterException} from "../interfaces/IExceptions.sol";

uint256 constant UNDERLYING_TOKEN_MASK = 1;

/// @title BitMask library
library BitMask {
    function calcIndex(uint256 mask) internal pure returns (uint8) {
        if (mask == 0) revert IncorrectParameterException();
        uint16 lb = 0;
        uint16 ub = 256;
        uint16 mid = 128;

        unchecked {
            while (1 << mid & mask == 0) {
                if (1 << mid > mask) ub = mid;
                else lb = mid;
                mid = (lb + ub) / 2;
            }
        }

        return uint8(mid);
    }

    /// @dev Calculates the number of `1` bits
    /// @param enabledTokensMask Bit mask to compute how many bits are set
    function calcEnabledTokens(uint256 enabledTokensMask) internal pure returns (uint256 totalTokensEnabled) {
        unchecked {
            while (enabledTokensMask > 0) {
                totalTokensEnabled += enabledTokensMask & 1;
                enabledTokensMask >>= 1;
            }
        }
    }
}
