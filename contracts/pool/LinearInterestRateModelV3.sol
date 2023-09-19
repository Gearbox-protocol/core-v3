// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;
pragma abicoder v1;

import {WAD, RAY, PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {ILinearInterestRateModelV3} from "../interfaces/ILinearInterestRateModelV3.sol";

// EXCEPTIONS
import {IncorrectParameterException, BorrowingMoreThanU2ForbiddenException} from "../interfaces/IExceptions.sol";

/// @title Linear interest rate model V3
/// @notice Gearbox V3 uses a two-point linear interest rate model in its pools.
///         Unlike previous single-point models, it has a new intermediate slope between the obtuse and steep regions
///         which serves to decrease interest rate jumps due to large withdrawals.
///         The model can also be configured to prevent borrowing after in the steep region (over `U_2` utilization)
///         in order to create a reserve for exits and make rates more stable.
contract LinearInterestRateModelV3 is ILinearInterestRateModelV3 {
    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice Whether to prevent borrowing over `U_2` utilization
    bool public immutable override isBorrowingMoreU2Forbidden;

    /// @notice The first slope change point (obtuse -> intermediate region)
    uint256 public immutable U_1_WAD;

    /// @notice The second slope change point (intermediate -> steep region)
    uint256 public immutable U_2_WAD;

    /// @notice Base interest rate in RAY format
    uint256 public immutable R_base_RAY;

    /// @notice Slope of the obtuse region
    uint256 public immutable R_slope1_RAY;

    /// @notice Slope of the intermediate region
    uint256 public immutable R_slope2_RAY;

    /// @notice Slope of the steep region
    uint256 public immutable R_slope3_RAY;

    /// @notice Constructor
    /// @param U_1 `U_1` in basis points
    /// @param U_2 `U_2` in basis points
    /// @param R_base `R_base` in basis points
    /// @param R_slope1 `R_slope1` in basis points
    /// @param R_slope2 `R_slope2` in basis points
    /// @param R_slope3 `R_slope3` in basis points
    /// @param _isBorrowingMoreU2Forbidden Whether to prevent borrowing over `U_2` utilization
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

        U_1_WAD = U_1 * (WAD / PERCENTAGE_FACTOR); // U:[LIM-1]
        U_2_WAD = U_2 * (WAD / PERCENTAGE_FACTOR); // U:[LIM-1]

        /// Slopes are stored in RAY format
        R_base_RAY = R_base * (RAY / PERCENTAGE_FACTOR); // U:[LIM-1]
        R_slope1_RAY = R_slope1 * (RAY / PERCENTAGE_FACTOR); // U:[LIM-1]
        R_slope2_RAY = R_slope2 * (RAY / PERCENTAGE_FACTOR); // U:[LIM-1]
        R_slope3_RAY = R_slope3 * (RAY / PERCENTAGE_FACTOR); // U:[LIM-1]

        isBorrowingMoreU2Forbidden = _isBorrowingMoreU2Forbidden; // U:[LIM-1]
    }

    /// @dev Same as the next one with `checkOptimalBorrowing` set to `false`, added for compatibility with older pools
    function calcBorrowRate(uint256 expectedLiquidity, uint256 availableLiquidity) external view returns (uint256) {
        return calcBorrowRate(expectedLiquidity, availableLiquidity, false);
    }

    /// @notice Returns the borrow rate calculated based on expected and available liquidity
    /// @param expectedLiquidity Expected liquidity in the pool
    /// @param availableLiquidity Available liquidity in the pool
    /// @param checkOptimalBorrowing Whether to check if borrowing over `U_2` utilization should be prevented
    function calcBorrowRate(uint256 expectedLiquidity, uint256 availableLiquidity, bool checkOptimalBorrowing)
        public
        view
        override
        returns (uint256)
    {
        if (expectedLiquidity <= availableLiquidity) {
            return R_base_RAY; // U:[LIM-3]
        }

        //      expectedLiquidity - availableLiquidity
        // U = ----------------------------------------
        //                expectedLiquidity

        uint256 U_WAD = (WAD * (expectedLiquidity - availableLiquidity)) / expectedLiquidity; // U:[LIM-3]

        // If U < U_1:
        //                                    U
        // borrowRate = R_base + R_slope1 * -----
        //                                   U_1

        if (U_WAD < U_1_WAD) {
            return R_base_RAY + ((R_slope1_RAY * U_WAD) / U_1_WAD); // U:[LIM-3]
        }

        // If U >= U_1 & U < U_2:
        //                                               U  - U_1
        // borrowRate = R_base + R_slope1 + R_slope2 * -----------
        //                                              U_2 - U_1

        if (U_WAD < U_2_WAD) {
            return R_base_RAY + R_slope1_RAY + (R_slope2_RAY * (U_WAD - U_1_WAD)) / (U_2_WAD - U_1_WAD); // U:[LIM-3]
        }

        // If U > U_2 in `isBorrowingMoreU2Forbidden` and the utilization check is requested,
        // the function will revert to prevent raising utilization over the limit
        if (checkOptimalBorrowing && isBorrowingMoreU2Forbidden) {
            revert BorrowingMoreThanU2ForbiddenException(); // U:[LIM-3]
        }

        // If U >= U_2:
        //                                                         U - U_2
        // borrowRate = R_base + R_slope1 + R_slope2 + R_slope3 * ----------
        //                                                         1 - U_2

        return R_base_RAY + R_slope1_RAY + R_slope2_RAY + R_slope3_RAY * (U_WAD - U_2_WAD) / (WAD - U_2_WAD); // U:[LIM-3]
    }

    /// @notice Returns the model's parameters in basis points
    function getModelParameters()
        external
        view
        override
        returns (uint16 U_1, uint16 U_2, uint16 R_base, uint16 R_slope1, uint16 R_slope2, uint16 R_slope3)
    {
        U_1 = uint16(U_1_WAD / (WAD / PERCENTAGE_FACTOR)); // U:[LIM-1]
        U_2 = uint16(U_2_WAD / (WAD / PERCENTAGE_FACTOR)); // U:[LIM-1]
        R_base = uint16(R_base_RAY / (RAY / PERCENTAGE_FACTOR)); // U:[LIM-1]
        R_slope1 = uint16(R_slope1_RAY / (RAY / PERCENTAGE_FACTOR)); // U:[LIM-1]
        R_slope2 = uint16(R_slope2_RAY / (RAY / PERCENTAGE_FACTOR)); // U:[LIM-1]
        R_slope3 = uint16(R_slope3_RAY / (RAY / PERCENTAGE_FACTOR)); // U:[LIM-1]
    }

    /// @notice Returns the amount available to borrow
    ///         - If borrowing over `U_2` is prohibited, returns the amount that can be borrowed before `U_2` is reached
    ///         - Otherwise, simply returns the available liquidity
    function availableToBorrow(uint256 expectedLiquidity, uint256 availableLiquidity)
        external
        view
        override
        returns (uint256)
    {
        if (isBorrowingMoreU2Forbidden && (expectedLiquidity >= availableLiquidity) && (expectedLiquidity != 0)) {
            uint256 U_WAD = (WAD * (expectedLiquidity - availableLiquidity)) / expectedLiquidity; // U:[LIM-3]

            return (U_WAD < U_2_WAD) ? ((U_2_WAD - U_WAD) * expectedLiquidity) / WAD : 0; // U:[LIM-3]
        } else {
            return availableLiquidity; // U:[LIM-3]
        }
    }
}
