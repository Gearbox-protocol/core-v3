// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {WAD, RAY} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";
import {IInterestRateModel} from "../interfaces/IInterestRateModel.sol";
import {Errors} from "@gearbox-protocol/core-v2/contracts/libraries/Errors.sol";

/// @title Linear Interest Rate Model
/// @notice Linear interest rate model, similar which Aave uses
contract LinearInterestRateModel is IInterestRateModel {
    bool public immutable isBorrowingMoreOptimalForbidden;

    // Uoptimal[0;1] in Wad
    uint256 public immutable U_Optimal_WAD;

    // 1 - Uoptimal [0;1] x10.000, percentage plus two decimals
    uint256 public immutable U_Optimal_inverted_WAD;

    // Uoptimal[0;1] in Wad
    uint256 public immutable U_Reserve_WAD;

    // 1 - Uoptimal [0;1] x10.000, percentage plus two decimals
    uint256 immutable U_Reserve_inverted_WAD;

    // R_base in Ray
    uint256 public immutable R_base_RAY;

    // R_Slope1 in Ray
    uint256 public immutable R_slope1_RAY;

    // R_Slope2 in Ray
    uint256 public immutable R_slope2_RAY;

    // R_Slope2 in Ray
    uint256 public immutable R_slope3_RAY;

    // Contract version
    uint256 public constant version = 2_01;

    /// @dev Constructor
    /// @param U_optimal Optimal U in percentage format: x10.000 - percentage plus two decimals
    /// @param U_reserve Optimal U in percentage format: x10.000 - percentage plus two decimals
    /// @param R_base R_base in percentage format: x10.000 - percentage plus two decimals @param R_slope1 R_Slope1 in Ray
    /// @param R_slope1 R_Slope1 in percentage format: x10.000 - percentage plus two decimals
    /// @param R_slope2 R_Slope2 in percentage format: x10.000 - percentage plus two decimals
    /// @param R_slope3 R_Slope3 in percentage format: x10.000 - percentage plus two decimals
    constructor(
        uint256 U_optimal,
        uint256 U_reserve,
        uint256 R_base,
        uint256 R_slope1,
        uint256 R_slope2,
        uint256 R_slope3,
        bool _isBorrowingMoreOptimalForbidden
    ) {
        if ((U_optimal >= PERCENTAGE_FACTOR) || (R_base > PERCENTAGE_FACTOR) || (R_slope1 > PERCENTAGE_FACTOR)) {
            revert IncorrectParameterException();
        }

        // Convert percetns to WAD
        uint256 U_optimal_WAD = WAD * U_optimal / PERCENTAGE_FACTOR;
        U_Optimal_WAD = (WAD * U_optimal) / PERCENTAGE_FACTOR;

        // 1 - Uoptimal in WAD
        U_Optimal_inverted_WAD = WAD - U_optimal_WAD;

        // Convert percetns to WAD
        U_Reserve_WAD = WAD * U_reserve / PERCENTAGE_FACTOR;

        // 1 - UReserve in WAD
        U_Reserve_inverted_WAD = WAD - U_Reserve_WAD;

        R_base_RAY = RAY * R_base / PERCENTAGE_FACTOR;
        R_slope1_RAY = RAY * R_slope1 / PERCENTAGE_FACTOR;
        R_slope2_RAY = RAY * R_slope2 / PERCENTAGE_FACTOR;
        R_slope3_RAY = RAY * R_slope3 / PERCENTAGE_FACTOR;

        isBorrowingMoreOptimalForbidden = _isBorrowingMoreOptimalForbidden;
    }

    /// @dev Returns the borrow rate calculated based on expectedLiquidity and availableLiquidity
    /// @param expectedLiquidity Expected liquidity in the pool
    /// @param availableLiquidity Available liquidity in the pool
    /// @notice In RAY format
    function calcBorrowRate(uint256 expectedLiquidity, uint256 availableLiquidity)
        external
        view
        override
        returns (uint256)
    {
        return calcBorrowRate(expectedLiquidity, availableLiquidity, false);
    }

    /// @dev Returns the borrow rate calculated based on expectedLiquidity and availableLiquidity
    /// @param expectedLiquidity Expected liquidity in the pool
    /// @param availableLiquidity Available liquidity in the pool
    /// @notice In RAY format
    function calcBorrowRate(uint256 expectedLiquidity, uint256 availableLiquidity, bool checkOptimalBorrowing)
        public
        view
        override
        returns (uint256)
    {
        if (expectedLiquidity == 0 || expectedLiquidity < availableLiquidity) {
            return R_base_RAY;
        } // T: [LR-5,6]

        //      expectedLiquidity - availableLiquidity
        // U = -------------------------------------
        //             expectedLiquidity

        uint256 U_WAD = (WAD * (expectedLiquidity - availableLiquidity)) / expectedLiquidity;

        // if U < Uoptimal:
        //
        //                                    U
        // borrowRate = Rbase + Rslope1 * ----------
        //                                 Uoptimal
        //
        if (U_WAD < U_Optimal_WAD) {
            return R_base_RAY + ((R_slope1_RAY * U_WAD) / U_Optimal_WAD);
        } else if (checkOptimalBorrowing && isBorrowingMoreOptimalForbidden) {
            revert BorrowingMoreOptimalForbiddenException();
        } else if (U_WAD >= U_Optimal_WAD && U_WAD < U_Reserve_WAD) {
            return R_base_RAY + R_slope1_RAY + (R_slope2_RAY * (U_WAD - U_Optimal_WAD)) / U_Optimal_inverted_WAD; // T:[LR-1,2,3]
        }

        // if U >= Uoptimal & U < Ureserve:
        //
        //                                                     U - Ureserve
        // borrowRate = Rbase + Rslope1 + Rslope2  + Rslope * --------------
        //                                                     1 - Ureserve

        return
            R_base_RAY + R_slope1_RAY + R_slope2_RAY + (R_slope3_RAY * (U_WAD - U_Reserve_WAD)) / U_Reserve_inverted_WAD; // T:[LR-1,2,3]
    }

    /// @dev Returns the model's parameters
    /// @param U_optimal U_optimal in percentage format: [0;10,000] - percentage plus two decimals
    /// @param R_base R_base in RAY format
    /// @param R_slope1 R_slope1 in RAY format
    /// @param R_slope2 R_slope2 in RAY format
    function getModelParameters()
        external
        view
        returns (uint256 U_optimal, uint256 R_base, uint256 R_slope1, uint256 R_slope2)
    {
        U_optimal = U_Optimal_WAD * PERCENTAGE_FACTOR / WAD; // T:[LR-4]
        R_base = R_base_RAY; // T:[LR-4]
        R_slope1 = R_slope1_RAY; // T:[LR-4]
        R_slope2 = R_slope2_RAY; // T:[LR-4]
    }

    function availableToBorrow(uint256 expectedLiquidity, uint256 availableLiquidity)
        external
        view
        override
        returns (uint256)
    {
        if (isBorrowingMoreOptimalForbidden) {
            uint256 U_WAD = (WAD * (expectedLiquidity - availableLiquidity)) / expectedLiquidity;

            return (U_WAD < U_Optimal_WAD) ? ((U_Optimal_WAD - U_WAD) * expectedLiquidity) / PERCENTAGE_FACTOR : 0;
        } else {
            return availableLiquidity;
        }
    }
}
