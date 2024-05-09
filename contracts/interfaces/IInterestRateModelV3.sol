// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

/// @title Interest rate model V3 interface
/// @notice Generic interface for an interest rate model contract that can be used in a pool
interface IInterestRateModelV3 is IVersion {
    /// @notice Calculates borrow rate based on utilization
    /// @dev The last parameter
    /// @dev Allowed to be state-changing to
    function calcBorrowRate(uint256 expectedLiquidity, uint256 availableLiquidity, bool checkOptimalBorrowing)
        external
        returns (uint256);

    function availableToBorrow(uint256 expectedLiquidity, uint256 availableLiquidity) external view returns (uint256);
}
