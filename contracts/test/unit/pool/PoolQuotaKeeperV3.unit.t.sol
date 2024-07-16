// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.23;

import "../../interfaces/IAddressProviderV3.sol";
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";

import {IPoolQuotaKeeperV3, TokenQuotaParams} from "../../../interfaces/IPoolQuotaKeeperV3.sol";
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

import {PERCENTAGE_FACTOR} from "../../../libraries/Constants.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

import {TestHelper} from "../../lib/helper.sol";

contract PoolQuotaKeeperV3UnitTest is TestHelper, BalanceHelper {
    using Math for uint256;

    AddressProviderV3ACLMock addressProvider;

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

        addressProvider = new AddressProviderV3ACLMock();
        addressProvider.setAddress(AP_WETH_TOKEN, tokenTestSuite.addressOf(Tokens.WETH), false);

        poolMock = new PoolMock(address(addressProvider), address(addressProvider), underlying);

        pqk = new PoolQuotaKeeperV3(address(addressProvider), address(addressProvider), underlying, address(poolMock));

        poolMock.setPoolQuotaKeeper(address(pqk));

        gaugeMock = new GaugeMock(address(addressProvider), address(pqk));

        pqk.setGauge(address(gaugeMock));

        vm.startPrank(CONFIGURATOR);

        creditManagerMock = new CreditManagerMock(address(addressProvider), address(poolMock));

        addressProvider.addPool(address(poolMock));
        addressProvider.addCreditManager(address(creditManagerMock));

        vm.label(address(poolMock), "Pool");

        vm.stopPrank();
    }

    //
    // TESTS
    //

    /// @notice U:[QK-1]: constructor sets parameters correctly
    function test_U_QK_01_constructor_sets_parameters_correctly() public view {
        assertEq(address(poolMock), pqk.pool(), "Incorrect poolMock address");
        assertEq(underlying, pqk.underlying(), "Incorrect poolMock address");
    }

    /// @notice U:[QK-2]: configuration functions revert if called nonConfigurator(nonController)
    function test_U_QK_02_configuration_functions_reverts_if_call_nonConfigurator() public {
        vm.startPrank(USER);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        pqk.setGauge(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        pqk.addCreditManager(DUMB_ADDRESS);

        vm.expectRevert(CallerNotControllerOrConfiguratorException.selector);
        pqk.setTokenLimit(DUMB_ADDRESS, 1);

        vm.expectRevert(CallerNotControllerOrConfiguratorException.selector);
        pqk.setTokenQuotaIncreaseFee(DUMB_ADDRESS, 1);

        vm.stopPrank();
    }

    /// @notice U:[QK-3]: gaugeOnly funcitons revert if called by non-gauge contract
    function test_U_QK_03_gaugeOnly_funcitons_reverts_if_called_by_non_gauge() public {
        vm.startPrank(USER);

        vm.expectRevert(CallerNotGaugeException.selector);
        pqk.addQuotaToken(DUMB_ADDRESS);

        vm.expectRevert(CallerNotGaugeException.selector);
        pqk.updateRates();

        vm.stopPrank();
    }

    /// @notice U:[QK-4]: creditManagerOnly funcitons revert if called by non registered creditManager
    function test_U_QK_04_creditManagerOnly_funcitons_reverts_if_called_by_non_creditManager() public {
        vm.startPrank(USER);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        pqk.updateQuota(DUMB_ADDRESS, address(1), 0, 0, 0);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        pqk.removeQuotas(DUMB_ADDRESS, new address[](1), false);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        pqk.accrueQuotaInterest(DUMB_ADDRESS, new address[](1));

        vm.stopPrank();
    }

    /// @notice U:[QK-5]: addQuotaToken adds token and set parameters correctly
    function test_U_QK_05_addQuotaToken_adds_token_and_set_parameters_correctly() public {
        address gauge = pqk.gauge();

        vm.prank(gauge);
        vm.expectRevert(TokenNotAllowedException.selector);
        pqk.addQuotaToken(underlying);

        address[] memory tokens = pqk.quotedTokens();

        assertEq(tokens.length, 0, "SETUP: tokens set unexpectedly has tokens");

        vm.expectEmit(true, true, false, false);
        emit IPoolQuotaKeeperV3.AddQuotaToken(DUMB_ADDRESS);

        vm.prank(gauge);
        pqk.addQuotaToken(DUMB_ADDRESS);

        tokens = pqk.quotedTokens();

        assertEq(tokens.length, 1, "token wasn't added to quotaTokenSet");
        assertEq(tokens[0], DUMB_ADDRESS, "Incorrect address was added to quotaTokenSet");
        assertEq(tokens.length, 1, "token wasn't added to quotaTokenSet");

        TokenQuotaParams memory tqp = pqk.tokenQuotaParams(DUMB_ADDRESS);

        assertEq(tqp.totalQuoted, 0, "totalQuoted !=0");
        assertEq(tqp.limit, 0, "limit !=0");
        assertEq(tqp.rate, 0, "rate !=0");
        assertEq(tqp.cumulativeIndexLU, 0, "Cumulative index !=1");

        vm.prank(gauge);
        vm.expectRevert(TokenAlreadyAddedException.selector);
        pqk.addQuotaToken(DUMB_ADDRESS);
    }

    /// @notice U:[QK-6]: updateRates works as expected
    function test_U_QK_06_updateRates_works_as_expected() public {
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
                    quotaChange: daiQuota,
                    minQuota: 0,
                    maxQuota: type(uint96).max
                });

                vm.prank(address(creditManagerMock));
                pqk.updateQuota({
                    creditAccount: DUMB_ADDRESS,
                    token: USDC,
                    quotaChange: usdcQuota,
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
            emit IPoolQuotaKeeperV3.UpdateTokenQuotaRate(DAI, DAI_QUOTA_RATE);

            vm.expectEmit(true, true, false, true);
            emit IPoolQuotaKeeperV3.UpdateTokenQuotaRate(USDC, USDC_QUOTA_RATE);

            uint256 expectedQuotaRevenue =
                (DAI_QUOTA_RATE * uint96(daiQuota) + USDC_QUOTA_RATE * uint96(usdcQuota)) / PERCENTAGE_FACTOR;

            vm.expectCall(address(poolMock), abi.encodeCall(IPoolV3.setQuotaRevenue, expectedQuotaRevenue));

            vm.prank(address(gaugeMock));
            pqk.updateRates();

            TokenQuotaParams memory tqp = pqk.tokenQuotaParams(DAI);

            assertEq(tqp.rate, DAI_QUOTA_RATE, _testCaseErr("Incorrect DAI rate"));
            assertEq(
                tqp.cumulativeIndexLU,
                RAY * DAI_QUOTA_RATE / PERCENTAGE_FACTOR,
                _testCaseErr("Incorrect DAI cumulativeIndexLU")
            );

            tqp = pqk.tokenQuotaParams(USDC);

            assertEq(tqp.rate, USDC_QUOTA_RATE, _testCaseErr("Incorrect USDC rate"));
            assertEq(
                tqp.cumulativeIndexLU,
                RAY * USDC_QUOTA_RATE / PERCENTAGE_FACTOR,
                _testCaseErr("Incorrect USDC cumulativeIndexLU")
            );

            assertEq(pqk.lastQuotaRateUpdate(), block.timestamp, _testCaseErr("Incorect lastQuotaRateUpdate timestamp"));

            assertEq(poolMock.quotaRevenue(), expectedQuotaRevenue, _testCaseErr("Incorect expectedQuotaRevenue"));
        }
    }

    /// @notice U:[QK-7]: setGauge works as expected
    function test_U_QK_07_setGauge_works_as_expected() public {
        pqk = new PoolQuotaKeeperV3(address(addressProvider), address(addressProvider), underlying, address(poolMock));

        assertEq(pqk.gauge(), address(0), "SETUP: incorrect address at start");

        gaugeMock = new GaugeMock(address(addressProvider), makeAddr("DUMMY"));
        vm.expectRevert(IncompatibleGaugeException.selector);
        pqk.setGauge(address(gaugeMock));

        gaugeMock = new GaugeMock(address(addressProvider), address(pqk));

        vm.expectEmit(true, true, false, false);
        emit IPoolQuotaKeeperV3.SetGauge(address(gaugeMock));

        pqk.setGauge(address(gaugeMock));
        assertEq(pqk.gauge(), address(gaugeMock), "gauge address wasnt updated");

        vm.prank(address(gaugeMock));
        pqk.addQuotaToken(makeAddr("TOKEN"));

        vm.expectRevert(TokenIsNotQuotedException.selector);
        pqk.setGauge(address(gaugeMock));
    }

    /// @notice U:[QK-8]: addCreditManager works as expected
    function test_U_QK_08_addCreditManager_works_as_expected() public {
        pqk = new PoolQuotaKeeperV3(address(addressProvider), address(addressProvider), underlying, address(poolMock));

        address[] memory managers = pqk.creditManagers();
        assertEq(managers.length, 0, "SETUP: at least one creditmanager is unexpectedly connected");

        // Case: non registered credit manager
        vm.expectRevert(RegisteredCreditManagerOnlyException.selector);
        pqk.addCreditManager(DUMB_ADDRESS);

        vm.expectEmit(true, true, false, false);
        emit IPoolQuotaKeeperV3.AddCreditManager(address(creditManagerMock));

        pqk.addCreditManager(address(creditManagerMock));

        managers = pqk.creditManagers();
        assertEq(managers.length, 1, "Incorrect length of connected managers");
        assertEq(managers[0], address(creditManagerMock), "Incorrect address was added to creditManagerSet");

        // check that funciton works correctly for another one step
        pqk.addCreditManager(address(creditManagerMock));

        managers = pqk.creditManagers();
        assertEq(managers.length, 1, "Incorrect length of connected managers");
        assertEq(managers[0], address(creditManagerMock), "Incorrect address was added to creditManagerSet");

        // Case: credit manager with different poolMock address
        creditManagerMock.setPoolService(DUMB_ADDRESS);
        vm.expectRevert(IncompatibleCreditManagerException.selector);
        pqk.addCreditManager(address(creditManagerMock));
    }

    /// @notice U:[QK-9]: setTokenLimit works as expected
    function test_U_QK_09_setTokenLimit_works_as_expected() public {
        vm.expectRevert(IncorrectParameterException.selector);
        pqk.setTokenLimit(DUMB_ADDRESS, type(uint96).max);

        vm.expectRevert(TokenIsNotQuotedException.selector);
        pqk.setTokenLimit(DUMB_ADDRESS, 1);

        uint96 limit = 435_223_999;

        gaugeMock.addQuotaToken(DUMB_ADDRESS, 11);

        vm.expectEmit(true, true, false, true);
        emit IPoolQuotaKeeperV3.SetTokenLimit(DUMB_ADDRESS, limit);

        pqk.setTokenLimit(DUMB_ADDRESS, limit);

        TokenQuotaParams memory tqp = pqk.tokenQuotaParams(DUMB_ADDRESS);

        assertEq(tqp.limit, limit, "Incorrect limit was set");
        assertEq(tqp.rate, 0, "Rate is incorrectly non-zero");

        vm.warp(block.timestamp + 7 days);
        gaugeMock.updateEpoch();

        tqp = pqk.tokenQuotaParams(DUMB_ADDRESS);

        assertEq(tqp.limit, limit, "Incorrect limit was set");
        assertNotEq(tqp.rate, 0, "Rate is incorrectly zero");
    }

    /// @notice U:[QK-10]: setTokenQuotaIncreaseFee works as expected
    function test_U_QK_10_setTokenQuotaIncreaseFee_works_as_expected() public {
        uint16 fee = 39_99;

        gaugeMock.addQuotaToken(DUMB_ADDRESS, 11);

        vm.expectEmit(true, true, false, true);
        emit IPoolQuotaKeeperV3.SetQuotaIncreaseFee(DUMB_ADDRESS, fee);

        pqk.setTokenQuotaIncreaseFee(DUMB_ADDRESS, fee);

        TokenQuotaParams memory tqp = pqk.tokenQuotaParams(DUMB_ADDRESS);

        assertEq(tqp.quotaIncreaseFee, fee, "Incorrect fee was set");
    }

    /// @notice U:[QK-11]: updateQuota reverts for unregistered token
    function test_U_QK_11_updateQuotas_reverts_for_unregistered_token() public {
        pqk.addCreditManager(address(creditManagerMock));
        address link = tokenTestSuite.addressOf(Tokens.LINK);

        vm.expectRevert(TokenIsNotQuotedException.selector);
        vm.prank(address(creditManagerMock));
        pqk.updateQuota({
            creditAccount: DUMB_ADDRESS,
            token: link,
            quotaChange: -int96(uint96(100 * WAD)),
            minQuota: 0,
            maxQuota: 1
        });

        vm.prank(address(gaugeMock));
        pqk.addQuotaToken(link);

        vm.expectRevert(TokenIsNotQuotedException.selector);
        vm.prank(address(creditManagerMock));
        pqk.updateQuota({
            creditAccount: DUMB_ADDRESS,
            token: link,
            quotaChange: -int96(uint96(100 * WAD)),
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

    /// @notice U:[QK-12]: updateQuotas works as expected
    function test_U_QK_12_updateQuotas_works_as_expected() public {
        UpdateQuotaTestCase[6] memory cases = [
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
                emit IPoolQuotaKeeperV3.UpdateQuota(creditAccount, token, _case.expectedRealQuotaChange);
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

    /// @notice U:[QK-13]: removeQuotas works correctly
    function test_U_QK_13_removeQuotas_works_correctly() public {
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
                quotaChange: int96(cases[i].token1Quota),
                minQuota: 0,
                maxQuota: type(uint96).max
            });

            vm.prank(address(creditManagerMock));
            pqk.updateQuota({
                creditAccount: creditAccount,
                token: token2,
                quotaChange: int96(cases[i].token2Quota),
                minQuota: 0,
                maxQuota: type(uint96).max
            });

            vm.prank(address(creditManagerMock));
            pqk.updateQuota({
                creditAccount: DUMB_ADDRESS,
                token: token1,
                quotaChange: int96(cases[i].token1TotalQuoted - cases[i].token1Quota),
                minQuota: 0,
                maxQuota: type(uint96).max
            });

            vm.prank(address(creditManagerMock));
            pqk.updateQuota({
                creditAccount: DUMB_ADDRESS,
                token: token2,
                quotaChange: int96(cases[i].token2TotalQuoted - cases[i].token2Quota),
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
                emit IPoolQuotaKeeperV3.UpdateQuota(creditAccount, token1, -int96(cases[i].token1Quota));
            }

            if (cases[i].token2Quota != 0) {
                vm.expectEmit(true, true, false, false);
                emit IPoolQuotaKeeperV3.UpdateQuota(creditAccount, token2, -int96(cases[i].token1Quota));
            }

            vm.prank(address(creditManagerMock));
            pqk.removeQuotas(creditAccount, tokens, cases[i].setLimitsToZero);

            {
                (uint96 quota1,) = pqk.getQuotaAndOutstandingInterest(creditAccount, token1);
                (uint96 quota2,) = pqk.getQuotaAndOutstandingInterest(creditAccount, token2);

                assertEq(quota1, 0, "Quota 1 was not removed");

                assertEq(quota2, 0, "Quota 2 was not removed");
            }

            TokenQuotaParams memory tqp1 = pqk.tokenQuotaParams(token1);
            TokenQuotaParams memory tqp2 = pqk.tokenQuotaParams(token2);

            assertEq(
                tqp1.totalQuoted, cases[i].token1TotalQuoted - cases[i].token1Quota, "Incorrect new total quoted 1"
            );

            assertEq(
                tqp2.totalQuoted, cases[i].token2TotalQuoted - cases[i].token2Quota, "Incorrect new total quoted 2"
            );

            if (cases[i].setLimitsToZero) {
                assertEq(tqp1.limit, 0, "Limit 1 was not set to zero");

                assertEq(tqp2.limit, 0, "Limit 2 was not set to zero");
            }

            vm.revertTo(snapshot);
        }
    }

    /// @notice U:[QK-14]: accrueQuotaInterest works correctly
    function test_U_QK_14_accrueQuotaInterest_works_correctly() external {
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
            quotaChange: int96(uint96(WAD)),
            minQuota: 0,
            maxQuota: type(uint96).max
        });

        vm.prank(address(creditManagerMock));
        pqk.updateQuota({
            creditAccount: creditAccount,
            token: token2,
            quotaChange: int96(uint96(WAD)),
            minQuota: 0,
            maxQuota: type(uint96).max
        });

        uint256 timestampLU = block.timestamp;
        vm.warp(block.timestamp + 365 days);

        uint192 expectedIndex1 = QuotasLogic.cumulativeIndexSince(0, 1000, timestampLU);
        // uint192 expectedIndex2 = QuotasLogic.cumulativeIndexSince(uint192(RAY), 2000, timestampLU);

        vm.prank(address(creditManagerMock));
        pqk.accrueQuotaInterest(creditAccount, tokens);

        assertEq(pqk.accountQuotas(creditAccount, token1).cumulativeIndexLU, expectedIndex1, "Incorrect token 1 index");

        // assertEq(pqk.accountQuotas(creditAccount, token2).cumulativeIndexLU, expectedIndex2, "Incorrect token 2 index");
    }
}
