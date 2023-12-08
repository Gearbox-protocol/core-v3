// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {CreditLogic} from "../../../libraries/CreditLogic.sol";
import {CollateralDebtData} from "../../../interfaces/ICreditManagerV3.sol";
import {TestHelper} from "../../lib/helper.sol";
import {GeneralMock} from "../../mocks/GeneralMock.sol";

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {RAY, WAD} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

/// @title Credit logic unit test
/// @notice U:[CL]: Unit tests for `CreditLogic` library
contract CreditLogicUnitTest is TestHelper {
    uint256 public constant TEST_FEE = 50;

    // ------------- //
    // FUZZING TESTS //
    // ------------- //

    /// @notice U:[CL-1]: `calcAccruedInterest` works correctly
    function test_U_CL_01_calcAccruedInterest_works_correctly(
        uint256 amount,
        uint256 indexLastUpdate,
        uint256 interestRate,
        uint256 timeDiff
    ) public {
        amount = bound(amount, 0, type(uint128).max);
        indexLastUpdate = bound(indexLastUpdate, RAY, 10 * RAY);
        interestRate = bound(interestRate, RAY / 1000, RAY);
        timeDiff = bound(timeDiff, 0, 2000 days);

        uint256 timestampLastUpdate = block.timestamp;
        vm.warp(block.timestamp + timeDiff);
        uint256 indexNow = _getIndexNow(indexLastUpdate, interestRate, timestampLastUpdate);

        // accrued interest computed by pool and by credit manager is roughly the same
        uint256 expectedInterest = amount * CreditLogic.calcLinearGrowth(interestRate, timestampLastUpdate) / RAY;
        uint256 interest = CreditLogic.calcAccruedInterest(amount, indexLastUpdate, indexNow);
        assertApproxEqAbs(interest, expectedInterest, amount / 1e18);
    }

    /// @notice U:[CL-2]: `calcIncrease` works correctly
    function test_U_CL_02_calcIncrease_works_correctly(
        uint256 amount,
        uint256 debt,
        uint256 indexLastUpdate,
        uint256 interestRate,
        uint256 timeDiff
    ) public {
        amount = bound(amount, 0, type(uint128).max);
        debt = bound(debt, 0, type(uint128).max);
        indexLastUpdate = bound(indexLastUpdate, RAY, 10 * RAY);
        interestRate = bound(interestRate, RAY / 1000, RAY);
        timeDiff = bound(timeDiff, 0, 2000 days);

        uint256 timestampLastUpdate = block.timestamp;
        vm.warp(block.timestamp + timeDiff);
        uint256 indexNow = _getIndexNow(indexLastUpdate, interestRate, timestampLastUpdate);

        (uint256 newDebt, uint256 newIndex) = CreditLogic.calcIncrease(amount, debt, indexNow, indexLastUpdate);

        // new debt is correct
        assertEq(newDebt, debt + amount, "New debt is incorrect");

        // index increases but not beyond current index
        assertGe(newIndex, indexLastUpdate, "New index is smaller than old index");
        assertLe(newIndex, indexNow, "New index is greater than current index");

        // base interest stays roughly the same (errors in favor of the pool)
        uint256 baseInterest = CreditLogic.calcAccruedInterest(debt, indexLastUpdate, indexNow);
        uint256 newBaseInterest = CreditLogic.calcAccruedInterest(newDebt, newIndex, indexNow);
        assertGe(newBaseInterest, baseInterest, "Base interest decreased");
        assertLe(newBaseInterest, baseInterest + newDebt / 1e18, "Base interest increased too much");
    }

    /// @notice U:[CL-3A]: `calcDecrease` works correctly
    function test_U_CL_03_calcDecrease_works_correctly(
        uint256 amount,
        uint256 debt,
        uint256 indexLastUpdate,
        uint256 interestRate,
        uint256 timeDiff,
        uint128 quotaInterest,
        uint128 quotaFees,
        uint16 feeInterest
    ) public {
        debt = bound(debt, 1, type(uint128).max);
        indexLastUpdate = bound(indexLastUpdate, RAY, 10 * RAY);
        interestRate = bound(interestRate, RAY / 1000, RAY);
        timeDiff = bound(timeDiff, 0, 2000 days);
        quotaInterest = uint128(bound(quotaInterest, 0, type(uint96).max));
        quotaFees = uint128(bound(quotaFees, 0, type(uint96).max));
        feeInterest = uint16(bound(feeInterest, 0, PERCENTAGE_FACTOR));

        uint256 timestampLastUpdate = block.timestamp;
        vm.warp(block.timestamp + timeDiff);
        uint256 indexNow = _getIndexNow(indexLastUpdate, interestRate, timestampLastUpdate);

        amount = bound(amount, 0, _getTotalDebt(debt, indexNow, indexLastUpdate, quotaInterest, quotaFees, feeInterest));

        _calcDecrease__debtChecks(amount, debt, indexNow, indexLastUpdate, quotaInterest, quotaFees, feeInterest);
        _calcDecrease__profitChecks(amount, debt, indexNow, indexLastUpdate, quotaInterest, quotaFees, feeInterest);
        _calcDecrease__interestChecks(amount, debt, indexNow, indexLastUpdate, quotaInterest, quotaFees, feeInterest);
        _calcDecrease__quotasChecks(amount, debt, indexNow, indexLastUpdate, quotaInterest, quotaFees, feeInterest);
    }

    function _calcDecrease__debtChecks(
        uint256 amount,
        uint256 debt,
        uint256 indexNow,
        uint256 indexLastUpdate,
        uint128 quotaInterest,
        uint128 quotaFees,
        uint16 feeInterest
    ) internal {
        (uint256 newDebt, uint256 newIndex,, uint128 newQuotaInterest, uint128 newQuotaFees) =
            CreditLogic.calcDecrease(amount, debt, indexNow, indexLastUpdate, quotaInterest, quotaFees, feeInterest);

        uint256 totalDebt = _getTotalDebt(debt, indexNow, indexLastUpdate, quotaInterest, quotaFees, feeInterest);
        uint256 newTotalDebt = _getTotalDebt(newDebt, indexNow, newIndex, newQuotaInterest, newQuotaFees, feeInterest);

        assertLe(newDebt, debt, "Debt increased");
        assertLe(newTotalDebt, totalDebt, "Total debt increased");
        assertApproxEqAbs(totalDebt - newTotalDebt, amount, 2 + totalDebt / 1e18, "Incorrect amount repaid");

        if (amount < totalDebt) {
            assertGt(newTotalDebt, 0, "Zero total debt after partial repayment");
        }
    }

    function _calcDecrease__profitChecks(
        uint256 amount,
        uint256 debt,
        uint256 indexNow,
        uint256 indexLastUpdate,
        uint128 quotaInterest,
        uint128 quotaFees,
        uint16 feeInterest
    ) internal {
        (uint256 newDebt,, uint256 profit,,) =
            CreditLogic.calcDecrease(amount, debt, indexNow, indexLastUpdate, quotaInterest, quotaFees, feeInterest);

        uint256 accruedFees = _getAccruedFees(debt, indexNow, indexLastUpdate, quotaInterest, quotaFees, feeInterest);
        // NOTE: + 1 because we do have a rounding issue however it can't be used to harm the protocol
        // namely, this line rounds up: `profit += amountToRepay - amountToPool;`
        assertLe(profit, accruedFees + 1, "Profit more than it can be");

        if (newDebt < debt) {
            assertEq(profit, accruedFees, "Incorrect profit after repaying all interest and fees");
        }
    }

    function _calcDecrease__interestChecks(
        uint256 amount,
        uint256 debt,
        uint256 indexNow,
        uint256 indexLastUpdate,
        uint128 quotaInterest,
        uint128 quotaFees,
        uint16 feeInterest
    ) internal {
        (uint256 newDebt, uint256 newIndex,,,) =
            CreditLogic.calcDecrease(amount, debt, indexNow, indexLastUpdate, quotaInterest, quotaFees, feeInterest);

        assertGe(newIndex, indexLastUpdate, "New index is smaller than old index");
        assertLe(newIndex, indexNow, "New index is greater than current index");

        uint256 baseInterest = CreditLogic.calcAccruedInterest(debt, indexLastUpdate, indexNow);
        uint256 newBaseInterest = CreditLogic.calcAccruedInterest(newDebt, newIndex, indexNow);
        assertLe(newBaseInterest, baseInterest, "Base interest increased");

        if (newDebt < debt) {
            assertEq(newIndex, indexNow, "Incorrect index after repaying all interest and fees");
        }
    }

    function _calcDecrease__quotasChecks(
        uint256 amount,
        uint256 debt,
        uint256 indexNow,
        uint256 indexLastUpdate,
        uint128 quotaInterest,
        uint128 quotaFees,
        uint16 feeInterest
    ) internal {
        (uint256 newDebt,,, uint128 newQuotaInterest, uint128 newQuotaFees) =
            CreditLogic.calcDecrease(amount, debt, indexNow, indexLastUpdate, quotaInterest, quotaFees, feeInterest);

        assertLe(newQuotaInterest, quotaInterest, "Quota interest increased");
        assertLe(newQuotaFees, quotaFees, "Quota fees increased");

        if (newDebt < debt) {
            assertEq(newQuotaInterest, 0, "Quota interest not zero after repaying all interest and fees");
            assertEq(newQuotaFees, 0, "Quota fees not zero after repaying all interest and fees");
        }
    }

    // ---------- //
    // CASE TESTS //
    // ---------- //

    struct CalcLiquidationPaymentsTestCase {
        string name;
        bool withFee;
        uint16 liquidationDiscount;
        uint16 feeLiquidation;
        uint16 feeInterest;
        uint256 totalValue;
        uint256 debt;
        uint256 accruedInterest;
        uint256 amountToPool;
        uint256 remainingFunds;
        uint256 profit;
        uint256 loss;
    }

    /// @notice U:[CL-4]: `calcLiquidationPayments` gives expected outputs
    function test_U_CL_04_calcLiquidationPayments_case_test() public {
        /// FEE INTEREST: 50%
        /// NORMAL LIQUIDATION PREMIUM: 4%
        /// NORMAL LIQUIDATION FEE: 1.5%
        /// EXPIRE LIQUIDATION PREMIUM: 2%
        /// EXPIRE LIQUIDATION FEE: 1%
        /// TOKEN FEE: 0.5%

        CalcLiquidationPaymentsTestCase[9] memory cases = [
            CalcLiquidationPaymentsTestCase({
                name: "NORMAL LIQUIDATION WITH PROFIT AND REMAINING FUNDS",
                withFee: false,
                liquidationDiscount: 9600,
                feeLiquidation: 150,
                feeInterest: 5000,
                totalValue: 10000,
                debt: 5000,
                accruedInterest: 2000,
                amountToPool: 8150,
                remainingFunds: 1450,
                profit: 1150,
                loss: 0
            }),
            CalcLiquidationPaymentsTestCase({
                name: "NORMAL LIQUIDATION WITH PROFIT AND NO REMAINING FUNDS",
                withFee: false,
                liquidationDiscount: 9600,
                feeLiquidation: 150,
                feeInterest: 5000,
                totalValue: 10000,
                debt: 6500,
                accruedInterest: 2000,
                amountToPool: 9600,
                remainingFunds: 0,
                profit: 1100,
                loss: 0
            }),
            CalcLiquidationPaymentsTestCase({
                name: "NORMAL LIQUIDATION WITH LOSS",
                withFee: false,
                liquidationDiscount: 9600,
                feeLiquidation: 150,
                feeInterest: 5000,
                totalValue: 10000,
                debt: 7000,
                accruedInterest: 3000,
                amountToPool: 9600,
                remainingFunds: 0,
                profit: 0,
                loss: 400
            }),
            CalcLiquidationPaymentsTestCase({
                name: "EXPIRED LIQUIDATION WITH PROFIT AND REMAINING FUNDS",
                withFee: false,
                liquidationDiscount: 9800,
                feeLiquidation: 100,
                feeInterest: 5000,
                totalValue: 10000,
                debt: 5000,
                accruedInterest: 2000,
                amountToPool: 8100,
                remainingFunds: 1700,
                profit: 1100,
                loss: 0
            }),
            CalcLiquidationPaymentsTestCase({
                name: "EXPIRED LIQUIDATION WITH PROFIT AND NO REMAINING FUNDS",
                withFee: false,
                liquidationDiscount: 9800,
                feeLiquidation: 100,
                feeInterest: 5000,
                totalValue: 10000,
                debt: 6800,
                accruedInterest: 2000,
                amountToPool: 9800,
                remainingFunds: 0,
                profit: 1000,
                loss: 0
            }),
            CalcLiquidationPaymentsTestCase({
                name: "EXPIRED LIQUIDATION WITH LOSS",
                withFee: false,
                liquidationDiscount: 9800,
                feeLiquidation: 100,
                feeInterest: 5000,
                totalValue: 10000,
                debt: 7000,
                accruedInterest: 3000,
                amountToPool: 9800,
                remainingFunds: 0,
                profit: 0,
                loss: 200
            }),
            CalcLiquidationPaymentsTestCase({
                name: "NORMAL LIQUIDATION WITH PROFIT AND REMAINING FUNDS + FEE",
                withFee: true,
                liquidationDiscount: 9600,
                feeLiquidation: 150,
                feeInterest: 5000,
                totalValue: 10000,
                debt: 5000,
                accruedInterest: 2000,
                amountToPool: 8190,
                remainingFunds: 1410,
                profit: 1150,
                loss: 0
            }),
            CalcLiquidationPaymentsTestCase({
                name: "NORMAL LIQUIDATION WITH PROFIT AND NO REMAINING FUNDS + FEE",
                withFee: true,
                liquidationDiscount: 9600,
                feeLiquidation: 150,
                feeInterest: 5000,
                totalValue: 10000,
                debt: 6500,
                accruedInterest: 2000,
                amountToPool: 9600,
                remainingFunds: 0,
                profit: 1052,
                loss: 0
            }),
            CalcLiquidationPaymentsTestCase({
                name: "NORMAL LIQUIDATION WITH LOSS + FEE",
                withFee: true,
                liquidationDiscount: 9600,
                feeLiquidation: 150,
                feeInterest: 5000,
                totalValue: 10000,
                debt: 7000,
                accruedInterest: 3000,
                amountToPool: 9600,
                remainingFunds: 0,
                profit: 0,
                loss: 448
            })
        ];

        for (uint256 i = 0; i < cases.length; i++) {
            CollateralDebtData memory cdd;

            cdd.totalValue = cases[i].totalValue;
            cdd.debt = cases[i].debt;
            cdd.accruedInterest = cases[i].accruedInterest;
            cdd.accruedFees = cases[i].accruedInterest * cases[i].feeInterest / PERCENTAGE_FACTOR;

            (uint256 amountToPool, uint256 remainingFunds, uint256 profit, uint256 loss) = CreditLogic
                .calcLiquidationPayments(
                cdd,
                cases[i].feeLiquidation,
                cases[i].liquidationDiscount,
                cases[i].withFee ? _amountWithFee : _amountWithoutFee,
                cases[i].withFee ? _amountMinusFee : _amountWithoutFee
            );

            assertEq(amountToPool, cases[i].amountToPool, string(abi.encodePacked(cases[i].name, ": amountToPool")));
            assertEq(
                remainingFunds, cases[i].remainingFunds, string(abi.encodePacked(cases[i].name, ": remainingFunds"))
            );
            assertEq(profit, cases[i].profit, string(abi.encodePacked(cases[i].name, ": profit")));
            assertEq(loss, cases[i].loss, string(abi.encodePacked(cases[i].name, ": loss")));
        }
    }

    struct LiquidationThresholdTestCase {
        string name;
        uint16 ltInitial;
        uint16 ltFinal;
        uint40 timestampRampStart;
        uint24 rampDuration;
        uint16 expectedLT;
    }

    /// @notice U:[CL-5]: `getLiquidationThreshold` gives expected outputs
    function test_U_CL_05_getLiquidationThreshold_case_test() public {
        LiquidationThresholdTestCase[6] memory cases = [
            LiquidationThresholdTestCase({
                name: "LIQUIDATION THRESHOLD RAMP IN THE FUTURE",
                ltInitial: 4000,
                ltFinal: 6000,
                timestampRampStart: uint40(block.timestamp + 1000),
                rampDuration: 3600,
                expectedLT: 4000
            }),
            LiquidationThresholdTestCase({
                name: "LIQUIDATION THRESHOLD RAMP IN THE PAST",
                ltInitial: 4000,
                ltFinal: 6000,
                timestampRampStart: uint40(block.timestamp - 10000),
                rampDuration: 3600,
                expectedLT: 6000
            }),
            LiquidationThresholdTestCase({
                name: "LIQUIDATION THRESHOLD RAMP ONE-THIRD WAY ASCENDING",
                ltInitial: 3000,
                ltFinal: 6000,
                timestampRampStart: uint40(block.timestamp - 5000),
                rampDuration: 15000,
                expectedLT: 4000
            }),
            LiquidationThresholdTestCase({
                name: "LIQUIDATION THRESHOLD RAMP ONE-HALF WAY ASCENDING",
                ltInitial: 4500,
                ltFinal: 5000,
                timestampRampStart: uint40(block.timestamp - 7500),
                rampDuration: 15000,
                expectedLT: 4750
            }),
            LiquidationThresholdTestCase({
                name: "LIQUIDATION THRESHOLD RAMP ONE-THIRD WAY DESCENDING",
                ltInitial: 2000,
                ltFinal: 1000,
                timestampRampStart: uint40(block.timestamp - 5000),
                rampDuration: 15000,
                expectedLT: 1666
            }),
            LiquidationThresholdTestCase({
                name: "LIQUIDATION THRESHOLD RAMP ONE-HALF WAY DESCENDING",
                ltInitial: 9000,
                ltFinal: 8900,
                timestampRampStart: uint40(block.timestamp - 7500),
                rampDuration: 15000,
                expectedLT: 8950
            })
        ];

        for (uint256 i = 0; i < cases.length; i++) {
            assertEq(
                CreditLogic.getLiquidationThreshold({
                    ltInitial: cases[i].ltInitial,
                    ltFinal: cases[i].ltFinal,
                    timestampRampStart: cases[i].timestampRampStart,
                    rampDuration: cases[i].rampDuration
                }),
                cases[i].expectedLT,
                string(abi.encodePacked(cases[i].name, ": LT"))
            );
        }
    }

    // ------- //
    // HELPERS //
    // ------- //

    function _getIndexNow(uint256 indexLastUpdate, uint256 interestRate, uint256 timestampLastUpdate)
        internal
        view
        returns (uint256)
    {
        return indexLastUpdate * (RAY + CreditLogic.calcLinearGrowth(interestRate, timestampLastUpdate)) / RAY;
    }

    function _getAccruedFees(
        uint256 debt,
        uint256 indexNow,
        uint256 indexLastUpdate,
        uint256 quotaInterest,
        uint256 quotaFees,
        uint16 feeInterest
    ) internal pure returns (uint256) {
        uint256 baseInterest = CreditLogic.calcAccruedInterest(debt, indexLastUpdate, indexNow);
        // forgefmt: disable-next-item
        return quotaFees
            + quotaInterest * feeInterest / PERCENTAGE_FACTOR
            + baseInterest * feeInterest / PERCENTAGE_FACTOR;
    }

    function _getTotalDebt(
        uint256 debt,
        uint256 indexNow,
        uint256 indexLastUpdate,
        uint256 quotaInterest,
        uint256 quotaFees,
        uint16 feeInterest
    ) internal pure returns (uint256) {
        uint256 baseInterest = CreditLogic.calcAccruedInterest(debt, indexLastUpdate, indexNow);
        return debt + baseInterest + quotaInterest
            + _getAccruedFees(debt, indexNow, indexLastUpdate, quotaInterest, quotaFees, feeInterest);
    }

    function _amountWithoutFee(uint256 a) internal pure returns (uint256) {
        return a;
    }

    function _amountWithFee(uint256 a) internal pure returns (uint256) {
        return a * (TEST_FEE + PERCENTAGE_FACTOR) / PERCENTAGE_FACTOR;
    }

    function _amountMinusFee(uint256 a) internal pure returns (uint256) {
        return a * (PERCENTAGE_FACTOR - TEST_FEE) / PERCENTAGE_FACTOR;
    }
}
