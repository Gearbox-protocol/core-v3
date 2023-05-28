// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;
pragma abicoder v1;

import {WAD, RAY} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {IInterestRateModelV3} from "../interfaces/IInterestRateModelV3.sol";

// EXCEPTIONS
import {IncorrectParameterException, BorrowingMoreU2ForbiddenException} from "../interfaces/IExceptions.sol";

/// @title Linear Interest Rate Model
/// @dev GearboxV3 uses a two-point linear model in its pools. Unlike
///      previous single-point models, it has a new intermediate slope
///      between the obtuse and steep regions, which serves to decrease
///      interest rate jumps due to large withdrawals. Additionally, the model
///      can be configured to prevent borrowing after entering the steep region
///      (beyond the U2 point), in order to create a reserve for exits and make
///      rates more stable
contract LinearInterestRateModel is IInterestRateModelV3 {
    /// @notice Whether to revert when borrowing beyond U2 utilization
    bool public immutable isBorrowingMoreU2Forbidden;

    /// @notice The first rate change point (obtuse -> intermediate region)
    uint256 public immutable U_1_WAD;

    /// @notice The second rate change point (intermediate -> steep region)
    uint256 public immutable U_2_WAD;

    /// @notice Base interest rate in WAD format
    uint256 public immutable R_base_RAY;

    /// @notice Slope of the first region. The rate at U1 is equal
    ///         to R_base_RAY + R_slope1_RAY
    uint256 public immutable R_slope1_RAY;

    /// @notice Slope of the second region. The rate at U2 is equal
    ///         to R_base_RAY + R_slope1_RAY + R_slope2_RAY
    uint256 public immutable R_slope2_RAY;

    /// @notice Slope of the third region. The rate at U = 100% is equal
    ///         to R_base_RAY + R_slope1_RAY + R_slope2_RAY
    uint256 public immutable R_slope3_RAY;

    /// @notice Contract version
    uint256 public constant version = 3_00;

    /// @dev Constructor
    /// @param U_1 U1 in basis points
    /// @param U_2 U2 in basis points
    /// @param R_base R_base in basis points
    /// @param R_slope1 R_Slope1 in basis points
    /// @param R_slope2 R_Slope2 in basis points
    /// @param R_slope3 R_Slope3 in basis points
    /// @param _isBorrowingMoreU2Forbidden Whether to prevent borrowing more than U2
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
            revert IncorrectParameterException(); // U:[LIM-2]
        }

        /// Critical utilization points are stored in WAD format
        U_1_WAD = (WAD * U_1) / PERCENTAGE_FACTOR; // U:[LIM-1]
        U_2_WAD = (WAD * U_2) / PERCENTAGE_FACTOR; // U:[LIM-1]

        /// Slopes are stored in RAY format
        R_base_RAY = (RAY * R_base) / PERCENTAGE_FACTOR; // U:[LIM-1]
        R_slope1_RAY = (RAY * R_slope1) / PERCENTAGE_FACTOR; // U:[LIM-1]
        R_slope2_RAY = (RAY * R_slope2) / PERCENTAGE_FACTOR; // U:[LIM-1]
        R_slope3_RAY = (RAY * R_slope3) / PERCENTAGE_FACTOR; // U:[LIM-1]

        isBorrowingMoreU2Forbidden = _isBorrowingMoreU2Forbidden; // U:[LIM-1]
    }

    /// @notice Returns the borrow rate calculated based on expectedLiquidity and availableLiquidity,
    ///      without preventing borrowing over U2
    /// @param expectedLiquidity Expected liquidity in the pool
    /// @param availableLiquidity Available liquidity in the pool
    function calcBorrowRate(uint256 expectedLiquidity, uint256 availableLiquidity)
        external
        view
        override
        returns (uint256)
    {
        return calcBorrowRate(expectedLiquidity, availableLiquidity, false);
    }

    /// @notice Returns the borrow rate calculated based on expectedLiquidity and availableLiquidity
    /// @param expectedLiquidity Expected liquidity in the pool
    /// @param availableLiquidity Available liquidity in the pool
    /// @param checkOptimalBorrowing Whether utilization over U2 needs to be checked
    function calcBorrowRate(uint256 expectedLiquidity, uint256 availableLiquidity, bool checkOptimalBorrowing)
        public
        view
        override
        returns (uint256)
    {
        if (expectedLiquidity == 0 || expectedLiquidity < availableLiquidity) {
            return R_base_RAY;
        } // U:[LIM-3]

        //      expectedLiquidity - availableLiquidity
        // U = -------------------------------------
        //             expectedLiquidity

        uint256 U_WAD = (WAD * (expectedLiquidity - availableLiquidity)) / expectedLiquidity; // U:[LIM-3]

        // if U < U1:
        //
        //                                    U
        // borrowRate = Rbase + Rslope1 * ----------
        //                                    U1
        //
        if (U_WAD < U_1_WAD) {
            return R_base_RAY + ((R_slope1_RAY * U_WAD) / U_1_WAD); // U:[LIM-3]
        }

        // if U >= U1 & U < U2:
        //
        //                                           U  - U1
        // borrowRate = Rbase + Rslope1 + Rslope2 * ---------
        //                                           U2 - U1

        if (U_WAD >= U_1_WAD && U_WAD < U_2_WAD) {
            return R_base_RAY + R_slope1_RAY + (R_slope2_RAY * (U_WAD - U_1_WAD)) / (U_2_WAD - U_1_WAD); // U:[LIM-3]
        }

        /// If U > U2 in `isBorrowingMoreU2Forbidden` and the utilization check requested
        /// the function will revert to prevent raising utilization over the limit
        if (checkOptimalBorrowing && isBorrowingMoreU2Forbidden) {
            revert BorrowingMoreU2ForbiddenException(); // U:[LIM-3]
        }

        // if U >= U2:
        //
        //                                                      U - U2
        // borrowRate = Rbase + Rslope1 + Rslope2  + Rslope3 * ----------
        //                                                      1 - U2

        return R_base_RAY + R_slope1_RAY + R_slope2_RAY + (R_slope3_RAY * (U_WAD - U_2_WAD)) / (WAD - U_2_WAD); // U:[LIM-3]
    }

    /// @notice Returns the model's parameters
    function getModelParameters()
        external
        view
        returns (uint16 U_1, uint16 U_2, uint16 R_base, uint16 R_slope1, uint16 R_slope2, uint16 R_slope3)
    {
        U_1 = uint16((U_1_WAD * PERCENTAGE_FACTOR) / WAD); // U:[LIM-1]
        U_2 = uint16((U_2_WAD * PERCENTAGE_FACTOR) / WAD); // U:[LIM-1]
        R_base = uint16(R_base_RAY * PERCENTAGE_FACTOR / RAY); // U:[LIM-1]
        R_slope1 = uint16(R_slope1_RAY * PERCENTAGE_FACTOR / RAY); // U:[LIM-1]
        R_slope2 = uint16(R_slope2_RAY * PERCENTAGE_FACTOR / RAY); // U:[LIM-1]
        R_slope3 = uint16(R_slope3_RAY * PERCENTAGE_FACTOR / RAY); // U:[LIM-1]
    }

    /// @notice Returns the amount available to borrow until the U2 is reached if borrowing
    ///         over U2 is prohibited
    function availableToBorrow(uint256 expectedLiquidity, uint256 availableLiquidity)
        external
        view
        override
        returns (uint256)
    {
        if (isBorrowingMoreU2Forbidden && (expectedLiquidity >= availableLiquidity)) {
            uint256 U_WAD = (WAD * (expectedLiquidity - availableLiquidity)) / expectedLiquidity; // U:[LIM-3]

            return (U_WAD < U_2_WAD) ? ((U_2_WAD - U_WAD) * expectedLiquidity) / WAD : 0; // U:[LIM-3]
        } else {
            return availableLiquidity; // U:[LIM-3]
        }
    }
}
