// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {LinearInterestRateModelV3} from "../../../pool/LinearInterestRateModelV3.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// TEST
import "../../lib/constants.sol";

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

import {TestHelper} from "../../lib/helper.sol";

contract LinearInterestRateModelV3UnitTest is TestHelper {
    using Math for uint256;

    LinearInterestRateModelV3 irm;

    function setUp() public {
        irm = new LinearInterestRateModelV3(80_00, 95_00, 10_00, 20_00, 30_00, 40_00, true);
    }

    //
    // TESTS
    //

    // U:[LIM-1]: start parameters are correct
    function test_U_LIM_01_start_parameters_correct() public {
        (uint16 U_1, uint16 U_2, uint16 R_base, uint16 R_slope1, uint16 R_slope2, uint16 R_slope3) =
            irm.getModelParameters();

        assertEq(U_1, 8000);
        assertEq(U_2, 9500);
        assertEq(R_base, 1000);
        assertEq(R_slope1, 2000);
        assertEq(R_slope2, 3000);
        assertEq(R_slope3, 4000);
        assertTrue(irm.isBorrowingMoreU2Forbidden());
    }

    struct IncorrectParamCase {
        string name;
        /// SETUP
        uint16 U_1;
        uint16 U_2;
        uint16 R_base;
        uint16 R_slope1;
        uint16 R_slope2;
        uint16 R_slope3;
    }

    // U:[LIM-2]: linear model constructor reverts for incorrect params
    function test_U_LIM_02_linear_model_constructor_reverts_for_incorrect_params() public {
        // adds liqudity to mint initial diesel tokens to change 1:1 rate

        IncorrectParamCase[8] memory cases = [
            IncorrectParamCase({
                name: "U1 > 100%",
                /// SETUP
                U_1: 100_01,
                U_2: 95_00,
                R_base: 15_00,
                R_slope1: 5_00,
                R_slope2: 10_00,
                R_slope3: 90_00
            }),
            IncorrectParamCase({
                name: "U2 > 100%",
                /// SETUP
                U_1: 10_00,
                U_2: 100_01,
                R_base: 15_00,
                R_slope1: 5_00,
                R_slope2: 10_00,
                R_slope3: 90_00
            }),
            IncorrectParamCase({
                name: "U1 > U2",
                /// SETUP
                U_1: 99_00,
                U_2: 95_00,
                R_base: 15_00,
                R_slope1: 5_00,
                R_slope2: 10_00,
                R_slope3: 90_00
            }),
            IncorrectParamCase({
                name: "Rbase > 100%",
                /// SETUP
                U_1: 10_00,
                U_2: 95_00,
                R_base: 100_01,
                R_slope1: 5_00,
                R_slope2: 10_00,
                R_slope3: 90_00
            }),
            IncorrectParamCase({
                name: "R1 > 100%",
                /// SETUP
                U_1: 10_00,
                U_2: 95_00,
                R_base: 1_00,
                R_slope1: 100_01,
                R_slope2: 10_00,
                R_slope3: 90_00
            }),
            IncorrectParamCase({
                name: "R2 > 100%",
                /// SETUP
                U_1: 10_00,
                U_2: 95_00,
                R_base: 100,
                R_slope1: 5_00,
                R_slope2: 100_01,
                R_slope3: 90_00
            }),
            IncorrectParamCase({
                name: "R1 > R2",
                /// SETUP
                U_1: 10_00,
                U_2: 95_00,
                R_base: 100,
                R_slope1: 80_01,
                R_slope2: 80_00,
                R_slope3: 90_00
            }),
            IncorrectParamCase({
                name: "R2 > R3",
                /// SETUP
                U_1: 10_00,
                U_2: 95_00,
                R_base: 100,
                R_slope1: 5_00,
                R_slope2: 90_01,
                R_slope3: 90_00
            })
        ];

        for (uint256 i; i < cases.length; ++i) {
            IncorrectParamCase memory testCase = cases[i];

            vm.expectRevert(IncorrectParameterException.selector);
            irm = new LinearInterestRateModelV3(
                testCase.U_1,
                testCase.U_2,
                testCase.R_base,
                testCase.R_slope1,
                testCase.R_slope2,
                testCase.R_slope3,
                false
            );
        }
    }

    struct LinearCalculationsCase {
        string name;
        /// SETUP
        uint16 U_1;
        uint16 U_2;
        uint16 R_base;
        uint16 R_slope1;
        uint16 R_slope2;
        uint16 R_slope3;
        bool isBorrowingMoreU2Forbidden;
        /// PARAMS
        uint256 expectedLiquidity;
        uint256 availableLiquidity;
        /// EXPECTED VALUES
        uint256 expectedBorrowRate;
        uint256 expectedAvailableToBorrow;
        bool expectedRevert;
    }

    // U:[LIM-3]: linear model computes available to borrow and borrow rate correctly
    function test_U_LIM_03_linear_model_computes_available_to_borrow_and_borrow_rate_correctly() public {
        // adds liqudity to mint initial diesel tokens to change 1:1 rate

        LinearCalculationsCase[12] memory cases = [
            LinearCalculationsCase({
                name: "0% utilisation [MoreU2borrowing: false]",
                // POOL SETUP
                /// SETUP
                U_1: 80_00,
                U_2: 95_00,
                R_base: 15_00,
                R_slope1: 5_00,
                R_slope2: 10_00,
                R_slope3: 90_00,
                isBorrowingMoreU2Forbidden: false,
                /// PARAMS
                expectedLiquidity: 100,
                availableLiquidity: 100,
                /// EXPECTED VALUES
                // R_base only
                expectedBorrowRate: 15_00 * RAY / PERCENTAGE_FACTOR,
                expectedAvailableToBorrow: 100,
                expectedRevert: false
            }),
            LinearCalculationsCase({
                name: "0% utilisation  [MoreU2borrowing: true]",
                // POOL SETUP
                /// SETUP
                U_1: 80_00,
                U_2: 95_00,
                R_base: 15_00,
                R_slope1: 5_00,
                R_slope2: 10_00,
                R_slope3: 90_00,
                isBorrowingMoreU2Forbidden: true,
                /// PARAMS
                expectedLiquidity: 100,
                availableLiquidity: 100,
                /// EXPECTED VALUES
                // R_base only
                expectedBorrowRate: 15_00 * RAY / PERCENTAGE_FACTOR,
                expectedAvailableToBorrow: 95,
                expectedRevert: false
            }),
            LinearCalculationsCase({
                name: "expectedLiquidity < availableLiquidity [MoreU2borrowing: false]",
                // POOL SETUP
                /// SETUP
                U_1: 80_00,
                U_2: 95_00,
                R_base: 15_00,
                R_slope1: 5_00,
                R_slope2: 10_00,
                R_slope3: 90_00,
                isBorrowingMoreU2Forbidden: false,
                /// PARAMS
                expectedLiquidity: 10,
                availableLiquidity: 100,
                /// EXPECTED VALUES
                // R_base only
                expectedBorrowRate: 15_00 * RAY / PERCENTAGE_FACTOR,
                expectedAvailableToBorrow: 100,
                expectedRevert: false
            }),
            LinearCalculationsCase({
                name: "expectedLiquidity < availableLiquidity  [MoreU2borrowing: true]",
                // POOL SETUP
                /// SETUP
                U_1: 80_00,
                U_2: 95_00,
                R_base: 15_00,
                R_slope1: 5_00,
                R_slope2: 10_00,
                R_slope3: 90_00,
                isBorrowingMoreU2Forbidden: true,
                /// PARAMS
                expectedLiquidity: 10,
                availableLiquidity: 100,
                /// EXPECTED VALUES
                // R_base only
                expectedBorrowRate: 15_00 * RAY / PERCENTAGE_FACTOR,
                expectedAvailableToBorrow: 100,
                expectedRevert: false
            }),
            LinearCalculationsCase({
                name: "0% < utilisation < U1  [MoreU2borrowing: false]",
                // POOL SETUP
                /// SETUP
                U_1: 80_00,
                U_2: 95_00,
                R_base: 15_00,
                R_slope1: 5_00,
                R_slope2: 10_00,
                R_slope3: 90_00,
                isBorrowingMoreU2Forbidden: false,
                /// PARAMS
                expectedLiquidity: 100,
                availableLiquidity: 60,
                /// EXPECTED VALUES
                // 15% + 5% (r1) * 40% (utilisation) / 80% (u1)
                expectedBorrowRate: (15_00 + 5_00 * 40 / 80) * RAY / PERCENTAGE_FACTOR,
                expectedAvailableToBorrow: 60,
                expectedRevert: false
            }),
            LinearCalculationsCase({
                name: "0% < utilisation < U1  [MoreU2borrowing: true]",
                // POOL SETUP
                /// SETUP
                U_1: 80_00,
                U_2: 95_00,
                R_base: 15_00,
                R_slope1: 5_00,
                R_slope2: 10_00,
                R_slope3: 90_00,
                isBorrowingMoreU2Forbidden: true,
                /// PARAMS
                expectedLiquidity: 100,
                availableLiquidity: 60,
                /// EXPECTED VALUES
                // 15% (rBase) + 5% (r1) * 40% (utilisation) / 80% (u1)
                expectedBorrowRate: (15_00 + 5_00 * 40 / 80) * RAY / PERCENTAGE_FACTOR,
                expectedAvailableToBorrow: 55,
                expectedRevert: false
            }),
            LinearCalculationsCase({
                name: "U1 < utilisation < U2  [MoreU2borrowing: false]",
                // POOL SETUP
                /// SETUP
                U_1: 80_00,
                U_2: 95_00,
                R_base: 12_00,
                R_slope1: 5_00,
                R_slope2: 15_00,
                R_slope3: 90_00,
                isBorrowingMoreU2Forbidden: false,
                /// PARAMS
                expectedLiquidity: 100,
                availableLiquidity: 10,
                // EXPECTED VALUES
                // utilisation: 90%
                // 12% (rBase) + 5% (r1) + 15%(r2) * 10% / 15% (u2 - u1)
                expectedBorrowRate: (12_00 + 5_00 + 15_00 * 10 / 15) * RAY / PERCENTAGE_FACTOR,
                expectedAvailableToBorrow: 10,
                expectedRevert: false
            }),
            LinearCalculationsCase({
                name: "U1 < utilisation < U2  [MoreU2borrowing: true]",
                // POOL SETUP
                /// SETUP
                U_1: 80_00,
                U_2: 95_00,
                R_base: 12_00,
                R_slope1: 5_00,
                R_slope2: 15_00,
                R_slope3: 90_00,
                isBorrowingMoreU2Forbidden: true,
                /// PARAMS
                expectedLiquidity: 100,
                availableLiquidity: 10,
                /// EXPECTED VALUES
                // 12% (rBase) + 5% (r1) + 15%(r2) * 10% / 15% (u2 - u1)
                expectedBorrowRate: (12_00 + 5_00 + 15_00 * 10 / 15) * RAY / PERCENTAGE_FACTOR,
                expectedAvailableToBorrow: 5,
                expectedRevert: false
            }),
            LinearCalculationsCase({
                name: "utilisation > U2  [MoreU2borrowing: false]",
                // POOL SETUP
                /// SETUP
                U_1: 80_00,
                U_2: 95_00,
                R_base: 12_00,
                R_slope1: 5_00,
                R_slope2: 15_00,
                R_slope3: 90_00,
                isBorrowingMoreU2Forbidden: false,
                /// PARAMS
                expectedLiquidity: 100,
                availableLiquidity: 2,
                // EXPECTED VALUES
                // utilisation: 90%
                // 12% (rBase) + 5% (r1) + 15% + 90% (r3) * 3% / 5%(1 - u2)
                expectedBorrowRate: (12_00 + 5_00 + 15_00 + 90_00 * 3 / 5) * RAY / PERCENTAGE_FACTOR,
                expectedAvailableToBorrow: 2,
                expectedRevert: false
            }),
            LinearCalculationsCase({
                name: "utilisation > U2  [MoreU2borrowing: true]",
                // POOL SETUP
                /// SETUP
                U_1: 80_00,
                U_2: 95_00,
                R_base: 12_00,
                R_slope1: 5_00,
                R_slope2: 15_00,
                R_slope3: 90_00,
                isBorrowingMoreU2Forbidden: true,
                /// PARAMS
                expectedLiquidity: 100,
                availableLiquidity: 2,
                /// EXPECTED VALUES
                // 12% (rBase) + 5% (r1) + 15% + 90% (r3) * 3% / 5%(1 - u2)
                expectedBorrowRate: (12_00 + 5_00 + 15_00 + 90_00 * 3 / 5) * RAY / PERCENTAGE_FACTOR,
                expectedAvailableToBorrow: 0,
                expectedRevert: true
            }),
            LinearCalculationsCase({
                name: "100% utilisation  [MoreU2borrowing: false]",
                // POOL SETUP
                /// SETUP
                U_1: 80_00,
                U_2: 95_00,
                R_base: 12_00,
                R_slope1: 5_00,
                R_slope2: 15_00,
                R_slope3: 90_00,
                isBorrowingMoreU2Forbidden: false,
                /// PARAMS
                expectedLiquidity: 100,
                availableLiquidity: 0,
                // EXPECTED VALUES
                // utilisation: 90%
                // 12% (rBase) + 5% (r1) + 15% + 90% (r3) * 3% / 5%(1 - u2)
                expectedBorrowRate: (12_00 + 5_00 + 15_00 + 90_00) * RAY / PERCENTAGE_FACTOR,
                expectedAvailableToBorrow: 0,
                expectedRevert: false
            }),
            LinearCalculationsCase({
                name: "100% utilisation  [MoreU2borrowing: true]",
                // POOL SETUP
                /// SETUP
                U_1: 80_00,
                U_2: 95_00,
                R_base: 12_00,
                R_slope1: 5_00,
                R_slope2: 15_00,
                R_slope3: 90_00,
                isBorrowingMoreU2Forbidden: true,
                /// PARAMS
                expectedLiquidity: 100,
                availableLiquidity: 0,
                /// EXPECTED VALUES
                // 12% (rBase) + 5% (r1) + 15% + 90% (r3) * 3% / 5%(1 - u2)
                expectedBorrowRate: (12_00 + 5_00 + 15_00 + 90_00) * RAY / PERCENTAGE_FACTOR,
                expectedAvailableToBorrow: 0,
                expectedRevert: true
            })
        ];

        for (uint256 i; i < cases.length; ++i) {
            LinearCalculationsCase memory testCase = cases[i];

            irm = new LinearInterestRateModelV3(
                testCase.U_1,
                testCase.U_2,
                testCase.R_base,
                testCase.R_slope1,
                testCase.R_slope2,
                testCase.R_slope3,
                testCase.isBorrowingMoreU2Forbidden
            );

            if (testCase.expectedRevert) {
                vm.expectRevert(BorrowingMoreThanU2ForbiddenException.selector);
            }

            irm.calcBorrowRate(testCase.expectedLiquidity, testCase.availableLiquidity, true);

            assertEq(
                irm.calcBorrowRate(testCase.expectedLiquidity, testCase.availableLiquidity, false),
                testCase.expectedBorrowRate,
                _testCaseErr(testCase.name, "Borrow rate isn't computed correcty")
            );

            assertEq(
                irm.availableToBorrow(testCase.expectedLiquidity, testCase.availableLiquidity),
                testCase.expectedAvailableToBorrow,
                _testCaseErr(testCase.name, "availableToBorrow isn't computed correcty")
            );
        }
    }
}
