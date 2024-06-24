// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";

/// @title Interest rate model interface
/// @notice Generic interface for an interest rate model contract that can be used in a pool
interface IInterestRateModel is IVersion {
    /// @notice Calculates borrow rate based on utilization
    /// @dev The last parameter can be used to prevent borrowing above maximum allowed utilization
    /// @dev This function can be state-changing in case the IRM is stateful
    function calcBorrowRate(uint256 expectedLiquidity, uint256 availableLiquidity, bool checkOptimalBorrowing)
        external
        returns (uint256);

    /// @notice Returns amount that can be borrowed before maximum allowed utilization is reached
    function availableToBorrow(uint256 expectedLiquidity, uint256 availableLiquidity) external view returns (uint256);
}
