// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

/// @title Linear interest rate model V3 interface
interface ILinearInterestRateModelV3 is IVersion {
    function calcBorrowRate(uint256 expectedLiquidity, uint256 availableLiquidity, bool checkOptimalBorrowing)
        external
        view
        returns (uint256);

    function availableToBorrow(uint256 expectedLiquidity, uint256 availableLiquidity) external view returns (uint256);

    function isBorrowingMoreU2Forbidden() external view returns (bool);

    function getModelParameters()
        external
        view
        returns (uint16 U_1, uint16 U_2, uint16 R_base, uint16 R_slope1, uint16 R_slope2, uint16 R_slope3);
}
