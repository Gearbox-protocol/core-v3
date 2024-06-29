// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

/// @title Bit mask library
/// @notice Implements functions that manipulate bit masks.
///         Bit masks are utilized extensively by Gearbox to efficiently store token sets (enabled tokens on accounts or
///         forbidden tokens) and check for set inclusion. A mask is a `uint256` number that has its `i`-th bit set to `1`
///         if `i`-th item is included into the set. For example, each token has a mask equal to `2**i`, so set inclusion
///         can be checked by computing `tokenMask & setMask != 0`.
library BitMask {
    /// @notice Calculates the number of enabled bits in `mask`
    /// @custom:tests U:[BM-1]
    function calcEnabledBits(uint256 mask) internal pure returns (uint256 enabled) {
        unchecked {
            while (mask > 0) {
                mask &= mask - 1;
                ++enabled;
            }
        }
    }

    /// @notice Enables bits from `bitsToEnable` in `mask`
    /// @custom:tests U:[BM-2]
    function enable(uint256 mask, uint256 bitsToEnable) internal pure returns (uint256) {
        return mask | bitsToEnable;
    }

    /// @notice Disables bits from `bitsToDisable` in `mask`
    /// @custom:tests U:[BM-2]
    function disable(uint256 mask, uint256 bitsToDisable) internal pure returns (uint256) {
        return mask & ~bitsToDisable;
    }

    /// @notice Returns `mask` with bits from `bitsToEnable` enabled and bits from `bitsToDisable` disabled
    /// @dev `bitsToEnable` and `bitsToDisable` are applied sequentially, so if some bit is enabled in both masks,
    ///      it will be disabled in the resulting mask regardless of its value in the original one
    /// @custom:tests U:[BM-3]
    function enableDisable(uint256 mask, uint256 bitsToEnable, uint256 bitsToDisable) internal pure returns (uint256) {
        return (mask | bitsToEnable) & (~bitsToDisable);
    }

    /// @notice Returns a mask with only the least significant bit of `mask` enabled
    /// @dev This function can be used to efficiently iterate over enabled bits in a mask
    /// @custom:tests U:[BM-4]
    function lsbMask(uint256 mask) internal pure returns (uint256) {
        unchecked {
            return mask & uint256(-int256(mask));
        }
    }
}
