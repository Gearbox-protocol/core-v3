// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {QuotasLogic} from "../../../libraries/QuotasLogic.sol";
import {AccountQuota, TokenQuotaParams} from "../../../interfaces/IPoolQuotaKeeperV3.sol";
import {TestHelper} from "../../lib/helper.sol";

import {RAY, WAD} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

/// @title Quotas logic test
/// @notice U:[BM]: Unit tests for QuotasLogic library
contract QuotasLogicUnitTest is TestHelper {
    TokenQuotaParams params;
    AccountQuota accountQuota;

    struct AdditiveCumulativeIndexCase {
        uint192 cumulativeIndexLU;
        uint16 rate;
        uint256 deltaTimestamp;
        uint192 expectedIndex;
    }

    /// @notice U:[QL-1]: `calcAdditiveCumulativeIndex` computes the new index correctly
    function test_U_QL_01_calcAdditiveCumulativeIndex_computes_index_correctly() public {
        AdditiveCumulativeIndexCase[4] memory cases = [
            AdditiveCumulativeIndexCase({
                cumulativeIndexLU: uint192(RAY),
                rate: 10000,
                deltaTimestamp: 365 days,
                expectedIndex: uint192(2 * RAY)
            }),
            AdditiveCumulativeIndexCase({
                cumulativeIndexLU: uint192(2 * RAY),
                rate: 3650,
                deltaTimestamp: 1 days,
                expectedIndex: uint192(20010 * RAY / 10000)
            }),
            AdditiveCumulativeIndexCase({
                cumulativeIndexLU: uint192(RAY),
                rate: 1,
                deltaTimestamp: 1 days,
                expectedIndex: uint192(RAY + 273972602739726027397)
            }),
            AdditiveCumulativeIndexCase({
                cumulativeIndexLU: uint192(RAY),
                rate: 1234,
                deltaTimestamp: 365 days,
                expectedIndex: uint192(RAY + 1234 * RAY / 10000)
            })
        ];

        vm.warp(5 * 365 days);

        for (uint256 i = 0; i < cases.length; ++i) {
            uint192 index = QuotasLogic.cumulativeIndexSince(
                cases[i].cumulativeIndexLU, cases[i].rate, block.timestamp - cases[i].deltaTimestamp
            );

            assertEq(index, cases[i].expectedIndex, "Index computed incorrectly");
        }
    }

    struct CalcAccruedQuotaInterestCase {
        uint192 cumulativeIndexNow;
        uint192 cumulativeIndexLU;
        uint96 quoted;
        uint256 expectedInterest;
    }

    /// @notice U:[QL-2]: `calcAccruedQuotaInterest` computes the interest correctly
    function test_U_QL_02_calcAccruedQuotaInterest_computes_index_correctly() public {
        CalcAccruedQuotaInterestCase[4] memory cases = [
            CalcAccruedQuotaInterestCase({
                cumulativeIndexNow: uint192(RAY),
                cumulativeIndexLU: uint192(RAY),
                quoted: type(uint96).max,
                expectedInterest: 0
            }),
            CalcAccruedQuotaInterestCase({
                cumulativeIndexNow: uint192(2 * RAY),
                cumulativeIndexLU: uint192(RAY),
                quoted: 1000,
                expectedInterest: 1000
            }),
            CalcAccruedQuotaInterestCase({
                cumulativeIndexNow: uint192(12 * RAY / 10),
                cumulativeIndexLU: uint192(RAY),
                quoted: 1000,
                expectedInterest: 200
            }),
            CalcAccruedQuotaInterestCase({
                cumulativeIndexNow: uint192(2345 * RAY / 1000),
                cumulativeIndexLU: uint192(RAY),
                quoted: 1000,
                expectedInterest: 1345
            })
        ];

        for (uint256 i = 0; i < cases.length; ++i) {
            params.cumulativeIndexLU = cases[i].cumulativeIndexLU;

            uint256 interest = QuotasLogic.calcAccruedQuotaInterest(
                cases[i].quoted, cases[i].cumulativeIndexNow, cases[i].cumulativeIndexLU
            );

            assertEq(interest, cases[i].expectedInterest, "Interest computed incorrectly");
        }
    }

    // struct ChangeQuotaCase {
    //     string name;
    //     uint192 cumulativeIndexTokenLU;
    //     uint192 cumulativeIndexAccountLU;
    //     uint256 timeSinceLastUpdate;
    //     uint16 rate;
    //     uint16 oneTimeFee;
    //     uint96 previousQuota;
    //     int96 quotaChange;
    //     uint96 quotaLimit;
    //     uint96 totalQuoted;
    //     uint256 caQuotaInterestChangeExpected;
    //     int256 quotaRevenueChangeExpected;
    //     int96 realQuotaChangeExpected;
    //     bool enableTokenExpected;
    //     bool disableTokenExpected;
    // }

    // /// @notice U:[QL-3]: `changeQuota` works correctly
    // function test_U_QL_03_changeQuota_works_correctly() public {
    //     ChangeQuotaCase[7] memory cases = [
    //         ChangeQuotaCase({
    //             name: "Increasing quota from 0 without trading fee",
    //             cumulativeIndexTokenLU: uint192(2 * RAY),
    //             cumulativeIndexAccountLU: uint192(RAY),
    //             timeSinceLastUpdate: 1 days,
    //             rate: 1000,
    //             oneTimeFee: 0,
    //             previousQuota: 0,
    //             quotaChange: int96(int256(WAD)),
    //             quotaLimit: uint96(2 * WAD),
    //             totalQuoted: uint96(WAD / 2),
    //             caQuotaInterestChangeExpected: 0,
    //             quotaRevenueChangeExpected: int256(int96(int256(WAD)) / 10),
    //             realQuotaChangeExpected: int96(int256(WAD)),
    //             enableTokenExpected: true,
    //             disableTokenExpected: false
    //         }),
    //         ChangeQuotaCase({
    //             name: "Increasing quota from non-zero without trading fee",
    //             cumulativeIndexTokenLU: uint192(2 * RAY),
    //             cumulativeIndexAccountLU: uint192(RAY),
    //             timeSinceLastUpdate: 1 days,
    //             rate: 3650,
    //             oneTimeFee: 0,
    //             previousQuota: uint96(WAD),
    //             quotaChange: int96(int256(2 * WAD)),
    //             quotaLimit: uint96(5 * WAD),
    //             totalQuoted: uint96(15 * WAD / 10),
    //             caQuotaInterestChangeExpected: WAD + WAD / 1000,
    //             quotaRevenueChangeExpected: int256(int96(int256(2 * WAD)) * 365 / 1000),
    //             realQuotaChangeExpected: int96(int256(2 * WAD)),
    //             enableTokenExpected: false,
    //             disableTokenExpected: false
    //         }),
    //         ChangeQuotaCase({
    //             name: "Increasing quota from non-zero with trading fee",
    //             cumulativeIndexTokenLU: uint192(2 * RAY),
    //             cumulativeIndexAccountLU: uint192(RAY),
    //             timeSinceLastUpdate: 1 days,
    //             rate: 3650,
    //             oneTimeFee: 100,
    //             previousQuota: uint96(WAD),
    //             quotaChange: int96(int256(2 * WAD)),
    //             quotaLimit: uint96(5 * WAD),
    //             totalQuoted: uint96(15 * WAD / 10),
    //             caQuotaInterestChangeExpected: WAD + WAD / 1000 + 2 * WAD / 100,
    //             quotaRevenueChangeExpected: int256(int96(int256(2 * WAD)) * 365 / 1000),
    //             realQuotaChangeExpected: int96(int256(2 * WAD)),
    //             enableTokenExpected: false,
    //             disableTokenExpected: false
    //         }),
    //         ChangeQuotaCase({
    //             name: "Increasing quota from non-zero over capacity",
    //             cumulativeIndexTokenLU: uint192(2 * RAY),
    //             cumulativeIndexAccountLU: uint192(RAY),
    //             timeSinceLastUpdate: 1 days,
    //             rate: 3650,
    //             oneTimeFee: 100,
    //             previousQuota: uint96(WAD),
    //             quotaChange: int96(int256(2 * WAD)),
    //             quotaLimit: uint96(3 * WAD),
    //             totalQuoted: uint96(15 * WAD / 10),
    //             caQuotaInterestChangeExpected: WAD + WAD / 1000 + 15 * WAD / 1000,
    //             quotaRevenueChangeExpected: int256(int96(int256(15 * WAD / 10)) * 365 / 1000),
    //             realQuotaChangeExpected: int96(int256(15 * WAD / 10)),
    //             enableTokenExpected: false,
    //             disableTokenExpected: false
    //         }),
    //         ChangeQuotaCase({
    //             name: "Increasing quota at the limit",
    //             cumulativeIndexTokenLU: uint192(2 * RAY),
    //             cumulativeIndexAccountLU: uint192(RAY),
    //             timeSinceLastUpdate: 1 days,
    //             rate: 3650,
    //             oneTimeFee: 100,
    //             previousQuota: uint96(WAD),
    //             quotaChange: int96(int256(2 * WAD)),
    //             quotaLimit: uint96(14 * WAD / 10),
    //             totalQuoted: uint96(15 * WAD / 10),
    //             caQuotaInterestChangeExpected: WAD + WAD / 1000,
    //             quotaRevenueChangeExpected: 0,
    //             realQuotaChangeExpected: 0,
    //             enableTokenExpected: false,
    //             disableTokenExpected: false
    //         }),
    //         ChangeQuotaCase({
    //             name: "Decreasing quota from non-zero to non-zero",
    //             cumulativeIndexTokenLU: uint192(2 * RAY),
    //             cumulativeIndexAccountLU: uint192(RAY),
    //             timeSinceLastUpdate: 1 days,
    //             rate: 3650,
    //             oneTimeFee: 100,
    //             previousQuota: uint96(WAD),
    //             quotaChange: -int96(int256(WAD / 2)),
    //             quotaLimit: uint96(15 * WAD / 10),
    //             totalQuoted: uint96(15 * WAD / 10),
    //             caQuotaInterestChangeExpected: WAD + WAD / 1000,
    //             quotaRevenueChangeExpected: -int256(int96(int256(WAD / 2)) * 365 / 1000),
    //             realQuotaChangeExpected: -int96(int256(WAD / 2)),
    //             enableTokenExpected: false,
    //             disableTokenExpected: false
    //         }),
    //         ChangeQuotaCase({
    //             name: "Decreasing quota from non-zero to zero",
    //             cumulativeIndexTokenLU: uint192(2 * RAY),
    //             cumulativeIndexAccountLU: uint192(RAY),
    //             timeSinceLastUpdate: 1 days,
    //             rate: 3650,
    //             oneTimeFee: 100,
    //             previousQuota: uint96(WAD),
    //             quotaChange: -int96(int256(WAD)),
    //             quotaLimit: uint96(15 * WAD / 10),
    //             totalQuoted: uint96(15 * WAD / 10),
    //             caQuotaInterestChangeExpected: WAD + WAD / 1000,
    //             quotaRevenueChangeExpected: -int256(int96(int256(WAD)) * 365 / 1000),
    //             realQuotaChangeExpected: -int96(int256(WAD)),
    //             enableTokenExpected: false,
    //             disableTokenExpected: true
    //         })
    //     ];

    //     for (uint256 i = 0; i < cases.length; ++i) {
    //         params.cumulativeIndexLU = cases[i].cumulativeIndexTokenLU;
    //         params.rate = cases[i].rate;
    //         params.limit = cases[i].quotaLimit;
    //         params.totalQuoted = cases[i].totalQuoted;
    //         params.quotaIncreaseFee = cases[i].oneTimeFee;

    //         accountQuota.quota = cases[i].previousQuota;
    //         accountQuota.cumulativeIndexLU = cases[i].cumulativeIndexAccountLU;

    //         (
    //             uint256 caQuotaInterestChange,
    //             uint256 fees,
    //             int256 quotaRevenueChange,
    //             int96 realQuotaChange,
    //             bool enableToken,
    //             bool disableToken
    //         ) = QuotasLogic.changeQuota(
    //             params, accountQuota, block.timestamp - cases[i].timeSinceLastUpdate, cases[i].quotaChange
    //         );

    //         assertEq(
    //             caQuotaInterestChange,
    //             cases[i].caQuotaInterestChangeExpected,
    //             "caQuotaInterestChange computed incorrectly"
    //         );

    //         assertEq(quotaRevenueChange, cases[i].quotaRevenueChangeExpected, "quotaRevenueChange computed incorrectly");

    //         assertEq(realQuotaChange, cases[i].realQuotaChangeExpected, "realQuotaChange computed incorrectly");

    //         assertEq(enableToken ? 1 : 0, cases[i].enableTokenExpected ? 1 : 0, "enableToken computed incorrectly");

    //         assertEq(disableToken ? 1 : 0, cases[i].disableTokenExpected ? 1 : 0, "disableToken computed incorrectly");

    //         assertEq(
    //             accountQuota.cumulativeIndexLU,
    //             QuotasLogic.cumulativeIndexSince(params, block.timestamp - cases[i].timeSinceLastUpdate),
    //             "Cumulative index updated incorrectly"
    //         );

    //         assertEq(
    //             accountQuota.quota,
    //             uint96(int96(cases[i].previousQuota) + cases[i].realQuotaChangeExpected),
    //             "Quota updated incorrectly"
    //         );

    //         assertEq(
    //             params.totalQuoted,
    //             uint96(int96(cases[i].totalQuoted) + cases[i].realQuotaChangeExpected),
    //             "Total quoted updated incorrectly"
    //         );
    //     }
    // }

    // struct AccrueQuotaInterestCase {
    //     string name;
    //     uint192 cumulativeIndexTokenLU;
    //     uint192 cumulativeIndexAccountLU;
    //     uint256 timeSinceLastUpdate;
    //     uint16 rate;
    //     uint96 quota;
    //     uint256 caQuotaInterestChangeExpected;
    //     uint256 expectedIndexAccountAfter;
    // }

    // /// @notice U:[QL-4]: `accruedQuotaInterest` works correctly
    // function test_U_QL_04_accrueQuotaInterest_works_correctly() public {
    //     AccrueQuotaInterestCase[2] memory cases = [
    //         AccrueQuotaInterestCase({
    //             name: "Quota is zero",
    //             cumulativeIndexTokenLU: uint192(2 * RAY),
    //             cumulativeIndexAccountLU: uint192(RAY),
    //             timeSinceLastUpdate: 1 days,
    //             rate: 3650,
    //             quota: 0,
    //             caQuotaInterestChangeExpected: 0,
    //             expectedIndexAccountAfter: uint192(2001 * RAY / 1000)
    //         }),
    //         AccrueQuotaInterestCase({
    //             name: "Quota is non-zero",
    //             cumulativeIndexTokenLU: uint192(2 * RAY),
    //             cumulativeIndexAccountLU: uint192(RAY),
    //             timeSinceLastUpdate: 1 days,
    //             rate: 3650,
    //             quota: uint96(WAD),
    //             caQuotaInterestChangeExpected: WAD + WAD / 1000,
    //             expectedIndexAccountAfter: uint192(2001 * RAY / 1000)
    //         })
    //     ];

    //     for (uint256 i = 0; i < cases.length; ++i) {
    //         params.cumulativeIndexLU = cases[i].cumulativeIndexTokenLU;
    //         params.rate = cases[i].rate;

    //         accountQuota.quota = cases[i].quota;
    //         accountQuota.cumulativeIndexLU = cases[i].cumulativeIndexAccountLU;

    //         uint256 caQuotaInterestChange = QuotasLogic.accrueAccountQuotaInterest(
    //             params, accountQuota, block.timestamp - cases[i].timeSinceLastUpdate
    //         );

    //         assertEq(
    //             caQuotaInterestChange, cases[i].caQuotaInterestChangeExpected, "Interest change computed incorrectly"
    //         );

    //         assertEq(
    //             accountQuota.cumulativeIndexLU,
    //             cases[i].expectedIndexAccountAfter,
    //             "Cumulative index updated incorrectly"
    //         );
    //     }
    // }

    // /// @notice U:[QL-5]: `removeQuota` works correctly
    // function test_U_QL_05_removeQuota_works_correctly() public {
    //     params.rate = 3650;
    //     params.cumulativeIndexLU = uint192(RAY);
    //     params.totalQuoted = uint96(3 * WAD);
    //     accountQuota.quota = uint96(WAD);

    //     int256 quotaRevenueChange = QuotasLogic.removeQuota(params, accountQuota);

    //     assertEq(quotaRevenueChange, -(int96(uint96(WAD * 3650 / 10000))) + 1, "Quota revenue change incorrect");

    //     assertEq(params.totalQuoted, uint96(2 * WAD + 1), "Incorrect total quoted");

    //     assertEq(accountQuota.quota, 1, "Incorrect quota");
    // }

    // /// @notice U:[QL-6]: `setLimit` works correctly
    // function test_U_QL_06_setLimit_works_correctly() public {
    //     params.cumulativeIndexLU = uint192(RAY);
    //     params.limit = uint96(WAD);

    //     bool changed = QuotasLogic.setLimit(params, uint96(WAD));

    //     assertTrue(!changed, "Status is changed despite the same value");

    //     changed = QuotasLogic.setLimit(params, uint96(2 * WAD));

    //     assertTrue(changed, "Status is not changed despite different value");

    //     assertEq(params.limit, uint96(2 * WAD), "Limit is incorrect");
    // }

    // /// @notice U:[QL-7]: `setQuotaIncreaseFee` works correctly
    // function test_U_QL_07_setQuotaIncreaseFee_works_correctly() public {
    //     params.cumulativeIndexLU = uint192(RAY);
    //     params.quotaIncreaseFee = 100;

    //     bool changed = QuotasLogic.setQuotaIncreaseFee(params, 100);

    //     assertTrue(!changed, "Status is changed despite the same value");

    //     changed = QuotasLogic.setQuotaIncreaseFee(params, 200);

    //     assertTrue(changed, "Status is not changed despite different value");

    //     assertEq(params.quotaIncreaseFee, 200, "Quota increase fee is incorrect");
    // }

    // /// @notice U:[QL-8]: `updateRate` works correctly
    // function test_U_QL_08_updateRate_works_correctly() public {
    //     params.cumulativeIndexLU = uint192(RAY);
    //     params.totalQuoted = uint96(WAD);
    //     params.rate = 1000;

    //     uint256 lastUpdate = block.timestamp;
    //     vm.warp(block.timestamp + 365 days);

    //     uint256 quotaRevenue = QuotasLogic.updateRate(params, lastUpdate, 2000);

    //     assertEq(quotaRevenue, WAD / 5, "Incorrect quota revenue");

    //     assertEq(params.rate, 2000, "Incorrect rate set");

    //     assertEq(params.cumulativeIndexLU, uint192(11 * RAY / 10));
    // }

    // /// @notice U:[QL-9]: state-changing token-dependent functions fail on non-initialized token
    // function test_U_QL_09_initializedQuotasOnly_reverts_state_changing_functions() public {
    //     vm.expectRevert(TokenIsNotQuotedException.selector);
    //     QuotasLogic.changeQuota(params, accountQuota, block.timestamp, 1);

    //     vm.expectRevert(TokenIsNotQuotedException.selector);
    //     QuotasLogic.accrueAccountQuotaInterest(params, accountQuota, block.timestamp);

    //     vm.expectRevert(TokenIsNotQuotedException.selector);
    //     QuotasLogic.removeQuota(params, accountQuota);

    //     vm.expectRevert(TokenIsNotQuotedException.selector);
    //     QuotasLogic.setLimit(params, 1);

    //     vm.expectRevert(TokenIsNotQuotedException.selector);
    //     QuotasLogic.setQuotaIncreaseFee(params, 1);

    //     vm.expectRevert(TokenIsNotQuotedException.selector);
    //     QuotasLogic.updateRate(params, block.timestamp, 1);
    // }
}
