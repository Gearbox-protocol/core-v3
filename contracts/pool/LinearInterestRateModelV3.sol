// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {ILinearInterestRateModelV3} from "../interfaces/ILinearInterestRateModelV3.sol";
import {IncorrectParameterException, BorrowingMoreThanU2ForbiddenException} from "../interfaces/IExceptions.sol";

import {PERCENTAGE_FACTOR, RAY, RAY_OVER_PERCENTAGE, WAD, WAD_OVER_PERCENTAGE} from "../libraries/Constants.sol";

/// @title Linear interest rate model V3
/// @notice Gearbox V3 uses a two-point linear interest rate model in its pools.
///         Unlike previous single-point models, it has a new intermediate slope between the obtuse and steep regions
///         which serves to decrease interest rate jumps due to large withdrawals.
///         The model can also be configured to prevent borrowing after in the steep region (over `U_2` utilization)
///         in order to create a reserve for exits and make rates more stable.
contract LinearInterestRateModelV3 is ILinearInterestRateModelV3 {
    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Whether to prevent borrowing over `U_2` utilization
    bool public immutable override isBorrowingMoreU2Forbidden;

    /// @notice The first slope change point (obtuse -> intermediate region)
    uint256 internal immutable U_1_WAD;

    /// @notice The second slope change point (intermediate -> steep region)
    uint256 internal immutable U_2_WAD;

    /// @notice Base interest rate in RAY format
    uint256 internal immutable R_base_RAY;

    /// @notice Slope of the obtuse region
    uint256 internal immutable R_slope1_RAY;

    /// @notice Slope of the intermediate region
    uint256 internal immutable R_slope2_RAY;

    /// @notice Slope of the steep region
    uint256 internal immutable R_slope3_RAY;

    /// @notice Constructor
    /// @param U_1 `U_1` in basis points
    /// @param U_2 `U_2` in basis points
    /// @param R_base `R_base` in basis points
    /// @param R_slope1 `R_slope1` in basis points
    /// @param R_slope2 `R_slope2` in basis points
    /// @param R_slope3 `R_slope3` in basis points
    /// @param _isBorrowingMoreU2Forbidden Whether to prevent borrowing over `U_2` utilization
    /// @custom:tests U:[LIM-1], U:[LIM-2]
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
            U_2 >= PERCENTAGE_FACTOR || U_1 > U_2 || R_base > PERCENTAGE_FACTOR || R_slope2 > PERCENTAGE_FACTOR
                || R_slope1 > R_slope2 || R_slope2 > R_slope3
        ) revert IncorrectParameterException();

        // critical utilization points are stored in WAD format
        U_1_WAD = U_1 * WAD_OVER_PERCENTAGE;
        U_2_WAD = U_2 * WAD_OVER_PERCENTAGE;

        // slopes are stored in RAY format
        R_base_RAY = R_base * RAY_OVER_PERCENTAGE;
        R_slope1_RAY = R_slope1 * RAY_OVER_PERCENTAGE;
        R_slope2_RAY = R_slope2 * RAY_OVER_PERCENTAGE;
        R_slope3_RAY = R_slope3 * RAY_OVER_PERCENTAGE;

        isBorrowingMoreU2Forbidden = _isBorrowingMoreU2Forbidden;
    }

    /// @notice Returns the borrow rate calculated based on expected and available liquidity
    /// @param expectedLiquidity Expected liquidity in the pool
    /// @param availableLiquidity Available liquidity in the pool
    /// @param checkOptimalBorrowing Whether to check if borrowing over `U_2` utilization should be prevented
    /// @custom:tests U:[LIM-3], U:[LIM-4]
    function calcBorrowRate(uint256 expectedLiquidity, uint256 availableLiquidity, bool checkOptimalBorrowing)
        public
        view
        override
        returns (uint256)
    {
        if (expectedLiquidity <= availableLiquidity) {
            return R_base_RAY;
        }

        //      expectedLiquidity - availableLiquidity
        // U = ----------------------------------------
        //                expectedLiquidity

        uint256 U_WAD = (WAD * (expectedLiquidity - availableLiquidity)) / expectedLiquidity;

        // If U <= U_1:
        //                                    U
        // borrowRate = R_base + R_slope1 * -----
        //                                   U_1

        if (U_WAD <= U_1_WAD) {
            return R_base_RAY + ((R_slope1_RAY * U_WAD) / U_1_WAD);
        }

        // if U > U_1 & U <= U_2:
        //                                               U  - U_1
        // borrowRate = R_base + R_slope1 + R_slope2 * -----------
        //                                              U_2 - U_1

        if (U_WAD <= U_2_WAD) {
            return R_base_RAY + R_slope1_RAY + (R_slope2_RAY * (U_WAD - U_1_WAD)) / (U_2_WAD - U_1_WAD);
        }

        // if U > U_2 in `isBorrowingMoreU2Forbidden` and the utilization check is requested,
        // the function will revert to prevent raising utilization over the limit
        if (checkOptimalBorrowing && isBorrowingMoreU2Forbidden) {
            revert BorrowingMoreThanU2ForbiddenException();
        }

        // if U > U_2:
        //                                                         U - U_2
        // borrowRate = R_base + R_slope1 + R_slope2 + R_slope3 * ----------
        //                                                         1 - U_2

        return R_base_RAY + R_slope1_RAY + R_slope2_RAY + R_slope3_RAY * (U_WAD - U_2_WAD) / (WAD - U_2_WAD);
    }

    /// @notice Returns the model's parameters in basis points
    /// @custom:tests U:[LIM-1]
    function getModelParameters()
        external
        view
        override
        returns (uint16 U_1, uint16 U_2, uint16 R_base, uint16 R_slope1, uint16 R_slope2, uint16 R_slope3)
    {
        U_1 = uint16(U_1_WAD / WAD_OVER_PERCENTAGE);
        U_2 = uint16(U_2_WAD / WAD_OVER_PERCENTAGE);
        R_base = uint16(R_base_RAY / RAY_OVER_PERCENTAGE);
        R_slope1 = uint16(R_slope1_RAY / RAY_OVER_PERCENTAGE);
        R_slope2 = uint16(R_slope2_RAY / RAY_OVER_PERCENTAGE);
        R_slope3 = uint16(R_slope3_RAY / RAY_OVER_PERCENTAGE);
    }

    /// @notice Returns the amount available to borrow
    ///         - If borrowing over `U_2` is prohibited, returns the amount that can be borrowed before `U_2` is reached
    ///         - Otherwise, simply returns the available liquidity
    /// @custom:tests U:[LIM-3], U:[LIM-4]
    function availableToBorrow(uint256 expectedLiquidity, uint256 availableLiquidity)
        external
        view
        override
        returns (uint256)
    {
        if (isBorrowingMoreU2Forbidden && expectedLiquidity != 0) {
            uint256 minAvailableLiquidity = expectedLiquidity - expectedLiquidity * U_2_WAD / WAD;
            return availableLiquidity > minAvailableLiquidity ? availableLiquidity - minAvailableLiquidity : 0;
        } else {
            return availableLiquidity;
        }
    }
}
