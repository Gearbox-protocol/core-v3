// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IncorrectParameterException} from "../../../interfaces/IExceptions.sol";
import {CreditLogic} from "../../../libraries/CreditLogic.sol";
import {ClosureAction, CollateralDebtData} from "../../../interfaces/ICreditManagerV3.sol";
import {TestHelper} from "../../lib/helper.sol";

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";
import {RAY, WAD} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

import "forge-std/console.sol";

/// @title BitMask logic test
/// @notice [BM]: Unit tests for bit mask library
contract CreditLogicTest is TestHelper {
    function _calcDiff(uint256 a, uint256 b) internal pure returns (uint256 diff) {
        diff = a > b ? a - b : b - a;
    }

    function _calcTotalDebt(
        uint256 debt,
        uint256 indexNow,
        uint256 indexOpen,
        uint256 quotaInterest,
        uint16 feeInterest
    ) internal view returns (uint256) {
        return debt
            + (debt * indexNow / indexOpen + quotaInterest - debt) * (PERCENTAGE_FACTOR + feeInterest) / PERCENTAGE_FACTOR;
    }

    /// @notice U:[CL-1]: `calcIndex` reverts for zero value
    function test_CL_01_calcIndex_reverts_for_zero_value() public {}

    /// @notice U:[CL-2]: `calcIncrease` outputs new interest that is old interest with at most a small error
    function test_CL_02_calcIncrease_preserves_interest(
        uint256 debt,
        uint256 indexNow,
        uint256 indexAtOpen,
        uint256 delta
    ) public {
        vm.assume(debt > 100);
        vm.assume(debt < 2 ** 128 - 1);
        vm.assume(delta < 2 ** 128 - 1);
        vm.assume(debt + delta <= 2 ** 128 - 1);

        indexNow = indexNow < RAY ? indexNow + RAY : indexNow;
        indexAtOpen = indexAtOpen < RAY ? indexAtOpen + RAY : indexAtOpen;

        vm.assume(indexNow <= 100 * RAY);
        vm.assume(indexNow >= indexAtOpen);
        vm.assume(indexNow - indexAtOpen < 10 * RAY);

        uint256 interest = uint256((debt * indexNow) / indexAtOpen - debt);

        vm.assume(interest > 1);

        CollateralDebtData memory cdd;

        cdd.debt = debt;
        cdd.cumulativeIndexNow = indexNow;
        cdd.cumulativeIndexLastUpdate = indexAtOpen;

        (uint256 newDebt, uint256 newIndex) = CreditLogic.calcIncrease(cdd, delta);

        assertEq(newDebt, debt + delta, "Debt principal not updated correctly");

        uint256 newInterestError = (newDebt * indexNow) / newIndex - newDebt - ((debt * indexNow) / indexAtOpen - debt);

        uint256 newTotalDebt = (newDebt * indexNow) / newIndex;

        assertLe((RAY * newInterestError) / newTotalDebt, 10000, "Interest error is larger than 10 ** -23");
    }

    /// @notice U:[CL-3A]: `calcDecrease` outputs newTotalDebt that is different by delta with at most a small error
    function test_CL_03A_calcDecrease_outputs_correct_new_total_debt(
        uint256 debt,
        uint256 indexNow,
        uint256 indexAtOpen,
        uint256 delta,
        uint256 quotaInterest,
        uint16 feeInterest
    ) public {
        vm.assume(debt > WAD);
        vm.assume(debt < 2 ** 128 - 1);
        vm.assume(delta < 2 ** 128 - 1);
        vm.assume(quotaInterest < 2 ** 128 - 1);
        vm.assume(debt + delta <= 2 ** 128 - 1);
        vm.assume(feeInterest <= PERCENTAGE_FACTOR);

        indexNow = indexNow < RAY ? indexNow + RAY : indexNow;
        indexAtOpen = indexAtOpen < RAY ? indexAtOpen + RAY : indexAtOpen;

        vm.assume(indexNow <= 100 * RAY);
        vm.assume(indexNow >= indexAtOpen);
        vm.assume(indexNow - indexAtOpen < 10 * RAY);

        uint256 interest = uint256((debt * indexNow) / indexAtOpen - debt);

        vm.assume(interest > 1);

        if (delta > debt + interest + quotaInterest) delta %= debt + interest + quotaInterest;

        CollateralDebtData memory cdd;

        cdd.debt = debt;
        cdd.cumulativeIndexNow = indexNow;
        cdd.cumulativeIndexLastUpdate = indexAtOpen;
        cdd.cumulativeQuotaInterest = quotaInterest;

        (uint256 newDebt, uint256 newCumulativeIndex,,) = CreditLogic.calcDecrease(cdd, delta, feeInterest);

        uint256 cumulativeQuotaInterest = cdd.cumulativeQuotaInterest;

        uint256 oldTotalDebt = _calcTotalDebt(debt, indexNow, indexAtOpen, quotaInterest, feeInterest);
        uint256 newTotalDebt =
            _calcTotalDebt(newDebt, indexNow, newCumulativeIndex, cumulativeQuotaInterest, feeInterest);

        uint256 debtError = _calcDiff(oldTotalDebt, newTotalDebt + delta);
        uint256 rel = oldTotalDebt > newTotalDebt ? oldTotalDebt : newTotalDebt;

        debtError = debtError > 10 ? debtError : 0;

        assertLe((RAY * debtError) / rel, 10 ** 5, "Error is larger than 10 ** -22");
    }

    /// @notice U:[CL-3B]: `calcDecrease` correctly outputs amountToRepay and profit
    function test_CL_03B_calcDecrease_outputs_correct_amountToRepay_profit(
        uint256 debt,
        uint256 indexNow,
        uint256 indexAtOpen,
        uint256 delta,
        uint256 quotaInterest,
        uint16 feeInterest
    ) public {
        vm.assume(debt > WAD);
        vm.assume(debt < 2 ** 128 - 1);
        vm.assume(delta < 2 ** 128 - 1);
        vm.assume(quotaInterest < 2 ** 128 - 1);
        vm.assume(debt + delta <= 2 ** 128 - 1);
        vm.assume(feeInterest <= PERCENTAGE_FACTOR);

        indexNow = indexNow < RAY ? indexNow + RAY : indexNow;
        indexAtOpen = indexAtOpen < RAY ? indexAtOpen + RAY : indexAtOpen;

        vm.assume(indexNow <= 100 * RAY);
        vm.assume(indexNow >= indexAtOpen);
        vm.assume(indexNow - indexAtOpen < 10 * RAY);

        uint256 interest = uint256((debt * indexNow) / indexAtOpen - debt);

        vm.assume(interest > 1);

        if (delta > debt + interest + quotaInterest) delta %= debt + interest + quotaInterest;

        CollateralDebtData memory cdd;

        cdd.debt = debt;
        cdd.cumulativeIndexNow = indexNow;
        cdd.cumulativeIndexLastUpdate = indexAtOpen;
        cdd.cumulativeQuotaInterest = quotaInterest;

        (uint256 newDebt,, uint256 amountToRepay, uint256 profit) = CreditLogic.calcDecrease(cdd, delta, feeInterest);

        assertEq(amountToRepay, debt - newDebt, "Amount to repay incorrect");

        uint256 expectedProfit = delta
            > (interest + quotaInterest) * (PERCENTAGE_FACTOR + feeInterest) / PERCENTAGE_FACTOR
            ? (interest + quotaInterest) * feeInterest / PERCENTAGE_FACTOR
            : delta * feeInterest / (PERCENTAGE_FACTOR + feeInterest);

        uint256 profitError = _calcDiff(expectedProfit, profit);

        assertLe(profitError, 100, "Profit error too large");
    }

    //
    // CALC CLOSE PAYMENT PURE
    //
    struct CalcClosePaymentsPureTestCase {
        string name;
        uint256 totalValue;
        ClosureAction closureActionType;
        uint256 borrowedAmount;
        uint256 borrowedAmountWithInterest;
        uint256 amountToPool;
        uint256 remainingFunds;
        uint256 profit;
        uint256 loss;
    }

    /// @dev [CM-43]: calcClosePayments computes
    function test_CM_43_calcClosePayments_test() public {
        // vm.prank(CONFIGURATOR);

        // creditManager.setParams(
        //     1000, // feeInterest: 10% , it doesn't matter this test
        //     200, // feeLiquidation: 2%, it doesn't matter this test
        //     9500, // liquidationPremium: 5%, it doesn't matter this test
        //     100, // feeLiquidationExpired: 1%
        //     9800 // liquidationPremiumExpired: 2%
        // );

        // CalcClosePaymentsPureTestCase[7] memory cases = [
        //     CalcClosePaymentsPureTestCase({
        //         name: "CLOSURE",
        //         totalValue: 0,
        //         closureActionType: ClosureAction.CLOSE_ACCOUNT,
        //         borrowedAmount: 1000,
        //         borrowedAmountWithInterest: 1100,
        //         amountToPool: 1110, // amountToPool = 1100 + 100 * 10% = 1110
        //         remainingFunds: 0,
        //         profit: 10, // profit: 100 (interest) * 10% = 10
        //         loss: 0
        //     }),
        //     CalcClosePaymentsPureTestCase({
        //         name: "LIQUIDATION WITH PROFIT & REMAINING FUNDS",
        //         totalValue: 2000,
        //         closureActionType: ClosureAction.LIQUIDATE_ACCOUNT,
        //         borrowedAmount: 1000,
        //         borrowedAmountWithInterest: 1100,
        //         amountToPool: 1150, // amountToPool = 1100 + 100 * 10% + 2000 * 2% = 1150
        //         remainingFunds: 749, //remainingFunds: 2000 * (100% - 5%) - 1150 - 1 = 749
        //         profit: 50,
        //         loss: 0
        //     }),
        //     CalcClosePaymentsPureTestCase({
        //         name: "LIQUIDATION WITH PROFIT & ZERO REMAINING FUNDS",
        //         totalValue: 2100,
        //         closureActionType: ClosureAction.LIQUIDATE_ACCOUNT,
        //         borrowedAmount: 900,
        //         borrowedAmountWithInterest: 1900,
        //         amountToPool: 1995, // amountToPool =  1900 + 1000 * 10% + 2100 * 2% = 2042,  totalFunds = 2100 * 95% = 1995, so, amount to pool would be 1995
        //         remainingFunds: 0, // remainingFunds: 2000 * (100% - 5%) - 1150 - 1 = 749
        //         profit: 95,
        //         loss: 0
        //     }),
        //     CalcClosePaymentsPureTestCase({
        //         name: "LIQUIDATION WITH LOSS",
        //         totalValue: 1000,
        //         closureActionType: ClosureAction.LIQUIDATE_ACCOUNT,
        //         borrowedAmount: 900,
        //         borrowedAmountWithInterest: 1900,
        //         amountToPool: 950, // amountToPool =  1900 + 1000 * 10% + 1000 * 2% = 2020, totalFunds = 1000 * 95% = 950, So, amount to pool would be 950
        //         remainingFunds: 0, // 0, cause it's loss
        //         profit: 0,
        //         loss: 950
        //     }),
        //     CalcClosePaymentsPureTestCase({
        //         name: "LIQUIDATION OF EXPIRED WITH PROFIT & REMAINING FUNDS",
        //         totalValue: 2000,
        //         closureActionType: ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT,
        //         borrowedAmount: 1000,
        //         borrowedAmountWithInterest: 1100,
        //         amountToPool: 1130, // amountToPool = 1100 + 100 * 10% + 2000 * 1% = 1130
        //         remainingFunds: 829, //remainingFunds: 2000 * (100% - 2%) - 1130 - 1 = 829
        //         profit: 30,
        //         loss: 0
        //     }),
        //     CalcClosePaymentsPureTestCase({
        //         name: "LIQUIDATION OF EXPIRED WITH PROFIT & ZERO REMAINING FUNDS",
        //         totalValue: 2100,
        //         closureActionType: ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT,
        //         borrowedAmount: 900,
        //         borrowedAmountWithInterest: 2000,
        //         amountToPool: 2058, // amountToPool =  2000 + 1100 * 10% + 2100 * 1% = 2131,  totalFunds = 2100 * 98% = 2058, so, amount to pool would be 2058
        //         remainingFunds: 0,
        //         profit: 58,
        //         loss: 0
        //     }),
        //     CalcClosePaymentsPureTestCase({
        //         name: "LIQUIDATION OF EXPIRED WITH LOSS",
        //         totalValue: 1000,
        //         closureActionType: ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT,
        //         borrowedAmount: 900,
        //         borrowedAmountWithInterest: 1900,
        //         amountToPool: 980, // amountToPool =  1900 + 1000 * 10% + 1000 * 2% = 2020, totalFunds = 1000 * 98% = 980, So, amount to pool would be 980
        //         remainingFunds: 0, // 0, cause it's loss
        //         profit: 0,
        //         loss: 920
        //     })
        //     // CalcClosePaymentsPureTestCase({
        //     //     name: "LIQUIDATION WHILE PAUSED WITH REMAINING FUNDS",
        //     //     totalValue: 2000,
        //     //     closureActionType: ClosureAction.LIQUIDATE_PAUSED,
        //     //     borrowedAmount: 1000,
        //     //     borrowedAmountWithInterest: 1100,
        //     //     amountToPool: 1150, // amountToPool = 1100 + 100 * 10%  + 2000 * 2% = 1150
        //     //     remainingFunds: 849, //remainingFunds: 2000 - 1150 - 1 = 869
        //     //     profit: 50,
        //     //     loss: 0
        //     // }),
        //     // CalcClosePaymentsPureTestCase({
        //     //     name: "LIQUIDATION OF EXPIRED WITH LOSS",
        //     //     totalValue: 1000,
        //     //     closureActionType: ClosureAction.LIQUIDATE_PAUSED,
        //     //     borrowedAmount: 900,
        //     //     borrowedAmountWithInterest: 1900,
        //     //     amountToPool: 1000, // amountToPool =  1900 + 1000 * 10% + 1000 * 2% = 2020, totalFunds = 1000 * 98% = 980, So, amount to pool would be 980
        //     //     remainingFunds: 0, // 0, cause it's loss
        //     //     profit: 0,
        //     //     loss: 900
        //     // })
        // ];

        // for (uint256 i = 0; i < cases.length; i++) {
        //     (uint256 amountToPool, uint256 remainingFunds, uint256 profit, uint256 loss) = creditManager
        //         .calcClosePayments(
        //         cases[i].totalValue,
        //         cases[i].closureActionType,
        //         cases[i].borrowedAmount,
        //         cases[i].borrowedAmountWithInterest
        //     );

        //     assertEq(amountToPool, cases[i].amountToPool, string(abi.encodePacked(cases[i].name, ": amountToPool")));
        //     assertEq(
        //         remainingFunds, cases[i].remainingFunds, string(abi.encodePacked(cases[i].name, ": remainingFunds"))
        //     );
        //     assertEq(profit, cases[i].profit, string(abi.encodePacked(cases[i].name, ": profit")));
        //     assertEq(loss, cases[i].loss, string(abi.encodePacked(cases[i].name, ": loss")));
        // }
    }

    /// @dev [CM-66]: calcNewCumulativeIndex works correctly for various values
    function test_CM_66_calcNewCumulativeIndex_is_correct(
        uint128 borrowedAmount,
        uint256 indexAtOpen,
        uint256 indexNow,
        uint128 delta,
        bool isIncrease
    ) public {
        // vm.assume(borrowedAmount > 100);
        // vm.assume(uint256(borrowedAmount) + uint256(delta) <= 2 ** 128 - 1);

        // indexNow = indexNow < RAY ? indexNow + RAY : indexNow;
        // indexAtOpen = indexAtOpen < RAY ? indexAtOpen + RAY : indexNow;

        // vm.assume(indexNow <= 100 * RAY);
        // vm.assume(indexNow >= indexAtOpen);
        // vm.assume(indexNow - indexAtOpen < 10 * RAY);

        // uint256 interest = uint256((borrowedAmount * indexNow) / indexAtOpen - borrowedAmount);

        // vm.assume(interest > 1);

        // if (!isIncrease && (delta > interest)) delta %= uint128(interest);

        // CreditManagerTestInternal cmi = new CreditManagerTestInternal(
        //     creditManager.poolService(), address(withdrawalManager)
        // );

        // if (isIncrease) {
        //     uint256 newIndex = CreditLogic.calcNewCumulativeIndex(borrowedAmount, delta, indexNow, indexAtOpen, true);

        //     uint256 newInterestError = ((borrowedAmount + delta) * indexNow) / newIndex - (borrowedAmount + delta)
        //         - ((borrowedAmount * indexNow) / indexAtOpen - borrowedAmount);

        //     uint256 newTotalDebt = ((borrowedAmount + delta) * indexNow) / newIndex;

        //     assertLe((RAY * newInterestError) / newTotalDebt, 10000, "Interest error is larger than 10 ** -23");
        // } else {
        //     uint256 newIndex = cmi.calcNewCumulativeIndex(borrowedAmount, delta, indexNow, indexAtOpen, false);

        //     uint256 newTotalDebt = ((borrowedAmount * indexNow) / newIndex);
        //     uint256 newInterestError = newTotalDebt - borrowedAmount - (interest - delta);

        //     emit log_uint(indexNow);
        //     emit log_uint(indexAtOpen);
        //     emit log_uint(interest);
        //     emit log_uint(delta);
        //     emit log_uint(interest - delta);
        //     emit log_uint(newTotalDebt);
        //     emit log_uint(borrowedAmount);
        //     emit log_uint(newInterestError);

        //     assertLe((RAY * newInterestError) / newTotalDebt, 10000, "Interest error is larger than 10 ** -23");
        // }
    }

    /// @dev [CM-21]: manageDebt correctly decreases debt
    function test_CM_21_manageDebt_correctly_decreases_debt(uint128 amount) public {
        // tokenTestSuite.mint(Tokens.DAI, address(poolMock), (uint256(type(uint128).max) * 14) / 10);

        // (uint256 borrowedAmount, uint256 cumulativeIndexLastUpdate, uint256 cumulativeIndexNow, address creditAccount) =
        //     cms.openCreditAccount((uint256(type(uint128).max) * 14) / 10);

        // (,, uint256 totalDebt) = creditManager.calcAccruedInterestAndFees(creditAccount);

        // uint256 expectedInterestAndFees;
        // uint256 expectedBorrowAmount;
        // if (amount >= totalDebt - borrowedAmount) {
        //     expectedInterestAndFees = 0;
        //     expectedBorrowAmount = totalDebt - amount;
        // } else {
        //     expectedInterestAndFees = totalDebt - borrowedAmount - amount;
        //     expectedBorrowAmount = borrowedAmount;
        // }

        // (uint256 newBorrowedAmount,) =
        //     creditManager.manageDebt(creditAccount, amount, 1, ManageDebtAction.DECREASE_DEBT);

        // assertEq(newBorrowedAmount, expectedBorrowAmount, "Incorrect returned newBorrowedAmount");

        // if (amount >= totalDebt - borrowedAmount) {
        //     (,, uint256 newTotalDebt) = creditManager.calcAccruedInterestAndFees(creditAccount);

        //     assertEq(newTotalDebt, newBorrowedAmount, "Incorrect new interest");
        // } else {
        //     (,, uint256 newTotalDebt) = creditManager.calcAccruedInterestAndFees(creditAccount);

        //     assertLt(
        //         (RAY * (newTotalDebt - newBorrowedAmount)) / expectedInterestAndFees - RAY,
        //         10000,
        //         "Incorrect new interest"
        //     );
        // }
        // uint256 cumulativeIndexLastUpdateAfter;
        // {
        //     uint256 debt;
        //     (debt, cumulativeIndexLastUpdateAfter,,,,) = creditManager.creditAccountInfo(creditAccount);

        //     assertEq(debt, newBorrowedAmount, "Incorrect borrowedAmount");
        // }

        // expectBalance(Tokens.DAI, creditAccount, borrowedAmount - amount, "Incorrect balance on credit account");

        // if (amount >= totalDebt - borrowedAmount) {
        //     assertEq(cumulativeIndexLastUpdateAfter, cumulativeIndexNow, "Incorrect cumulativeIndexLastUpdate");
        // } else {
        //     CreditManagerTestInternal cmi = new CreditManagerTestInternal(
        //         creditManager.poolService(), address(withdrawalManager)
        //     );

        //     {
        //         (uint256 feeInterest,,,,) = creditManager.fees();
        //         amount = uint128((uint256(amount) * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest));
        //     }

        //     assertEq(
        //         cumulativeIndexLastUpdateAfter,
        //         cmi.calcNewCumulativeIndex(borrowedAmount, amount, cumulativeIndexNow, cumulativeIndexLastUpdate, false),
        //         "Incorrect cumulativeIndexLastUpdate"
        //     );
        // }
    }
}
