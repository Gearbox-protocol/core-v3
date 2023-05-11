// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;
pragma abicoder v1;

import {WAD, RAY} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";
import {IInterestRateModel} from "../interfaces/IInterestRateModel.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

/// @title Linear Interest Rate Model
contract LinearInterestRateModel is IInterestRateModel {
    // reverts if borrow more than U2 if flag is set
    bool public immutable isBorrowingMoreU2Forbidden;

    // Uoptimal[0;1] in Wad
    uint256 public immutable U_1_WAD;

    // Uoptimal[0;1] in Wad
    uint256 public immutable U_2_WAD;

    // R_base in Ray
    uint256 public immutable R_base_RAY;

    // R_Slope1 in Ray
    uint256 public immutable R_slope1_RAY;

    // R_Slope2 in Ray
    uint256 public immutable R_slope2_RAY;

    // R_Slope2 in Ray
    uint256 public immutable R_slope3_RAY;

    // Contract version
    uint256 public constant version = 3_00;

    /// @dev Constructor
    /// @param U_1 Optimal U in percentage format: x10.000 - percentage plus two decimals
    /// @param U_2 Optimal U in percentage format: x10.000 - percentage plus two decimals
    /// @param R_base R_base in percentage format: x10.000 - percentage plus two decimals @param R_slope1 R_Slope1 in Ray
    /// @param R_slope1 R_Slope1 in percentage format: x10.000 - percentage plus two decimals
    /// @param R_slope2 R_Slope2 in percentage format: x10.000 - percentage plus two decimals
    /// @param R_slope3 R_Slope3 in percentage format: x10.000 - percentage plus two decimals
    constructor(
        uint16 U_1,
        uint16 U_2,
        uint16 R_base,
        uint16 R_slope1,
        uint16 R_slope2,
        uint16 R_slope3,
        bool _isBorrowingMoreU2Forbidden
    ) {
        if (
            (U_1 >= PERCENTAGE_FACTOR) || (U_2 >= PERCENTAGE_FACTOR) || (U_1 > U_2) || (R_base > PERCENTAGE_FACTOR)
                || (R_slope1 > PERCENTAGE_FACTOR) || (R_slope2 > PERCENTAGE_FACTOR) || (R_slope1 > R_slope2)
                || (R_slope2 > R_slope3)
        ) {
            revert IncorrectParameterException(); // F:[LIM-2]
        }

        // Convert percetns to WAD
        U_1_WAD = (WAD * U_1) / PERCENTAGE_FACTOR; // F:[LIM-1]

        // Convert percetns to WAD
        U_2_WAD = (WAD * U_2) / PERCENTAGE_FACTOR; // F:[LIM-1]

        R_base_RAY = (RAY * R_base) / PERCENTAGE_FACTOR; // F:[LIM-1]
        R_slope1_RAY = (RAY * R_slope1) / PERCENTAGE_FACTOR; // F:[LIM-1]
        R_slope2_RAY = (RAY * R_slope2) / PERCENTAGE_FACTOR; // F:[LIM-1]
        R_slope3_RAY = (RAY * R_slope3) / PERCENTAGE_FACTOR; // F:[LIM-1]

        isBorrowingMoreU2Forbidden = _isBorrowingMoreU2Forbidden; // F:[LIM-1]
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
        } // F:[LIM-3]

        //      expectedLiquidity - availableLiquidity
        // U = -------------------------------------
        //             expectedLiquidity

        uint256 U_WAD = (WAD * (expectedLiquidity - availableLiquidity)) / expectedLiquidity; // F:[LIM-3]

        // if U < U1:
        //
        //                                    U
        // borrowRate = Rbase + Rslope1 * ----------
        //                                 U1
        //
        if (U_WAD < U_1_WAD) {
            return R_base_RAY + ((R_slope1_RAY * U_WAD) / U_1_WAD); // F:[LIM-3]
        }

        // if U >= U1 & U < U2:
        //
        //                                                      U - U1
        // borrowRate = Rbase + Rslope1 + Rslope2  + Rslope * ---------
        //                                                     U2 - U1

        if (U_WAD >= U_1_WAD && U_WAD < U_2_WAD) {
            return R_base_RAY + R_slope1_RAY + (R_slope2_RAY * (U_WAD - U_1_WAD)) / (U_2_WAD - U_1_WAD); // F:[LIM-3]
        }

        /// if U > U2 && checkOptimalBorrowing && isBorrowingMoreU2Forbidden
        if (checkOptimalBorrowing && isBorrowingMoreU2Forbidden) {
            revert BorrowingMoreU2ForbiddenException(); // F:[LIM-3]
        }

        // if U >= U2:
        //
        //                                                      U - U2
        // borrowRate = Rbase + Rslope1 + Rslope2  + Rslope * ----------
        //                                                      1 - U2

        return R_base_RAY + R_slope1_RAY + R_slope2_RAY + (R_slope3_RAY * (U_WAD - U_2_WAD)) / (WAD - U_2_WAD); // F:[LIM-3]
    }

    /// @dev Returns the model's parameters
    /// @param U_1 U_1 in percentage format: [0;10,000] - percentage plus two decimals
    /// @param R_base R_base in RAY format
    /// @param R_slope1 R_slope1 in RAY format
    /// @param R_slope2 R_slope2 in RAY format
    function getModelParameters()
        external
        view
        returns (uint16 U_1, uint16 U_2, uint16 R_base, uint16 R_slope1, uint16 R_slope2, uint16 R_slope3)
    {
        U_1 = uint16((U_1_WAD * PERCENTAGE_FACTOR) / WAD); // F:[LIM-1]
        U_2 = uint16((U_2_WAD * PERCENTAGE_FACTOR) / WAD); // F:[LIM-1]
        R_base = uint16(R_base_RAY * PERCENTAGE_FACTOR / RAY); // F:[LIM-1]
        R_slope1 = uint16(R_slope1_RAY * PERCENTAGE_FACTOR / RAY); // F:[LIM-1]
        R_slope2 = uint16(R_slope2_RAY * PERCENTAGE_FACTOR / RAY); // F:[LIM-1]
        R_slope3 = uint16(R_slope3_RAY * PERCENTAGE_FACTOR / RAY); // F:[LIM-1]
    }

    function availableToBorrow(uint256 expectedLiquidity, uint256 availableLiquidity)
        external
        view
        override
        returns (uint256)
    {
        if (isBorrowingMoreU2Forbidden && (expectedLiquidity >= availableLiquidity)) {
            uint256 U_WAD = (WAD * (expectedLiquidity - availableLiquidity)) / expectedLiquidity; // F:[LIM-3]

            return (U_WAD < U_2_WAD) ? ((U_2_WAD - U_WAD) * expectedLiquidity) / WAD : 0; // F:[LIM-3]
        } else {
            return availableLiquidity; // F:[LIM-3]
        }
    }
}
