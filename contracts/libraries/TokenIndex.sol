// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

/// @title TokenIndex library
library TokenIndex {
    function unzip(uint256 value) internal pure returns (address token, uint8 maskIndex) {
        maskIndex = uint8(value >> 160);
        token = address(uint160(value));
    }

    function zipWith(address token, uint8 maskIndex) internal pure returns (uint256 result) {
        result = uint256(maskIndex) << 160 | uint256(uint160(token));
    }
}
