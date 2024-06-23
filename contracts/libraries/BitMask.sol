// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IncorrectParameterException} from "../interfaces/IExceptions.sol";

/// @title Bit mask library
/// @notice Implements functions that manipulate bit masks
///         Bit masks are utilized extensively by Gearbox to efficiently store token sets (enabled tokens on accounts
///         or forbidden tokens) and check for set inclusion. A mask is a uint256 number that has its i-th bit set to
///         1 if i-th item is included into the set. For example, each token has a mask equal to 2**i, so set inclusion
///         can be checked by checking tokenMask & setMask != 0.
library BitMask {
    /// @dev Calculates the number of `1` bits
    /// @param enabledTokensMask Bit mask to compute the number of `1` bits in
    /// @custom:tests U:[BM-1]
    function calcEnabledTokens(uint256 enabledTokensMask) internal pure returns (uint256 totalTokensEnabled) {
        unchecked {
            while (enabledTokensMask > 0) {
                enabledTokensMask &= enabledTokensMask - 1;
                ++totalTokensEnabled;
            }
        }
    }

    /// @dev Enables bits from the second mask in the first mask
    /// @param enabledTokenMask The initial mask
    /// @param bitsToEnable Mask of bits to enable
    /// @custom:tests U:[BM-2]
    function enable(uint256 enabledTokenMask, uint256 bitsToEnable) internal pure returns (uint256) {
        return enabledTokenMask | bitsToEnable;
    }

    /// @dev Disables bits from the second mask in the first mask
    /// @param enabledTokenMask The initial mask
    /// @param bitsToDisable Mask of bits to disable
    /// @custom:tests U:[BM-2]
    function disable(uint256 enabledTokenMask, uint256 bitsToDisable) internal pure returns (uint256) {
        return enabledTokenMask & ~bitsToDisable;
    }

    /// @dev Computes a new mask with sets of new enabled and disabled bits
    /// @dev bitsToEnable and bitsToDisable are applied sequentially to original mask
    /// @param enabledTokensMask The initial mask
    /// @param bitsToEnable Mask with bits to enable
    /// @param bitsToDisable Mask with bits to disable
    /// @custom:tests U:[BM-3]
    function enableDisable(uint256 enabledTokensMask, uint256 bitsToEnable, uint256 bitsToDisable)
        internal
        pure
        returns (uint256)
    {
        return (enabledTokensMask | bitsToEnable) & (~bitsToDisable);
    }
}
