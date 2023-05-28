// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {QuotasLogic} from "../../../libraries/QuotasLogic.sol";
import {AccountQuota, TokenQuotaParams} from "../../../interfaces/IPoolQuotaKeeper.sol";
import {TestHelper} from "../../lib/helper.sol";

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";
import {RAY, WAD} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

import "forge-std/console.sol";

/// @title Quotas logic test
/// @notice [BM]: Unit tests for QuotasLogic library
contract QuotasLogicTest is TestHelper {
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

        for (uint256 i = 0; i < cases.length; ++i) {
            params.cumulativeIndexLU_RAY = cases[i].cumulativeIndexLU;

            uint192 index = QuotasLogic.calcAdditiveCumulativeIndex(params, cases[i].rate, cases[i].deltaTimestamp);

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
            params.cumulativeIndexLU_RAY = cases[i].cumulativeIndexLU;

            uint256 interest = QuotasLogic.calcAccruedQuotaInterest(
                cases[i].quoted, cases[i].cumulativeIndexNow, cases[i].cumulativeIndexLU
            );

            assertEq(interest, cases[i].expectedInterest, "Interest computed incorrectly");
        }
    }

    struct ChangeQuotaCase {
        string name;
        uint192 cumulativeIndexTokenLU;
        uint192 cumulativeIndexAccountLU;
        uint256 timeSinceLastUpdate;
        uint16 rate;
        uint16 oneTimeFee;
        uint96 previousQuota;
        int96 quotaChange;
        uint96 quotaLimit;
        uint96 totalQuoted;
        uint256 caQuotaInterestChangeExpected;
        int256 quotaRevenueChangeExpected;
        int96 realQuotaChangeExpected;
        bool enableTokenExpected;
        bool disableTokenExpected;
    }

    /// @notice U:[QL-3]: `changeQuota` works correctly
    function test_U_QL_03_changeQuota_works_correctly() public {
        ChangeQuotaCase[1] memory cases = [
            ChangeQuotaCase({
                name: "Increasing quota from 0 without trading fee",
                cumulativeIndexTokenLU: uint192(2 * RAY),
                cumulativeIndexAccountLU: uint192(RAY),
                timeSinceLastUpdate: 1 days,
                rate: 1000,
                oneTimeFee: 0,
                previousQuota: 0,
                quotaChange: int96(int256(WAD)),
                quotaLimit: uint96(2 * WAD),
                totalQuoted: uint96(WAD / 2),
                caQuotaInterestChangeExpected: 0,
                quotaRevenueChangeExpected: int256(int96(int256(WAD)) / 10),
                realQuotaChangeExpected: int96(int256(WAD)),
                enableTokenExpected: true,
                disableTokenExpected: false
            })
        ];

        for (uint256 i = 0; i < cases.length; ++i) {
            params.cumulativeIndexLU_RAY = cases[i].cumulativeIndexTokenLU;
            params.rate = cases[i].rate;
            params.limit = cases[i].quotaLimit;
            params.totalQuoted = cases[i].totalQuoted;
            params.quotaIncreaseFee = cases[i].oneTimeFee;

            accountQuota.quota = cases[i].previousQuota;
            accountQuota.cumulativeIndexLU = cases[i].cumulativeIndexAccountLU;

            (
                uint256 caQuotaInterestChange,
                int256 quotaRevenueChange,
                int96 realQuotaChange,
                bool enableToken,
                bool disableToken
            ) = QuotasLogic.changeQuota(
                params, accountQuota, block.timestamp - cases[i].timeSinceLastUpdate, cases[i].quotaChange
            );

            assertEq(
                caQuotaInterestChange,
                cases[i].caQuotaInterestChangeExpected,
                "caQuotaInterestChange computed incorrectly"
            );

            assertEq(quotaRevenueChange, cases[i].quotaRevenueChangeExpected, "quotaRevenueChange computed incorrectly");

            assertEq(realQuotaChange, cases[i].realQuotaChangeExpected, "realQuotaChange computed incorrectly");

            assertEq(enableToken ? 1 : 0, cases[i].enableTokenExpected ? 1 : 0, "enableToken computed incorrectly");

            assertEq(disableToken ? 1 : 0, cases[i].disableTokenExpected ? 1 : 0, "disableToken computed incorrectly");

            assertEq(
                accountQuota.cumulativeIndexLU,
                QuotasLogic.cumulativeIndexSince(params, block.timestamp - cases[i].timeSinceLastUpdate)
            );
        }
    }
}
