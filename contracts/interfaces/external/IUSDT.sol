// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

interface IUSDT {
    function basisPointsRate() external view returns (uint256);
    function maximumFee() external view returns (uint256);
}
