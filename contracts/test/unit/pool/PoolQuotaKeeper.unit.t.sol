// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../../interfaces/IAddressProviderV3.sol";
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";

import {IPoolQuotaKeeper, IPoolQuotaKeeperEvents, TokenQuotaParams} from "../../../interfaces/IPoolQuotaKeeper.sol";
import {IGauge} from "../../../interfaces/IGauge.sol";
import {IPoolV3} from "../../../interfaces/IPoolV3.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PoolMock} from "../../mocks/pool/PoolMock.sol";

import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";
import {CreditManagerMock} from "../../mocks/credit/CreditManagerMock.sol";

import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";

import {PoolQuotaKeeper} from "../../../pool/PoolQuotaKeeper.sol";
import {GaugeMock} from "../../mocks/pool/GaugeMock.sol";

// TEST
import "../../lib/constants.sol";

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

import {TestHelper} from "../../lib/helper.sol";
import "forge-std/console.sol";

contract PoolQuotaKeeperUnitTest is TestHelper, BalanceHelper, IPoolQuotaKeeperEvents {
    using Math for uint256;

    ContractsRegister public cr;

    PoolQuotaKeeper pqk;
    GaugeMock gaugeMock;

    PoolMock pool;
    address underlying;

    CreditManagerMock cmMock;

    function setUp() public {
        _setUp(Tokens.DAI);
    }

    function _setUp(Tokens t) public {
        tokenTestSuite = new TokensTestSuite();

        tokenTestSuite.topUpWETH{value: 100 * WAD}();

        underlying = tokenTestSuite.addressOf(t);

        AddressProviderV3ACLMock addressProvider = new AddressProviderV3ACLMock();
        addressProvider.setAddress(AP_WETH_TOKEN, tokenTestSuite.addressOf(Tokens.WETH), false);

        pool = new PoolMock(address(addressProvider), underlying);

        pqk = new PoolQuotaKeeper(address(pool));

        pool.setPoolQuotaKeeper(address(pqk));

        gaugeMock = new GaugeMock(address(pool));

        pqk.setGauge(address(gaugeMock));

        vm.startPrank(CONFIGURATOR);

        cmMock = new CreditManagerMock(address(addressProvider), address(pool));

        cr = ContractsRegister(addressProvider.getAddressOrRevert(AP_CONTRACTS_REGISTER, 1));

        cr.addPool(address(pool));
        cr.addCreditManager(address(cmMock));

        vm.label(address(pool), "Pool");

        vm.stopPrank();
    }

    //
    // TESTS
    //

    // U:[PQK-1]: constructor sets parameters correctly
    function test_U_PQK_01_constructor_sets_parameters_correctly() public {
        assertEq(address(pool), pqk.pool(), "Incorrect pool address");
        assertEq(underlying, pqk.underlying(), "Incorrect pool address");
    }

    // U:[PQK-2]: configuration functions revert if called nonConfigurator(nonController)
    function test_U_PQK_02_configuration_functions_reverts_if_call_nonConfigurator() public {
        vm.startPrank(USER);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        pqk.setGauge(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        pqk.addCreditManager(DUMB_ADDRESS);

        vm.expectRevert(CallerNotControllerException.selector);
        pqk.setTokenLimit(DUMB_ADDRESS, 1);

        vm.stopPrank();
    }

    // U:[PQK-3]: gaugeOnly funcitons revert if called by non-gauge contract
    function test_U_PQK_03_gaugeOnly_funcitons_reverts_if_called_by_non_gauge() public {
        vm.startPrank(USER);

        vm.expectRevert(CallerNotGaugeException.selector);
        pqk.addQuotaToken(DUMB_ADDRESS);

        vm.expectRevert(CallerNotGaugeException.selector);
        pqk.updateRates();

        vm.stopPrank();
    }

    // U:[PQK-4]: creditManagerOnly funcitons revert if called by non registered creditManager
    function test_U_PQK_04_gaugeOnly_funcitons_reverts_if_called_by_non_gauge() public {
        vm.startPrank(USER);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        pqk.updateQuota(DUMB_ADDRESS, address(1), 0);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        pqk.removeQuotas(DUMB_ADDRESS, new address[](1), false);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        pqk.accrueQuotaInterest(DUMB_ADDRESS, new address[](1));
        vm.stopPrank();
    }

    // U:[PQK-5]: addQuotaToken adds token and set parameters correctly
    function test_U_PQK_05_addQuotaToken_adds_token_and_set_parameters_correctly() public {
        address[] memory tokens = pqk.quotedTokens();

        assertEq(tokens.length, 0, "SETUP: tokens set unexpectedly has tokens");

        vm.expectEmit(true, true, false, false);
        emit NewQuotaTokenAdded(DUMB_ADDRESS);

        vm.prank(pqk.gauge());
        pqk.addQuotaToken(DUMB_ADDRESS);

        tokens = pqk.quotedTokens();

        assertEq(tokens.length, 1, "token wasn't added to quotaTokenSet");
        assertEq(tokens[0], DUMB_ADDRESS, "Incorrect address was added to quotaTokenSet");
        assertEq(tokens.length, 1, "token wasn't added to quotaTokenSet");

        (uint96 totalQuoted, uint96 limit, uint16 rate, uint192 cumulativeIndexLU_RAY,) =
            pqk.totalQuotaParams(DUMB_ADDRESS);

        assertEq(totalQuoted, 0, "totalQuoted !=0");
        assertEq(limit, 0, "limit !=0");
        assertEq(rate, 0, "rate !=0");
        assertEq(cumulativeIndexLU_RAY, RAY, "Cumulative index !=RAY");
    }

    // U:[PQK-6]: addQuotaToken reverts on adding the same token twice
    function test_U_PQK_06_addQuotaToken_reverts_on_adding_the_same_token_twice() public {
        address gauge = pqk.gauge();
        vm.prank(gauge);
        pqk.addQuotaToken(DUMB_ADDRESS);

        vm.prank(gauge);
        vm.expectRevert(TokenAlreadyAddedException.selector);
        pqk.addQuotaToken(DUMB_ADDRESS);
    }

    // U:[PQK-7]: updateRates works as expected
    function test_U_PQK_07_updateRates_works_as_expected() public {
        address DAI = tokenTestSuite.addressOf(Tokens.DAI);
        address USDC = tokenTestSuite.addressOf(Tokens.USDC);

        uint16 DAI_QUOTA_RATE = 20_00;
        uint16 USDC_QUOTA_RATE = 45_00;

        for (uint256 caseIndex; caseIndex < 2; ++caseIndex) {
            caseName = caseIndex == 1 ? "With totalQuoted" : "Without totalQuotae";

            setUp();

            gaugeMock.addQuotaToken(DAI, DAI_QUOTA_RATE);

            gaugeMock.addQuotaToken(USDC, USDC_QUOTA_RATE);

            int96 daiQuota;
            int96 usdcQuota;

            if (caseIndex == 1) {
                pqk.addCreditManager(address(cmMock));

                pqk.setTokenLimit(DAI, uint96(100_000 * WAD));
                pqk.setTokenLimit(USDC, uint96(100_000 * WAD));

                daiQuota = int96(uint96(100 * WAD));
                usdcQuota = int96(uint96(200 * WAD));

                vm.prank(address(cmMock));
                pqk.updateQuota({creditAccount: DUMB_ADDRESS, token: DAI, quotaChange: daiQuota});

                vm.prank(address(cmMock));
                pqk.updateQuota({creditAccount: DUMB_ADDRESS, token: USDC, quotaChange: usdcQuota});
            }

            vm.warp(block.timestamp + 365 days);
            address[] memory tokens = new address[](2);
            tokens[0] = DAI;
            tokens[1] = USDC;
            vm.expectCall(address(gaugeMock), abi.encodeCall(IGauge.getRates, tokens));

            vm.expectEmit(true, true, false, true);
            emit UpdateTokenQuotaRate(DAI, DAI_QUOTA_RATE);

            vm.expectEmit(true, true, false, true);
            emit UpdateTokenQuotaRate(USDC, USDC_QUOTA_RATE);

            uint256 expectedQuotaRevenue =
                (DAI_QUOTA_RATE * uint96(daiQuota) + USDC_QUOTA_RATE * uint96(usdcQuota)) / PERCENTAGE_FACTOR;

            vm.expectCall(address(pool), abi.encodeCall(IPoolV3.setQuotaRevenue, expectedQuotaRevenue));

            gaugeMock.updateEpoch();

            (uint96 totalQuoted, uint96 limit, uint16 rate, uint192 cumulativeIndexLU_RAY,) = pqk.totalQuotaParams(DAI);

            assertEq(rate, DAI_QUOTA_RATE, _testCaseErr("Incorrect DAI rate"));
            assertEq(
                cumulativeIndexLU_RAY,
                RAY * (PERCENTAGE_FACTOR + DAI_QUOTA_RATE) / PERCENTAGE_FACTOR,
                _testCaseErr("Incorrect DAI cumulativeIndexLU")
            );

            (totalQuoted, limit, rate, cumulativeIndexLU_RAY,) = pqk.totalQuotaParams(USDC);

            assertEq(rate, USDC_QUOTA_RATE, _testCaseErr("Incorrect USDC rate"));
            assertEq(
                cumulativeIndexLU_RAY,
                RAY * (PERCENTAGE_FACTOR + USDC_QUOTA_RATE) / PERCENTAGE_FACTOR,
                _testCaseErr("Incorrect USDC cumulativeIndexLU")
            );

            assertEq(pqk.lastQuotaRateUpdate(), block.timestamp, _testCaseErr("Incorect lastQuotaRateUpdate timestamp"));

            assertEq(pool.quotaRevenue(), expectedQuotaRevenue, _testCaseErr("Incorect expectedQuotaRevenue"));
        }
    }

    // U:[PQK-8]: setGauge works as expected
    function test_U_PQK_08_setGauge_works_as_expected() public {
        pqk = new PoolQuotaKeeper(address(pool));

        assertEq(pqk.gauge(), address(0), "SETUP: incorrect address at start");

        vm.warp(block.timestamp + 2 days);

        vm.expectEmit(true, true, false, false);
        emit SetGauge(address(gaugeMock));

        pqk.setGauge(address(gaugeMock));

        uint256 gaugeUpdateTimestamp = block.timestamp;

        vm.warp(block.timestamp + 2 days);

        assertEq(pqk.gauge(), address(gaugeMock), "gauge address wasnt updated");
        assertEq(pqk.lastQuotaRateUpdate(), gaugeUpdateTimestamp, "lastQuotaRateUpdate wasnt updated");

        // IF address the same, the function updates nothing
        pqk.setGauge(address(gaugeMock));
        assertEq(pqk.lastQuotaRateUpdate(), gaugeUpdateTimestamp, "lastQuotaRateUpdate was unexpectedly updated");
    }

    // U:[PQK-9]: addCreditManager works as expected
    function test_U_PQK_09_addCreditManager_reverts_for_non_cm_contract() public {
        vm.expectRevert(RegisteredCreditManagerOnlyException.selector);
        pqk.addCreditManager(DUMB_ADDRESS);

        cmMock.setPoolService(DUMB_ADDRESS);

        vm.expectRevert(IncompatibleCreditManagerException.selector);

        pqk.addCreditManager(address(cmMock));
    }

    // U:[PQK-10]: addCreditManager works as expected
    function test_U_PQK_10_addCreditManager_works_as_expected() public {
        pqk = new PoolQuotaKeeper(address(pool));

        address[] memory managers = pqk.creditManagers();

        assertEq(managers.length, 0, "SETUP: at least one creditmanager is unexpectedly connected");

        vm.expectEmit(true, true, false, false);
        emit AddCreditManager(address(cmMock));

        pqk.addCreditManager(address(cmMock));

        managers = pqk.creditManagers();
        assertEq(managers.length, 1, "Incorrect length of connected managers");
        assertEq(managers[0], address(cmMock), "Incorrect address was added to creditManagerSet");

        // check that funciton works correctly for another one step
        pqk.addCreditManager(address(cmMock));

        managers = pqk.creditManagers();
        assertEq(managers.length, 1, "Incorrect length of connected managers");
        assertEq(managers[0], address(cmMock), "Incorrect address was added to creditManagerSet");
    }

    // U:[PQK-11]: setTokenLimit reverts for unregistered token
    function test_U_PQK_11_reverts_for_unregistered_token() public {
        vm.expectRevert(TokenIsNotQuotedException.selector);
        pqk.setTokenLimit(DUMB_ADDRESS, 1);
    }

    // U:[PQK-12]: setTokenLimit works as expected
    function test_U_PQK_12_setTokenLimit_works_as_expected() public {
        uint96 limit = 435_223_999;

        gaugeMock.addQuotaToken(DUMB_ADDRESS, 11);

        vm.expectEmit(true, true, false, true);
        emit SetTokenLimit(DUMB_ADDRESS, limit);

        pqk.setTokenLimit(DUMB_ADDRESS, limit);

        (, uint96 limitSet,,,) = pqk.totalQuotaParams(DUMB_ADDRESS);

        assertEq(limitSet, limit, "Incorrect limit was set");
    }

    // U:[PQK-13]: updateQuota reverts for unregistered token
    function test_U_PQK_13_updateQuotas_reverts_for_unregistered_token() public {
        pqk.addCreditManager(address(cmMock));

        address link = tokenTestSuite.addressOf(Tokens.LINK);
        vm.expectRevert(TokenIsNotQuotedException.selector);

        vm.prank(address(cmMock));
        pqk.updateQuota({creditAccount: DUMB_ADDRESS, token: link, quotaChange: int96(uint96(100 * WAD))});
    }

    struct QuotaTest {
        Tokens token;
        int96 change;
        uint256 limit;
        uint16 rate;
        uint256 expectedTotalQuotedAfter;
    }

    struct QuotaTestInAYear {
        Tokens token;
        int96 change;
        uint256 expectedTotalQuotedAfter;
    }

    struct UpdateQuotasTestCase {
        string name;
        /// SETUP
        uint256 quotaLen;
        QuotaTest[2] initialQuotas;
        uint256 initialEnabledTokens;
        /// expected
        int128 expectedQuotaRevenueChange;
        uint256 expectedCaQuotaInterestChange;
        uint256 expectedEnableTokenMaskUpdated;
        // In 1 YEAR
        QuotaTestInAYear[2] quotasInAYear;
        /// expected in 1 YEAR
        int128 expectedInAYearQuotaRevenueChange;
        uint256 expectedInAYearCaQuotaInterestChange;
        uint256 expectedInAYearEnableTokenMaskUpdated;
    }

    // // U:[PQK-14]: updateQuotas works as expected
    // function test_U_PQK_14_updateQuotas_works_as_expected() public {
    //     UpdateQuotasTestCase[1] memory cases = [
    //         UpdateQuotasTestCase({
    //             name: "Quota simple test",
    //             /// SETUP
    //             quotaLen: 2,
    //             initialQuotas: [
    //                 QuotaTest({token: Tokens.DAI, change: 100, limit: 10_000, rate: 10_00, expectedTotalQuotedAfter: 100}),
    //                 QuotaTest({token: Tokens.USDC, change: 150, limit: 1_000, rate: 20_00, expectedTotalQuotedAfter: 150})
    //             ],
    //             initialEnabledTokens: 0,
    //             /// expected
    //             expectedQuotaRevenueChange: 0,
    //             expectedCaQuotaInterestChange: 0,
    //             expectedEnableTokenMaskUpdated: 3,
    //             // In 1 YEAR
    //             quotasInAYear: [
    //                 QuotaTestInAYear({token: Tokens.DAI, change: 100, expectedTotalQuotedAfter: 200}),
    //                 QuotaTestInAYear({token: Tokens.USDC, change: -100, expectedTotalQuotedAfter: 50})
    //             ],
    //             expectedInAYearQuotaRevenueChange: 0,
    //             expectedInAYearCaQuotaInterestChange: 0,
    //             expectedInAYearEnableTokenMaskUpdated: 3
    //         })
    //     ];
    //     for (uint256 i; i < cases.length; ++i) {
    //         UpdateQuotasTestCase memory testCase = cases[i];

    //         setUp();
    //         vm.startPrank(CONFIGURATOR);

    //         pqk.addCreditManager(address(cmMock));

    //         QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](testCase.quotaLen);

    //         for (uint256 j; j < testCase.quotaLen; ++j) {
    //             address token = tokenTestSuite.addressOf(testCase.initialQuotas[j].token);
    //             cmMock.addToken(token, 1 << (j));
    //             gaugeMock.addQuotaToken(token, testCase.initialQuotas[j].rate);
    //             pqk.setTokenLimit(token, uint96(testCase.initialQuotas[j].limit));

    //             quotaUpdates[j] = QuotaUpdate({token: token, quotaChange: testCase.initialQuotas[j].change});
    //         }

    //         vm.stopPrank();

    //         int128 quBefore = int128(pool.quotaRevenue());

    //         /// UPDATE QUOTAS

    //         uint256 tokensToEnable;
    //         uint256 tokensToDisable;
    //         uint256 caQuotaInterestChange;
    //         (caQuotaInterestChange, tokensToEnable, tokensToDisable) = cmMock.updateQuotas(DUMB_ADDRESS, quotaUpdates);

    //         // assertEq(
    //         //     enableTokenMaskUpdated,
    //         //     testCase.expectedEnableTokenMaskUpdated,
    //         //     _testCaseErr(testCase.name, "Incorrece enable token mask")
    //         // );

    //         assertEq(
    //             caQuotaInterestChange,
    //             testCase.expectedCaQuotaInterestChange,
    //             _testCaseErr(testCase.name, "Incorrece caQuotaInterestChange")
    //         );

    //         assertEq(
    //             quBefore - int128(pool.quotaRevenue()),
    //             testCase.expectedQuotaRevenueChange,
    //             _testCaseErr(testCase.name, "Incorrece QuotaRevenueChange")
    //         );

    //         for (uint256 j; j < testCase.quotaLen; ++j) {
    //             address token = tokenTestSuite.addressOf(testCase.initialQuotas[j].token);
    //             (uint96 totalQuoted,,,) = pqk.totalQuotaParams(token);

    //             assertEq(
    //                 totalQuoted,
    //                 testCase.initialQuotas[j].expectedTotalQuotedAfter,
    //                 _testCaseErr(testCase.name, "Incorrect expectedTotalQuotedAfter")
    //             );
    //         }
    //         vm.warp(block.timestamp + 365 days);

    //         for (uint256 j; j < testCase.quotaLen; ++j) {
    //             address token = tokenTestSuite.addressOf(testCase.quotasInAYear[j].token);

    //             quotaUpdates[j] = QuotaUpdate({token: token, quotaChange: testCase.quotasInAYear[j].change});
    //         }

    //         (caQuotaInterestChange, tokensToEnable, tokensToDisable) = cmMock.updateQuotas(DUMB_ADDRESS, quotaUpdates);

    //         // TODO: change the test
    //         // assertEq(
    //         //     enableTokenMaskUpdatedInAYear,
    //         //     testCase.expectedInAYearEnableTokenMaskUpdated,
    //         //     _testCaseErr(testCase.name, "Incorrect enable token mask in a year")
    //         // );

    //         assertEq(
    //             caQuotaInterestChange,
    //             testCase.expectedInAYearCaQuotaInterestChange,
    //             _testCaseErr(testCase.name, "Incorrect caQuotaInterestChange in a year")
    //         );

    //         assertEq(
    //             quBefore - int128(pool.quotaRevenue()),
    //             testCase.expectedInAYearQuotaRevenueChange,
    //             _testCaseErr(testCase.name, "Incorrect QuotaRevenueChange in a year")
    //         );

    //         for (uint256 j; j < testCase.quotaLen; ++j) {
    //             address token = tokenTestSuite.addressOf(testCase.initialQuotas[j].token);
    //             (uint96 totalQuoted,,,) = pqk.totalQuotaParams(token);

    //             assertEq(
    //                 totalQuoted,
    //                 testCase.quotasInAYear[j].expectedTotalQuotedAfter,
    //                 _testCaseErr(testCase.name, "Incorrect expectedTotalQuotedAfter in a year")
    //             );
    //         }
    //     }
    // }
}
