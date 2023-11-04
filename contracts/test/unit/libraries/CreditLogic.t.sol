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

/// @title BitMask logic test
/// @notice [BM]: Unit tests for bit mask library
contract CreditLogicTest is TestHelper {
    uint256 public constant TEST_FEE = 50;

    address[8] tokens;
    uint16[8] tokenLTsStorage;
    uint256[8] tokenBalancesStorage;
    uint256[8] tokenPricesStorage;

    function _prepareTokens() internal {
        for (uint256 i; i < 8; ++i) {
            tokens[i] = address(new GeneralMock());
        }
    }

    function _amountWithoutFee(uint256 a) internal pure returns (uint256) {
        return a;
    }

    function _amountPlusFee(uint256 a) internal pure returns (uint256) {
        return a * (TEST_FEE + PERCENTAGE_FACTOR) / PERCENTAGE_FACTOR;
    }

    function _amountMinusFee(uint256 a) internal pure returns (uint256) {
        return a * (PERCENTAGE_FACTOR - TEST_FEE) / PERCENTAGE_FACTOR;
    }

    function _calcDiff(uint256 a, uint256 b) internal pure returns (uint256 diff) {
        diff = a > b ? a - b : b - a;
    }

    function _getTokenArray() internal view returns (address[] memory tokensMemory) {
        tokensMemory = new address[](8);

        for (uint256 i = 0; i < 8; ++i) {
            tokensMemory[i] = tokens[i];
        }
    }

    function _getLTArray() internal view returns (uint16[] memory tokenLTsMemory) {
        tokenLTsMemory = new uint16[](8);

        for (uint256 i = 0; i < 8; ++i) {
            tokenLTsMemory[i] = tokenLTsStorage[i];
        }
    }

    function _getBalanceArray() internal view returns (uint256[] memory tokenBalancesMemory) {
        tokenBalancesMemory = new uint256[](8);

        for (uint256 i = 0; i < 8; ++i) {
            tokenBalancesMemory[i] = tokenBalancesStorage[i];
        }
    }

    function _getPriceArray() internal view returns (uint256[] memory tokenPricesMemory) {
        tokenPricesMemory = new uint256[](8);

        for (uint256 i = 0; i < 8; ++i) {
            tokenPricesMemory[i] = tokenPricesStorage[i];
        }
    }

    function _getCollateralHintsIdx(uint256 rand) internal pure returns (uint256[] memory collateralHints) {
        uint256 len = uint256(keccak256(abi.encode(rand))) % 9;

        uint256[] memory nums = new uint256[](8);
        collateralHints = new uint256[](len);

        for (uint256 i = 0; i < 8; ++i) {
            nums[i] = i;
        }

        for (uint256 i = 0; i < len; ++i) {
            rand = uint256(keccak256(abi.encode(rand)));
            uint256 idx = rand % (8 - i);
            collateralHints[i] = 2 ** nums[idx];
            nums[idx] = nums[7 - i];
        }
    }

    function _getMasksFromIdx(uint256[] memory idxArray) internal pure returns (uint256[] memory masksArray) {
        masksArray = new uint256[](idxArray.length);

        for (uint256 i = 0; i < idxArray.length; ++i) {
            masksArray[i] = 2 ** idxArray[i];
        }
    }

    function _calcTotalDebt(
        uint256 debt,
        uint256 indexNow,
        uint256 indexOpen,
        uint256 quotaInterest,
        uint256 quotaFees,
        uint16 feeInterest
    ) internal pure returns (uint256) {
        return debt + quotaFees
            + (debt * indexNow / indexOpen + quotaInterest - debt) * (PERCENTAGE_FACTOR + feeInterest) / PERCENTAGE_FACTOR;
    }

    /// @notice U:[CL-1]: `calcAccruedInterest` computes interest correctly
    function test_U_CL_01_calcAccruedInterest_computes_interest_with_small_error(
        uint256 debt,
        uint256 cumulativeIndexAtOpen,
        uint256 borrowRate,
        uint256 timeDiff
    ) public {
        debt = 100 + debt % (2 ** 128 - 101);
        cumulativeIndexAtOpen = RAY + cumulativeIndexAtOpen % (99 * RAY);
        borrowRate = borrowRate % (10 * RAY);
        timeDiff = timeDiff % (2000 days);

        uint256 timestampLastUpdate = block.timestamp;

        vm.warp(block.timestamp + timeDiff);

        uint256 interest = CreditLogic.calcLinearGrowth(debt * borrowRate, timestampLastUpdate) / RAY;

        uint256 cumulativeIndexNow =
            cumulativeIndexAtOpen * (RAY + CreditLogic.calcLinearGrowth(borrowRate, timestampLastUpdate)) / RAY;

        uint256 diff =
            _calcDiff(CreditLogic.calcAccruedInterest(debt, cumulativeIndexAtOpen, cumulativeIndexNow), interest);

        assertLe(RAY * diff / debt, 10000, "Interest error is more than 10 ** -22");
    }

    /// @notice U:[CL-2]: `calcIncrease` outputs new interest that is old interest with at most a small error
    function test_U_CL_02_calcIncrease_preserves_interest(
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

        (uint256 newDebt, uint256 newIndex) = CreditLogic.calcIncrease(delta, debt, indexNow, indexAtOpen);

        assertEq(newDebt, debt + delta, "Debt principal not updated correctly");

        uint256 newInterestError = (newDebt * indexNow) / newIndex - newDebt - ((debt * indexNow) / indexAtOpen - debt);

        uint256 newTotalDebt = (newDebt * indexNow) / newIndex;

        assertLe((RAY * newInterestError) / newTotalDebt, 10000, "Interest error is larger than 10 ** -23");
    }

    /// @notice U:[CL-3A]: `calcDecrease` outputs newTotalDebt that is different by delta with at most a small error
    function test_U_CL_03A_calcDecrease_outputs_correct_new_total_debt(
        uint256 debt,
        uint256 indexNow,
        uint256 indexAtOpen,
        uint256 delta,
        uint128 quotaInterest,
        uint128 quotaFees,
        uint16 feeInterest
    ) public {
        debt = WAD + debt % (2 ** 128 - WAD - 1);
        delta = delta % (2 ** 128 - 1);
        quotaInterest = quotaInterest % (2 ** 96 - 1);
        quotaFees = quotaInterest % (2 ** 96 - 1);

        vm.assume(debt + delta <= 2 ** 128 - 1);

        feeInterest %= PERCENTAGE_FACTOR + 1;

        indexNow = indexNow < RAY ? indexNow + RAY : indexNow;
        indexAtOpen = indexAtOpen < RAY ? indexAtOpen + RAY : indexAtOpen;

        indexNow %= 100 * RAY + 1;

        vm.assume(indexNow >= indexAtOpen);
        vm.assume(indexNow - indexAtOpen < 10 * RAY);

        uint256 interest = uint256((debt * indexNow) / indexAtOpen - debt);

        vm.assume(interest > 1);

        if (delta > debt + interest + quotaInterest + quotaFees) {
            delta %= debt + interest + quotaInterest + quotaFees;
        }

        (uint256 newDebt, uint256 newCumulativeIndex,, uint256 cumulativeQuotaInterest, uint256 newQuotaFees) =
            CreditLogic.calcDecrease(delta, debt, indexNow, indexAtOpen, quotaInterest, quotaFees, feeInterest);

        uint256 oldTotalDebt = _calcTotalDebt(debt, indexNow, indexAtOpen, quotaInterest, quotaFees, feeInterest);
        uint256 newTotalDebt =
            _calcTotalDebt(newDebt, indexNow, newCumulativeIndex, cumulativeQuotaInterest, newQuotaFees, feeInterest);

        uint256 debtError = _calcDiff(oldTotalDebt, newTotalDebt + delta);
        uint256 rel = oldTotalDebt > newTotalDebt ? oldTotalDebt : newTotalDebt;

        debtError = debtError > 10 ? debtError : 0;

        assertLe((RAY * debtError) / rel, 10 ** 5, "Error is larger than 10 ** -22");
    }

    /// @notice U:[CL-3B]: `calcDecrease` correctly outputs newDebt and profit
    function test_U_CL_03B_calcDecrease_outputs_correct_newDebt_profit(
        uint256 debt,
        uint256 indexNow,
        uint256 indexAtOpen,
        uint256 delta,
        uint128 quotaInterest,
        uint128 quotaFees,
        uint16 feeInterest
    ) public {
        debt = WAD + debt % (2 ** 128 - WAD - 1);
        delta = delta % (2 ** 128 - 1);
        quotaInterest = quotaInterest % (2 ** 96 - 1);
        quotaFees = quotaInterest % (2 ** 96 - 1);

        vm.assume(debt + delta <= 2 ** 128 - 1);

        feeInterest %= PERCENTAGE_FACTOR + 1;

        indexNow = indexNow < RAY ? indexNow + RAY : indexNow;
        indexAtOpen = indexAtOpen < RAY ? indexAtOpen + RAY : indexAtOpen;

        indexNow %= 100 * RAY + 1;

        vm.assume(indexNow >= indexAtOpen);
        vm.assume(indexNow - indexAtOpen < 10 * RAY);

        uint256 interest = uint256((debt * indexNow) / indexAtOpen - debt);

        vm.assume(interest > 1);

        if (delta > debt + interest + quotaInterest + quotaFees) {
            delta %= debt + interest + quotaInterest + quotaFees;
        }

        (uint256 newDebt,, uint256 profit,,) =
            CreditLogic.calcDecrease(delta, debt, indexNow, indexAtOpen, quotaInterest, quotaFees, feeInterest);

        uint256 expectedProfit;

        if (delta > quotaFees) {
            uint256 remainingDelta = delta - quotaFees;
            expectedProfit = quotaFees;
            expectedProfit += remainingDelta
                > (interest + quotaInterest) * (PERCENTAGE_FACTOR + feeInterest) / PERCENTAGE_FACTOR
                ? (interest + quotaInterest) * feeInterest / PERCENTAGE_FACTOR
                : remainingDelta * feeInterest / (PERCENTAGE_FACTOR + feeInterest);
        } else {
            expectedProfit = delta;
        }

        assertLe(_calcDiff(expectedProfit, profit), 100, "Profit error too large");

        uint256 expectedRepaid =
            delta > interest + quotaInterest + expectedProfit ? delta - interest - quotaInterest - expectedProfit : 0;

        assertLe(_calcDiff(expectedRepaid, debt - newDebt), 100, "New debt error too large");
    }

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
                cases[i].withFee ? _amountPlusFee : _amountWithoutFee,
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

    function _collateralTokenByMask(uint256 mask, bool computeLT) internal view returns (address token, uint16 lt) {
        for (uint256 i = 0; i < 8; ++i) {
            if (mask == (1 << i)) {
                token = tokens[i];
                lt = computeLT ? tokenLTsStorage[i] : 0;
            }
        }

        if (token == address(0)) {
            revert("Token not found");
        }
    }

    function _convertToUSD(address, address token) internal view returns (uint256) {
        uint256 tokenIdx;
        for (uint256 i = 0; i < 8; ++i) {
            if (tokens[i] == token) tokenIdx = i;
        }
        return tokenPricesStorage[tokenIdx] * tokenBalancesStorage[tokenIdx] / WAD;
    }

    //     /// @notice U:[CL-6]: `calcQuotedTokensCollateral` fuzzing test
    //     function test_CL_06_calcQuotedTokensCollateral_fuzz_test(
    //         uint256[8] memory tokenBalances,
    //         uint256[8] memory tokenPrices,
    //         uint256[8] memory tokenQuotas,
    //         uint256 limit,
    //         uint16[8] memory lts
    //     ) public {
    //         _prepareTokens();

    //         CollateralDebtData memory cdd;

    //         address creditAccount = makeAddr("CREDIT_ACCOUNT");
    //         address underlying = makeAddr("UNDERLYING");

    //         for (uint256 i = 0; i < 8; ++i) {
    //             tokenBalances[i] = tokenBalances[i] % (WAD * 10 ** 9);
    //             tokenQuotas[i] = tokenQuotas[i] % (WAD * 10 ** 9);
    //             lts[i] = lts[i] % 9451;
    //             tokenPrices[i] = 10 ** 5 + tokenPrices[i] % (100000 * 10 ** 8);

    //             emit log_string("TOKEN");
    //             emit log_uint(i);
    //             emit log_string("BALANCE");
    //             emit log_uint(tokenBalances[i]);
    //             emit log_string("QUOTA");
    //             emit log_uint(tokenQuotas[i]);
    //             emit log_string("LT");
    //             emit log_uint(lts[i]);
    //             emit log_string("TOKEN PRICE");
    //             emit log_uint(tokenPrices[i]);

    //             vm.mockCall(tokens[i], abi.encodeCall(IERC20.balanceOf, (creditAccount)), abi.encode(tokenBalances[i]));
    //         }

    //         tokenBalancesStorage = tokenBalances;
    //         tokenPricesStorage = tokenPrices;
    //         tokenLTsStorage = lts;

    //         cdd.quotedTokens = _getTokenArray();
    //         cdd.quotedLts = _getLTArray();

    //         {
    //             uint256[] memory quotas = new uint256[](8);

    //             for (uint256 i = 0; i < 8; ++i) {
    //                 quotas[i] = tokenQuotas[i];
    //             }

    //             cdd.quotas = quotas;
    //         }

    //         (cdd.totalValueUSD, cdd.twvUSD) = CreditLogic.calcQuotedTokensCollateral(
    //             cdd, creditAccount, 10 ** 8 * RAY / WAD, limit, _convertToUSD, address(0)
    //         );

    //         uint256 twvExpected;
    //         uint256 totalValueExpected;
    //         uint256 interestExpected;

    //         for (uint256 i = 0; i < 8; ++i) {
    //             uint256 balanceValue = tokenBalances[i] * tokenPrices[i] / WAD;
    //             uint256 quotaValue = tokenQuotas[i] / 10 ** 10;
    //             totalValueExpected += balanceValue;
    //             twvExpected += (balanceValue < quotaValue ? balanceValue : quotaValue) * lts[i] / PERCENTAGE_FACTOR;

    //             if (twvExpected >= limit) break;
    //         }

    //         assertLe(_calcDiff(cdd.twvUSD, twvExpected), 1, "Incorrect twv");

    //         assertEq(cdd.totalValueUSD, totalValueExpected, "Incorrect total value");
    //     }

    //     /// @notice U:[CL-7]: `calcNonQuotedTokensCollateral` fuzzing test
    //     function test_CL_07_calcNonQuotedTokensCollateral_fuzz_test(
    //         uint256 collateralHintsRand,
    //         uint256 tokensToCheck,
    //         uint256[8] memory tokenBalances,
    //         uint256[8] memory tokenPrices,
    //         uint256 limit,
    //         uint16[8] memory lts
    //     ) public {
    //         _prepareTokens();

    //         tokensToCheck %= 2 ** 8;

    //         emit log_string("LIMIT");
    //         emit log_uint(limit);

    //         for (uint256 i = 0; i < 8; ++i) {
    //             tokenBalances[i] = tokenBalances[i] % (WAD * 10 ** 9);
    //             lts[i] = lts[i] % 9451;
    //             tokenPrices[i] = 10 ** 5 + tokenPrices[i] % (100000 * 10 ** 8);

    //             emit log_string("TOKEN");
    //             emit log_uint(i);
    //             emit log_string("BALANCE");
    //             emit log_uint(tokenBalances[i]);
    //             emit log_string("LT");
    //             emit log_uint(lts[i]);
    //             emit log_string("TOKEN PRICE");
    //             emit log_uint(tokenPrices[i]);
    //             emit log_string("CHECKED");
    //             emit log_uint(tokensToCheck & (1 << i) == 0 ? 0 : 1);

    //             vm.mockCall(
    //                 tokens[i], abi.encodeCall(IERC20.balanceOf, (makeAddr("CREDIT_ACCOUNT"))), abi.encode(tokenBalances[i])
    //             );
    //         }

    //         uint256[] memory colHints = _getCollateralHintsIdx(collateralHintsRand);

    //         emit log_string("COLLATERAL HINTS");
    //         for (uint256 i = 0; i < colHints.length; ++i) {
    //             emit log_uint(colHints[i]);
    //         }

    //         tokenBalancesStorage = tokenBalances;
    //         tokenPricesStorage = tokenPrices;
    //         tokenLTsStorage = lts;

    //         (uint256 totalValueUSD, uint256 twvUSD, uint256 tokensToDisable) = CreditLogic.calcNonQuotedTokensCollateral(
    //             makeAddr("CREDIT_ACCOUNT"),
    //             limit,
    //             _getMasksFromIdx(colHints),
    //             _convertToUSD,
    //             _collateralTokenByMask,
    //             tokensToCheck,
    //             address(0)
    //         );

    //         uint256 twvExpected;
    //         uint256 totalValueExpected;
    //         uint256 tokensToDisableExpected;

    //         for (uint256 i = 0; i < colHints.length; ++i) {
    //             uint256 idx = colHints[i];

    //             if (tokensToCheck & (1 << idx) != 0) {
    //                 if (tokenBalances[idx] > 1) {
    //                     uint256 balanceValue = tokenBalances[idx] * tokenPrices[idx] / WAD;
    //                     totalValueExpected += balanceValue;
    //                     twvExpected += balanceValue * lts[idx] / PERCENTAGE_FACTOR;

    //                     if (twvExpected >= limit) break;
    //                 } else {
    //                     tokensToDisableExpected += 1 << idx;
    //                 }
    //             }

    //             tokensToCheck = tokensToCheck & ~(1 << idx);
    //         }

    //         for (uint256 i = 0; i < 8; ++i) {
    //             if (tokensToCheck & (1 << i) != 0) {
    //                 if (tokenBalances[i] > 1) {
    //                     uint256 balanceValue = tokenBalances[i] * tokenPrices[i] / WAD;
    //                     totalValueExpected += balanceValue;
    //                     twvExpected += balanceValue * lts[i] / PERCENTAGE_FACTOR;

    //                     if (twvExpected >= limit) break;
    //                 } else {
    //                     tokensToDisableExpected += 1 << i;
    //                 }
    //             }
    //         }

    //         assertLe(_calcDiff(twvUSD, twvExpected), 1, "Incorrect twv");

    //         assertEq(totalValueUSD, totalValueExpected, "Incorrect total value");

    //         assertEq(tokensToDisable, tokensToDisableExpected, "Incorrect tokens to disable");
    //     }
}
