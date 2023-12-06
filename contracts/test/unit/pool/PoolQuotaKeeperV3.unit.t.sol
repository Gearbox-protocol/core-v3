// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../../../interfaces/IAddressProviderV3.sol";
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";

import {
    IPoolQuotaKeeperV3, IPoolQuotaKeeperV3Events, TokenQuotaParams
} from "../../../interfaces/IPoolQuotaKeeperV3.sol";
import {IGaugeV3} from "../../../interfaces/IGaugeV3.sol";
import {IPoolV3} from "../../../interfaces/IPoolV3.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PoolMock} from "../../mocks/pool/PoolMock.sol";

import {CreditManagerMock} from "../../mocks/credit/CreditManagerMock.sol";

import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";

import {PoolQuotaKeeperV3} from "../../../pool/PoolQuotaKeeperV3.sol";
import {GaugeMock} from "../../mocks/governance/GaugeMock.sol";

import {QuotasLogic} from "../../../libraries/QuotasLogic.sol";

// TEST
import "../../lib/constants.sol";

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

import {TestHelper} from "../../lib/helper.sol";

contract PoolQuotaKeeperV3UnitTest is TestHelper, BalanceHelper, IPoolQuotaKeeperV3Events {
    using Math for uint256;

    ContractsRegister public cr;

    PoolQuotaKeeperV3 pqk;
    GaugeMock gaugeMock;

    PoolMock poolMock;
    address underlying;

    CreditManagerMock creditManagerMock;

    function setUp() public {
        _setUp(Tokens.DAI);
    }

    function _setUp(Tokens t) public {
        tokenTestSuite = new TokensTestSuite();

        tokenTestSuite.topUpWETH{value: 100 * WAD}();

        underlying = tokenTestSuite.addressOf(t);

        AddressProviderV3ACLMock addressProvider = new AddressProviderV3ACLMock();
        addressProvider.setAddress(AP_WETH_TOKEN, tokenTestSuite.addressOf(Tokens.WETH), false);

        poolMock = new PoolMock(address(addressProvider), underlying);

        pqk = new PoolQuotaKeeperV3(address(poolMock));

        poolMock.setPoolQuotaKeeper(address(pqk));

        gaugeMock = new GaugeMock(address(poolMock));

        pqk.setGauge(address(gaugeMock));

        vm.startPrank(CONFIGURATOR);

        creditManagerMock = new CreditManagerMock(address(addressProvider), address(poolMock));

        cr = ContractsRegister(addressProvider.getAddressOrRevert(AP_CONTRACTS_REGISTER, NO_VERSION_CONTROL));

        cr.addPool(address(poolMock));
        cr.addCreditManager(address(creditManagerMock));

        vm.label(address(poolMock), "Pool");

        vm.stopPrank();
    }

    //
    // TESTS
    //

    // U:[PQK-1]: constructor sets parameters correctly
    function test_U_PQK_01_constructor_sets_parameters_correctly() public {
        assertEq(address(poolMock), pqk.pool(), "Incorrect poolMock address");
        assertEq(underlying, pqk.underlying(), "Incorrect poolMock address");
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

        vm.expectRevert(CallerNotControllerException.selector);
        pqk.setTokenQuotaIncreaseFee(DUMB_ADDRESS, 1);

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
    function test_U_PQK_04_creditManagerOnly_funcitons_reverts_if_called_by_non_gauge() public {
        vm.startPrank(USER);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        pqk.updateQuota(DUMB_ADDRESS, address(1), 0, 0, 0);

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
        emit AddQuotaToken(DUMB_ADDRESS);

        vm.prank(pqk.gauge());
        pqk.addQuotaToken(DUMB_ADDRESS);

        tokens = pqk.quotedTokens();

        assertEq(tokens.length, 1, "token wasn't added to quotaTokenSet");
        assertEq(tokens[0], DUMB_ADDRESS, "Incorrect address was added to quotaTokenSet");
        assertEq(tokens.length, 1, "token wasn't added to quotaTokenSet");

        (uint16 rate, uint192 cumulativeIndexLU_RAY,, uint96 totalQuoted, uint96 limit,) =
            pqk.getTokenQuotaParams(DUMB_ADDRESS);

        assertEq(totalQuoted, 0, "totalQuoted !=0");
        assertEq(limit, 0, "limit !=0");
        assertEq(rate, 0, "rate !=0");
        assertEq(cumulativeIndexLU_RAY, 1, "Cumulative index !=1");
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

            vm.prank(address(gaugeMock));
            pqk.updateRates();

            int96 daiQuota;
            int96 usdcQuota;

            if (caseIndex == 1) {
                pqk.addCreditManager(address(creditManagerMock));

                pqk.setTokenLimit(DAI, uint96(100_000 * WAD));
                pqk.setTokenLimit(USDC, uint96(100_000 * WAD));

                daiQuota = int96(uint96(100 * WAD));
                usdcQuota = int96(uint96(200 * WAD));

                vm.prank(address(creditManagerMock));
                pqk.updateQuota({
                    creditAccount: DUMB_ADDRESS,
                    token: DAI,
                    requestedChange: daiQuota,
                    minQuota: 0,
                    maxQuota: type(uint96).max
                });

                vm.prank(address(creditManagerMock));
                pqk.updateQuota({
                    creditAccount: DUMB_ADDRESS,
                    token: USDC,
                    requestedChange: usdcQuota,
                    minQuota: 0,
                    maxQuota: type(uint96).max
                });
            }

            vm.warp(block.timestamp + 365 days);

            address[] memory tokens = new address[](2);
            tokens[0] = DAI;
            tokens[1] = USDC;

            vm.expectCall(address(gaugeMock), abi.encodeCall(IGaugeV3.getRates, tokens));

            vm.expectEmit(true, true, false, true);
            emit UpdateTokenQuotaRate(DAI, DAI_QUOTA_RATE);

            vm.expectEmit(true, true, false, true);
            emit UpdateTokenQuotaRate(USDC, USDC_QUOTA_RATE);

            uint256 expectedQuotaRevenue =
                (DAI_QUOTA_RATE * uint96(daiQuota) + USDC_QUOTA_RATE * uint96(usdcQuota)) / PERCENTAGE_FACTOR;

            vm.expectCall(address(poolMock), abi.encodeCall(IPoolV3.setQuotaRevenue, expectedQuotaRevenue));

            vm.prank(address(gaugeMock));
            pqk.updateRates();

            (uint16 rate, uint192 cumulativeIndexLU_RAY,, uint96 totalQuoted, uint96 limit,) =
                pqk.getTokenQuotaParams(DAI);

            assertEq(rate, DAI_QUOTA_RATE, _testCaseErr("Incorrect DAI rate"));
            assertEq(
                cumulativeIndexLU_RAY,
                1 + RAY * DAI_QUOTA_RATE / PERCENTAGE_FACTOR,
                _testCaseErr("Incorrect DAI cumulativeIndexLU")
            );

            (rate, cumulativeIndexLU_RAY,, totalQuoted, limit,) = pqk.getTokenQuotaParams(USDC);

            assertEq(rate, USDC_QUOTA_RATE, _testCaseErr("Incorrect USDC rate"));
            assertEq(
                cumulativeIndexLU_RAY,
                1 + RAY * USDC_QUOTA_RATE / PERCENTAGE_FACTOR,
                _testCaseErr("Incorrect USDC cumulativeIndexLU")
            );

            assertEq(pqk.lastQuotaRateUpdate(), block.timestamp, _testCaseErr("Incorect lastQuotaRateUpdate timestamp"));

            assertEq(poolMock.quotaRevenue(), expectedQuotaRevenue, _testCaseErr("Incorect expectedQuotaRevenue"));
        }
    }

    // U:[PQK-8]: setGauge works as expected
    function test_U_PQK_08_setGauge_works_as_expected() public {
        pqk = new PoolQuotaKeeperV3(address(poolMock));

        assertEq(pqk.gauge(), address(0), "SETUP: incorrect address at start");

        vm.expectEmit(true, true, false, false);
        emit SetGauge(address(gaugeMock));

        pqk.setGauge(address(gaugeMock));
        assertEq(pqk.gauge(), address(gaugeMock), "gauge address wasnt updated");
    }

    // U:[PQK-9]: addCreditManager works as expected
    function test_U_PQK_09_addCreditManager_reverts_for_non_cm_contract() public {
        // Case: non registered credit manager
        vm.expectRevert(RegisteredCreditManagerOnlyException.selector);
        pqk.addCreditManager(DUMB_ADDRESS);

        // Case: credit manager with different poolMock address
        creditManagerMock.setPoolService(DUMB_ADDRESS);
        vm.expectRevert(IncompatibleCreditManagerException.selector);
        pqk.addCreditManager(address(creditManagerMock));
    }

    // U:[PQK-10]: addCreditManager works as expected
    function test_U_PQK_10_addCreditManager_works_as_expected() public {
        pqk = new PoolQuotaKeeperV3(address(poolMock));

        address[] memory managers = pqk.creditManagers();

        assertEq(managers.length, 0, "SETUP: at least one creditmanager is unexpectedly connected");

        vm.expectEmit(true, true, false, false);
        emit AddCreditManager(address(creditManagerMock));

        pqk.addCreditManager(address(creditManagerMock));

        managers = pqk.creditManagers();
        assertEq(managers.length, 1, "Incorrect length of connected managers");
        assertEq(managers[0], address(creditManagerMock), "Incorrect address was added to creditManagerSet");

        // check that funciton works correctly for another one step
        pqk.addCreditManager(address(creditManagerMock));

        managers = pqk.creditManagers();
        assertEq(managers.length, 1, "Incorrect length of connected managers");
        assertEq(managers[0], address(creditManagerMock), "Incorrect address was added to creditManagerSet");
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

        (,,,, uint96 limitSet, bool isActive) = pqk.getTokenQuotaParams(DUMB_ADDRESS);

        assertEq(limitSet, limit, "Incorrect limit was set");
        assertTrue(!isActive, "Incorrect isActive was set");

        vm.warp(block.timestamp + 7 days);
        gaugeMock.updateEpoch();

        (,,,, limitSet, isActive) = pqk.getTokenQuotaParams(DUMB_ADDRESS);

        assertEq(limitSet, limit, "Incorrect limit was set");
        assertTrue(isActive, "Incorrect isActive was set");
    }

    // U:[PQK-13]: setTokenQuotaIncreaseFee works as expected
    function test_U_PQK_13_setTokenQuotaIncreaseFee_works_as_expected() public {
        uint16 fee = 39_99;

        gaugeMock.addQuotaToken(DUMB_ADDRESS, 11);

        vm.expectEmit(true, true, false, true);
        emit SetQuotaIncreaseFee(DUMB_ADDRESS, fee);

        pqk.setTokenQuotaIncreaseFee(DUMB_ADDRESS, fee);

        (,, uint16 feeSet,,,) = pqk.getTokenQuotaParams(DUMB_ADDRESS);

        assertEq(feeSet, fee, "Incorrect fee was set");
    }

    // U:[PQK-14]: updateQuota reverts for unregistered token
    function test_U_PQK_14_updateQuotas_reverts_for_unregistered_token() public {
        pqk.addCreditManager(address(creditManagerMock));

        address link = tokenTestSuite.addressOf(Tokens.LINK);
        vm.expectRevert(TokenIsNotQuotedException.selector);

        vm.prank(address(creditManagerMock));
        pqk.updateQuota({
            creditAccount: DUMB_ADDRESS,
            token: link,
            requestedChange: -int96(uint96(100 * WAD)),
            minQuota: 0,
            maxQuota: 1
        });
    }

    struct UpdateQuotaTestCase {
        string name;
        /// SETUP
        uint256 period;
        int96 change;
        uint96 minQuota;
        uint96 maxQuota;
        /// expected
        uint256 expectedCaQuotaInterestChange;
        uint256 expectedFees;
        int96 expectedRealQuotaChange;
        bool expectedEnableToken;
        bool expectedDisableToken;
        bool expectRevert;
        int256 expectedQuotaRevenueChange;
    }

    // U:[PQK-15]: updateQuotas works as expected
    function test_U_PQK_15_updateQuotas_works_as_expected() public {
        UpdateQuotaTestCase[7] memory cases = [
            UpdateQuotaTestCase({
                name: "Open new quota < limit",
                /// SETUP
                period: 0,
                change: 10_000,
                minQuota: 0,
                maxQuota: 100_000_000,
                ///
                expectedCaQuotaInterestChange: 0,
                expectedFees: 4_000,
                expectedRealQuotaChange: 10_000,
                expectedEnableToken: true,
                expectedDisableToken: false,
                expectRevert: false,
                expectedQuotaRevenueChange: 10_000 * 10 / 100 // 10% additional rate
            }),
            UpdateQuotaTestCase({
                name: "Quota in a year",
                /// SETUP
                period: 365 days,
                change: 0,
                minQuota: 0,
                maxQuota: 100_000_000,
                /// 10_000 * 10% quota
                expectedCaQuotaInterestChange: 1_000,
                expectedFees: 0,
                expectedRealQuotaChange: 0,
                expectedEnableToken: false,
                expectedDisableToken: false,
                expectRevert: false,
                expectedQuotaRevenueChange: 0
            }),
            UpdateQuotaTestCase({
                name: "Quota < minQuota",
                /// SETUP
                period: 0,
                change: 0,
                minQuota: 11_000,
                maxQuota: 100_000_000,
                /// 10_000 * 10% quota
                expectedCaQuotaInterestChange: 0,
                expectedFees: 0,
                expectedRealQuotaChange: 0,
                expectedEnableToken: false,
                expectedDisableToken: false,
                expectRevert: true,
                expectedQuotaRevenueChange: 0
            }),
            UpdateQuotaTestCase({
                name: "Quota > maxQuota",
                /// SETUP
                period: 0,
                change: 0,
                minQuota: 0,
                maxQuota: 9_000,
                /// 10_000 * 10% quota
                expectedCaQuotaInterestChange: 0,
                expectedFees: 0,
                expectedRealQuotaChange: 0,
                expectedEnableToken: false,
                expectedDisableToken: false,
                expectRevert: true,
                expectedQuotaRevenueChange: 0
            }),
            UpdateQuotaTestCase({
                name: "Quota reduction < minQuota, quota > minQuota",
                /// SETUP
                period: 365 days,
                change: -5_000,
                minQuota: 1_000,
                maxQuota: 100_000_000,
                /// 10_000 * 10% quota
                expectedCaQuotaInterestChange: 1_000,
                expectedFees: 0,
                expectedRealQuotaChange: -5000,
                expectedEnableToken: false,
                expectedDisableToken: false,
                expectRevert: false,
                expectedQuotaRevenueChange: (-5_000 * 10 / 100)
            }),
            UpdateQuotaTestCase({
                name: "Quota > limit",
                /// SETUP
                period: 365 days,
                change: 100_000,
                minQuota: 1_000,
                maxQuota: 100_000_000,
                /// 10_000 * 10% quota
                expectedCaQuotaInterestChange: 500, // 500 for prev year + fee
                expectedFees: 35_000 * 40 / 100,
                expectedRealQuotaChange: 35_000,
                expectedEnableToken: false,
                expectedDisableToken: false,
                expectRevert: false,
                expectedQuotaRevenueChange: (35_000 * 10 / 100)
            }),
            UpdateQuotaTestCase({
                name: "Quota disable token is fully paid",
                /// SETUP
                period: 365 days,
                change: -40_000,
                minQuota: 0,
                maxQuota: 100_000_000,
                expectedCaQuotaInterestChange: 40_000 * 10 / 100, // 4_000 for prev year
                expectedFees: 0,
                expectedRealQuotaChange: -40_000,
                expectedEnableToken: false,
                expectedDisableToken: true,
                expectRevert: false,
                expectedQuotaRevenueChange: (-40_000 * 10 / 100)
            })
        ];

        pqk.addCreditManager(address(creditManagerMock));

        address token = makeAddr("TOKEN");

        address creditAccount = makeAddr("CREDIT_ACCOUNT");

        gaugeMock.addQuotaToken({token: token, rate: 10_00}); // 10% rate

        vm.prank(address(gaugeMock));
        pqk.updateRates();
        pqk.setTokenLimit({token: token, limit: 40_000}); // 40_000 max
        pqk.setTokenQuotaIncreaseFee({token: token, fee: 40_00}); // 40%

        for (uint256 i; i < cases.length; ++i) {
            UpdateQuotaTestCase memory _case = cases[i];

            caseName = _case.name;

            vm.warp(block.timestamp + _case.period);

            /// UPDATE QUOTA

            (uint96 quota0,) = pqk.getQuotaAndOutstandingInterest(creditAccount, token);

            if (_case.expectRevert) {
                vm.expectRevert(QuotaIsOutOfBoundsException.selector);
            } else {
                if (_case.expectedQuotaRevenueChange != 0) {
                    vm.expectCall(
                        address(poolMock),
                        abi.encodeCall(IPoolV3.updateQuotaRevenue, (_case.expectedQuotaRevenueChange))
                    );
                }
            }

            if (_case.expectedRealQuotaChange != 0) {
                vm.expectEmit(true, true, false, false);
                emit UpdateQuota(creditAccount, token, _case.expectedRealQuotaChange);
            }

            vm.prank(address(creditManagerMock));
            (uint128 caQuotaInterestChange,, bool enableToken, bool disableToken) =
                pqk.updateQuota(creditAccount, token, _case.change, _case.minQuota, _case.maxQuota);

            (uint96 quota1,) = pqk.getQuotaAndOutstandingInterest(creditAccount, token);

            if (!_case.expectRevert) {
                assertEq(
                    caQuotaInterestChange,
                    _case.expectedCaQuotaInterestChange,
                    _testCaseErr("Incorrece caQuotaInterestChange")
                );

                assertEq(
                    int96(quota1) - int96(quota0),
                    _case.expectedRealQuotaChange,
                    _testCaseErr("Incorrece expectedRealQuotaChang")
                );

                assertEq(enableToken, _case.expectedEnableToken, _testCaseErr("Incorrece enableToken"));

                assertEq(disableToken, _case.expectedDisableToken, _testCaseErr("Incorrece disableToken"));
            }
        }
    }

    struct RemoveQuotasCase {
        uint96 token1Quota;
        uint96 token2Quota;
        uint96 token1TotalQuoted;
        uint96 token2TotalQuoted;
        bool setLimitsToZero;
        int256 expectedRevenueChange;
    }

    /// @dev U:[PQK-16]: removeQuotas works correctly
    function test_U_PQK_16_removeQuotas_works_correctly() public {
        RemoveQuotasCase[4] memory cases = [
            RemoveQuotasCase({
                token1Quota: 1,
                token2Quota: 0,
                token1TotalQuoted: uint96(WAD),
                token2TotalQuoted: uint96(2 * WAD),
                setLimitsToZero: false,
                expectedRevenueChange: 0
            }),
            RemoveQuotasCase({
                token1Quota: uint96(WAD),
                token2Quota: 0,
                token1TotalQuoted: uint96(WAD),
                token2TotalQuoted: uint96(2 * WAD),
                setLimitsToZero: false,
                expectedRevenueChange: -int96(uint96(WAD)) / 10
            }),
            RemoveQuotasCase({
                token1Quota: uint96(WAD / 2),
                token2Quota: uint96(WAD / 3),
                token1TotalQuoted: uint96(WAD),
                token2TotalQuoted: uint96(2 * WAD),
                setLimitsToZero: false,
                expectedRevenueChange: -int96(uint96(WAD / 2)) / 10 - int96(uint96(WAD / 3)) / 5
            }),
            RemoveQuotasCase({
                token1Quota: 1,
                token2Quota: 0,
                token1TotalQuoted: uint96(WAD),
                token2TotalQuoted: uint96(2 * WAD),
                setLimitsToZero: true,
                expectedRevenueChange: 0
            })
        ];

        pqk.addCreditManager(address(creditManagerMock));

        address token1 = makeAddr("TOKEN1");
        address token2 = makeAddr("TOKEN2");

        address creditAccount = makeAddr("CREDIT_ACCOUNT");

        gaugeMock.addQuotaToken({token: token1, rate: 10_00});
        gaugeMock.addQuotaToken({token: token2, rate: 20_00});

        vm.prank(address(gaugeMock));
        pqk.updateRates();
        pqk.setTokenLimit({token: token1, limit: uint96(4 * WAD)});
        pqk.setTokenLimit({token: token2, limit: uint96(3 * WAD)});

        address[] memory tokens = new address[](2);
        tokens[0] = token1;
        tokens[1] = token2;

        for (uint256 i = 0; i < cases.length; ++i) {
            uint256 snapshot = vm.snapshot();

            vm.prank(address(creditManagerMock));
            pqk.updateQuota({
                creditAccount: creditAccount,
                token: token1,
                requestedChange: int96(cases[i].token1Quota),
                minQuota: 0,
                maxQuota: type(uint96).max
            });

            vm.prank(address(creditManagerMock));
            pqk.updateQuota({
                creditAccount: creditAccount,
                token: token2,
                requestedChange: int96(cases[i].token2Quota),
                minQuota: 0,
                maxQuota: type(uint96).max
            });

            vm.prank(address(creditManagerMock));
            pqk.updateQuota({
                creditAccount: DUMB_ADDRESS,
                token: token1,
                requestedChange: int96(cases[i].token1TotalQuoted - cases[i].token1Quota),
                minQuota: 0,
                maxQuota: type(uint96).max
            });

            vm.prank(address(creditManagerMock));
            pqk.updateQuota({
                creditAccount: DUMB_ADDRESS,
                token: token2,
                requestedChange: int96(cases[i].token2TotalQuoted - cases[i].token2Quota),
                minQuota: 0,
                maxQuota: type(uint96).max
            });

            if (cases[i].expectedRevenueChange != 0) {
                vm.expectCall(
                    address(poolMock), abi.encodeCall(IPoolV3.updateQuotaRevenue, (cases[i].expectedRevenueChange))
                );
            }

            if (cases[i].token1Quota != 0) {
                vm.expectEmit(true, true, false, false);
                emit UpdateQuota(creditAccount, token1, -int96(cases[i].token1Quota));
            }

            if (cases[i].token2Quota != 0) {
                vm.expectEmit(true, true, false, false);
                emit UpdateQuota(creditAccount, token2, -int96(cases[i].token1Quota));
            }

            vm.prank(address(creditManagerMock));
            pqk.removeQuotas(creditAccount, tokens, cases[i].setLimitsToZero);

            {
                (uint96 quota1,) = pqk.getQuotaAndOutstandingInterest(creditAccount, token1);
                (uint96 quota2,) = pqk.getQuotaAndOutstandingInterest(creditAccount, token2);

                assertEq(quota1, 0, "Quota 1 was not removed");

                assertEq(quota2, 0, "Quota 2 was not removed");
            }

            (,,, uint96 totalQuoted1, uint96 limit1,) = pqk.getTokenQuotaParams(token1);
            (,,, uint96 totalQuoted2, uint96 limit2,) = pqk.getTokenQuotaParams(token2);

            assertEq(totalQuoted1, cases[i].token1TotalQuoted - cases[i].token1Quota, "Incorrect new total quoted 1");

            assertEq(totalQuoted2, cases[i].token2TotalQuoted - cases[i].token2Quota, "Incorrect new total quoted 2");

            if (cases[i].setLimitsToZero) {
                assertEq(limit1, 0, "Limit 1 was not set to zero");

                assertEq(limit2, 0, "Limit 2 was not set to zero");
            }

            vm.revertTo(snapshot);
        }
    }

    /// @dev U:[PQK-17]: accrueQuotaInterest works correctly
    function test_U_PQK_17_accrueQuotaInterest_works_correctly() external {
        pqk.addCreditManager(address(creditManagerMock));

        address creditAccount = makeAddr("CREDIT_ACCOUNT");

        address[] memory tokens = new address[](2);
        tokens[0] = DUMB_ADDRESS;

        vm.expectRevert(TokenIsNotQuotedException.selector);

        vm.prank(address(creditManagerMock));
        pqk.accrueQuotaInterest(creditAccount, tokens);

        address token1 = makeAddr("TOKEN1");
        address token2 = makeAddr("TOKEN2");

        gaugeMock.addQuotaToken({token: token1, rate: 10_00});
        gaugeMock.addQuotaToken({token: token2, rate: 20_00});

        vm.prank(address(gaugeMock));
        pqk.updateRates();
        pqk.setTokenLimit({token: token1, limit: uint96(4 * WAD)});
        pqk.setTokenLimit({token: token2, limit: uint96(3 * WAD)});

        tokens[0] = token1;
        tokens[1] = token2;

        vm.prank(address(creditManagerMock));
        pqk.updateQuota({
            creditAccount: creditAccount,
            token: token1,
            requestedChange: int96(uint96(WAD)),
            minQuota: 0,
            maxQuota: type(uint96).max
        });

        vm.prank(address(creditManagerMock));
        pqk.updateQuota({
            creditAccount: creditAccount,
            token: token2,
            requestedChange: int96(uint96(WAD)),
            minQuota: 0,
            maxQuota: type(uint96).max
        });

        uint256 timestampLU = block.timestamp;
        vm.warp(block.timestamp + 365 days);

        uint192 expectedIndex1 = QuotasLogic.cumulativeIndexSince(1, 1000, timestampLU);
        // uint192 expectedIndex2 = QuotasLogic.cumulativeIndexSince(uint192(RAY), 2000, timestampLU);

        vm.prank(address(creditManagerMock));
        pqk.accrueQuotaInterest(creditAccount, tokens);

        (, uint192 actualIndex1) = pqk.getQuota(creditAccount, token1);
        // (, uint192 actualIndex2) = pqk.getQuota(creditAccount, token2);

        assertEq(expectedIndex1, actualIndex1, "Incorrect token 1 index");

        assertEq(expectedIndex1, actualIndex1, "Incorrect token 2 index");
    }
}
