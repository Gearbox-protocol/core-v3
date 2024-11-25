// // SPDX-License-Identifier: UNLICENSED
// // Gearbox Protocol. Generalized leverage for DeFi protocols
// // (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CollateralLogic} from "../../../libraries/CollateralLogic.sol";
import {CollateralDebtData} from "../../../interfaces/ICreditManagerV3.sol";
import {TestHelper} from "../../lib/helper.sol";

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

import "../../lib/constants.sol";
import "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import {CollateralLogicHelper, PRICE_ORACLE, B, Q} from "./CollateralLogicHelper.sol";

/// @title CollateralLogic unit test
contract CollateralLogicUnitTest is TestHelper, CollateralLogicHelper {
    ///
    ///  TESTS
    ///

    modifier withTokenSetup() {
        _tokenSetup();
        _;
    }

    function _tokenSetup() internal {
        setTokenParams({t: TOKEN_DAI, lt: 80_00, price: 1});
        setTokenParams({t: TOKEN_USDC, lt: 60_00, price: 2});
        setTokenParams({t: TOKEN_WETH, lt: 90_00, price: 1_818});
        setTokenParams({t: TOKEN_LINK, lt: 30_00, price: 15});
        setTokenParams({t: TOKEN_USDT, lt: 50_00, price: 1});
        setTokenParams({t: TOKEN_STETH, lt: 40_00, price: 1_500});
        setTokenParams({t: TOKEN_CRV, lt: 55_00, price: 10});
    }

    struct CalcOneTokenCollateralTestCase {
        string name;
        uint256 balance;
        uint256 price;
        uint16 liquidationThreshold;
        uint256 quotaUSD;
        //
        uint256 expectedValueUSD;
        uint256 expectedWeightedValueUSD;
        bool expectedNonZeroBalance;
        bool priceOracleCalled;
    }

    /// @dev U:[CLL-1]: calcOneTokenCollateral works correctly
    function test_U_CLL_01_calcOneTokenCollateral_works_correctly() public {
        CalcOneTokenCollateralTestCase[4] memory cases = [
            CalcOneTokenCollateralTestCase({
                name: "Do nothing if balance == 0",
                balance: 0,
                price: 0,
                liquidationThreshold: 80_00,
                quotaUSD: 0,
                //
                expectedValueUSD: 0,
                expectedWeightedValueUSD: 0,
                expectedNonZeroBalance: false,
                priceOracleCalled: false
            }),
            CalcOneTokenCollateralTestCase({
                name: "Do nothing if balance == 1",
                balance: 0,
                price: 0,
                liquidationThreshold: 80_00,
                quotaUSD: 0,
                //
                expectedValueUSD: 0,
                expectedWeightedValueUSD: 0,
                expectedNonZeroBalance: false,
                priceOracleCalled: false
            }),
            CalcOneTokenCollateralTestCase({
                name: "Non quoted case,  valueUSD < quotaUSD",
                balance: 5000,
                price: 2,
                liquidationThreshold: 80_00,
                quotaUSD: 10_001,
                //
                expectedValueUSD: (5_000 - 1) * 2,
                expectedWeightedValueUSD: (5_000 - 1) * 2 * 80_00 / PERCENTAGE_FACTOR,
                expectedNonZeroBalance: true,
                priceOracleCalled: true
            }),
            CalcOneTokenCollateralTestCase({
                name: "Non quoted case, valueUSD > quotaUSD",
                balance: 5000,
                price: 2,
                liquidationThreshold: 80_00,
                quotaUSD: 40_00,
                //
                expectedValueUSD: (5_000 - 1) * 2,
                expectedWeightedValueUSD: 40_00,
                expectedNonZeroBalance: true,
                priceOracleCalled: true
            })
        ];

        address creditAccount = makeAddr("creditAccount");
        address token = makeAddr("token");
        for (uint256 i; i < cases.length; ++i) {
            uint256 snapshot = vm.snapshot();

            CalcOneTokenCollateralTestCase memory _case = cases[i];
            caseName = _case.name;

            if (!_case.priceOracleCalled) {
                revertIsPriceOracleCalled[token] = true;
            }

            _prices[token] = _case.price;

            vm.mockCall(token, abi.encodeCall(IERC20.balanceOf, (creditAccount)), abi.encode(_case.balance));
            (uint256 valueUSD, uint256 weightedValueUSD, bool nonZeroBalance) = CollateralLogic.calcOneTokenCollateral({
                creditAccount: creditAccount,
                convertToUSDFn: _convertToUSD,
                priceOracle: PRICE_ORACLE,
                token: token,
                liquidationThreshold: _case.liquidationThreshold,
                quotaUSD: _case.quotaUSD
            });

            assertEq(valueUSD, _case.expectedValueUSD, _testCaseErr("Incorrect valueUSD"));
            assertEq(weightedValueUSD, _case.expectedWeightedValueUSD, _testCaseErr("Incorrect weightedValueUSD"));
            assertEq(nonZeroBalance, _case.expectedNonZeroBalance, _testCaseErr("Incorrect nonZeroBalance"));

            vm.revertTo(snapshot);
        }
    }

    struct CalcOneNonQuotedTokenCollateralTestCase {
        string name;
        uint256 balance;
        uint256 price;
        uint16 liquidationThreshold;
        //
        uint256 expectedValueUSD;
        uint256 expectedWeightedValueUSD;
        bool expectedNonZeroBalance;
        bool priceOracleCalled;
    }

    /// @dev U:[CLL-2]: ccalcOneNonQuotedCollateral works correctly
    function test_U_CLL_02_calcOneNonQuotedCollateral_works_correctly() public {
        CalcOneNonQuotedTokenCollateralTestCase[3] memory cases = [
            CalcOneNonQuotedTokenCollateralTestCase({
                name: "Do nothing if balance == 0",
                balance: 0,
                price: 0,
                liquidationThreshold: 80_00,
                //
                expectedValueUSD: 0,
                expectedWeightedValueUSD: 0,
                expectedNonZeroBalance: false,
                priceOracleCalled: false
            }),
            CalcOneNonQuotedTokenCollateralTestCase({
                name: "Do nothing if balance == 1",
                balance: 0,
                price: 0,
                liquidationThreshold: 80_00,
                //
                expectedValueUSD: 0,
                expectedWeightedValueUSD: 0,
                expectedNonZeroBalance: false,
                priceOracleCalled: false
            }),
            CalcOneNonQuotedTokenCollateralTestCase({
                name: "balance > 1",
                balance: 5000,
                price: 2,
                liquidationThreshold: 80_00,
                //
                expectedValueUSD: (5_000 - 1) * 2,
                expectedWeightedValueUSD: (5_000 - 1) * 2 * 80_00 / PERCENTAGE_FACTOR,
                expectedNonZeroBalance: true,
                priceOracleCalled: true
            })
        ];

        address creditAccount = makeAddr("creditAccount");

        for (uint256 i; i < cases.length; ++i) {
            uint256 snapshot = vm.snapshot();

            CalcOneNonQuotedTokenCollateralTestCase memory _case = cases[i];
            caseName = _case.name;

            address token = addressOf[TOKEN_DAI];

            setTokenParams({t: TOKEN_DAI, lt: _case.liquidationThreshold, price: _case.price});

            setBalances(arrayOf(B({t: TOKEN_DAI, balance: _case.balance})));

            if (!_case.priceOracleCalled) {
                revertIsPriceOracleCalled[token] = true;
            }

            startSession();

            (uint256 valueUSD, uint256 weightedValueUSD, bool nonZeroBalance) = CollateralLogic
                .calcOneNonQuotedCollateral({
                creditAccount: creditAccount,
                convertToUSDFn: _convertToUSD,
                collateralTokenByMaskFn: _collateralTokenByMask,
                tokenMask: tokenMask[TOKEN_DAI],
                priceOracle: PRICE_ORACLE
            });

            expectTokensOrder({tokens: arrayOfTokens(TOKEN_DAI), debug: false});

            assertEq(valueUSD, _case.expectedValueUSD, _testCaseErr("Incorrect valueUSD"));
            assertEq(weightedValueUSD, _case.expectedWeightedValueUSD, _testCaseErr("Incorrect weightedValueUSD"));
            assertEq(nonZeroBalance, _case.expectedNonZeroBalance, _testCaseErr("Incorrect nonZeroBalance"));

            vm.revertTo(snapshot);
        }
    }

    struct CalcNonQuotedTokenCollateralTestCase {
        string name;
        B[] balances;
        uint256 target;
        uint256[] collateralHints;
        uint256 tokensToCheckMask;
        // expected
        uint256 expectedTotalValueUSD;
        uint256 expectedTwvUSD;
        uint256 expectedTokensToDisable;
        uint256[] expectedOrder;
    }

    /// @dev U:[CLL-3]: ccalcOneNonQuotedCollateral works correctly
    function test_U_CLL_03_calcOneNonQuotedCollateral_works_correctly() public withTokenSetup {
        CalcNonQuotedTokenCollateralTestCase[7] memory cases = [
            CalcNonQuotedTokenCollateralTestCase({
                name: "One token calc, no target, no hints",
                balances: arrayOf(B({t: TOKEN_DAI, balance: 10_000})),
                target: type(uint256).max,
                collateralHints: new uint256[](0),
                tokensToCheckMask: getTokenMask(arrayOfTokens(TOKEN_DAI)),
                expectedTotalValueUSD: (10_000 - 1) * prices[TOKEN_DAI],
                expectedTwvUSD: (10_000 - 1) * prices[TOKEN_DAI] * lts[TOKEN_DAI] / PERCENTAGE_FACTOR,
                expectedTokensToDisable: 0,
                expectedOrder: arrayOfTokens(TOKEN_DAI)
            }),
            CalcNonQuotedTokenCollateralTestCase({
                name: "Two tokens calc, no target, no hints",
                balances: arrayOf(B({t: TOKEN_DAI, balance: 10_000}), B({t: TOKEN_STETH, balance: 100})),
                target: type(uint256).max,
                collateralHints: new uint256[](0),
                tokensToCheckMask: getTokenMask(arrayOfTokens(TOKEN_DAI, TOKEN_STETH)),
                expectedTotalValueUSD: (10_000 - 1) * prices[TOKEN_DAI] + (100 - 1) * prices[TOKEN_STETH],
                expectedTwvUSD: (10_000 - 1) * prices[TOKEN_DAI] * lts[TOKEN_DAI] / PERCENTAGE_FACTOR
                    + (100 - 1) * prices[TOKEN_STETH] * lts[TOKEN_STETH] / PERCENTAGE_FACTOR,
                expectedTokensToDisable: 0,
                expectedOrder: arrayOfTokens(TOKEN_DAI, TOKEN_STETH)
            }),
            CalcNonQuotedTokenCollateralTestCase({
                name: "Disable tokens with 0 or 1 balance",
                balances: arrayOf(B({t: TOKEN_DAI, balance: 10_000}), B({t: TOKEN_STETH, balance: 1})),
                target: type(uint256).max,
                collateralHints: new uint256[](0),
                tokensToCheckMask: getTokenMask(arrayOfTokens(TOKEN_DAI, TOKEN_STETH, TOKEN_LINK)),
                expectedTotalValueUSD: (10_000 - 1) * prices[TOKEN_DAI],
                expectedTwvUSD: (10_000 - 1) * prices[TOKEN_DAI] * lts[TOKEN_DAI] / PERCENTAGE_FACTOR,
                expectedTokensToDisable: getTokenMask(arrayOfTokens(TOKEN_STETH, TOKEN_LINK)),
                expectedOrder: arrayOfTokens(TOKEN_DAI, TOKEN_LINK, TOKEN_STETH)
            }),
            CalcNonQuotedTokenCollateralTestCase({
                name: "Stops on target",
                balances: arrayOf(B({t: TOKEN_DAI, balance: 10_000}), B({t: TOKEN_STETH, balance: 100_000})),
                target: (10_000 - 1) * prices[TOKEN_DAI] * lts[TOKEN_DAI] / PERCENTAGE_FACTOR,
                collateralHints: new uint256[](0),
                tokensToCheckMask: getTokenMask(arrayOfTokens(TOKEN_DAI, TOKEN_STETH, TOKEN_LINK)),
                expectedTotalValueUSD: (10_000 - 1) * prices[TOKEN_DAI],
                expectedTwvUSD: (10_000 - 1) * prices[TOKEN_DAI] * lts[TOKEN_DAI] / PERCENTAGE_FACTOR,
                expectedTokensToDisable: 0,
                expectedOrder: arrayOfTokens(TOKEN_DAI)
            }),
            CalcNonQuotedTokenCollateralTestCase({
                name: "Call tokens by collateral hints order",
                balances: arrayOf(B({t: TOKEN_DAI, balance: 10_000}), B({t: TOKEN_STETH, balance: 300})),
                target: type(uint256).max,
                collateralHints: getHints(arrayOfTokens(TOKEN_LINK, TOKEN_DAI, TOKEN_STETH)),
                tokensToCheckMask: getTokenMask(arrayOfTokens(TOKEN_DAI, TOKEN_STETH, TOKEN_LINK)),
                expectedTotalValueUSD: (10_000 - 1) * prices[TOKEN_DAI] + (300 - 1) * prices[TOKEN_STETH],
                expectedTwvUSD: (10_000 - 1) * prices[TOKEN_DAI] * lts[TOKEN_DAI] / PERCENTAGE_FACTOR
                    + (300 - 1) * prices[TOKEN_STETH] * lts[TOKEN_STETH] / PERCENTAGE_FACTOR,
                expectedTokensToDisable: getTokenMask(arrayOfTokens(TOKEN_LINK)),
                expectedOrder: arrayOfTokens(TOKEN_LINK, TOKEN_DAI, TOKEN_STETH)
            }),
            CalcNonQuotedTokenCollateralTestCase({
                name: "Call tokens by normal order after collateral hints order",
                balances: arrayOf(B({t: TOKEN_DAI, balance: 10_000}), B({t: TOKEN_STETH, balance: 300})),
                target: type(uint256).max,
                collateralHints: getHints(arrayOfTokens(TOKEN_LINK, TOKEN_STETH)),
                tokensToCheckMask: getTokenMask(arrayOfTokens(TOKEN_DAI, TOKEN_STETH, TOKEN_LINK)),
                expectedTotalValueUSD: (10_000 - 1) * prices[TOKEN_DAI] + (300 - 1) * prices[TOKEN_STETH],
                expectedTwvUSD: (10_000 - 1) * prices[TOKEN_DAI] * lts[TOKEN_DAI] / PERCENTAGE_FACTOR
                    + (300 - 1) * prices[TOKEN_STETH] * lts[TOKEN_STETH] / PERCENTAGE_FACTOR,
                expectedTokensToDisable: getTokenMask(arrayOfTokens(TOKEN_LINK)),
                expectedOrder: arrayOfTokens(TOKEN_LINK, TOKEN_STETH, TOKEN_DAI)
            }),
            CalcNonQuotedTokenCollateralTestCase({
                name: "Do not double count tokens if it's mask added twice to collatreral hints",
                balances: arrayOf(B({t: TOKEN_DAI, balance: 10_000})),
                target: type(uint256).max,
                collateralHints: getHints(arrayOfTokens(TOKEN_DAI, TOKEN_DAI)),
                tokensToCheckMask: getTokenMask(arrayOfTokens(TOKEN_DAI)),
                expectedTotalValueUSD: (10_000 - 1) * prices[TOKEN_DAI],
                expectedTwvUSD: (10_000 - 1) * prices[TOKEN_DAI] * lts[TOKEN_DAI] / PERCENTAGE_FACTOR,
                expectedTokensToDisable: 0,
                expectedOrder: arrayOfTokens(TOKEN_DAI)
            })
        ];

        address creditAccount = makeAddr("creditAccount");

        for (uint256 i; i < cases.length; ++i) {
            uint256 snapshot = vm.snapshot();

            CalcNonQuotedTokenCollateralTestCase memory _case = cases[i];
            caseName = _case.name;

            setBalances(_case.balances);

            startSession();

            (uint256 totalValueUSD, uint256 twvUSD, uint256 tokensToDisable) = CollateralLogic
                .calcNonQuotedTokensCollateral({
                creditAccount: creditAccount,
                twvUSDTarget: _case.target,
                collateralHints: _case.collateralHints,
                convertToUSDFn: _convertToUSD,
                collateralTokenByMaskFn: _collateralTokenByMask,
                tokensToCheckMask: _case.tokensToCheckMask,
                priceOracle: PRICE_ORACLE
            });

            expectTokensOrder({tokens: _case.expectedOrder, debug: true});

            assertEq(totalValueUSD, _case.expectedTotalValueUSD, _testCaseErr("Incorrect totalValueUSD"));
            assertEq(twvUSD, _case.expectedTwvUSD, _testCaseErr("Incorrect weightedValueUSD"));
            assertEq(tokensToDisable, _case.expectedTokensToDisable, _testCaseErr("Incorrect nonZeroBalance"));

            vm.revertTo(snapshot);
        }
    }

    struct CalcQuotedTokenCollateralTestCase {
        string name;
        B[] balances;
        Q[] quotas;
        uint256 target;
        // expected
        uint256 expectedTotalValueUSD;
        uint256 expectedTwvUSD;
        uint256[] expectedOrder;
    }

    /// @dev U:[CLL-4]: calcQuotedTokensCollateral works correctly
    function test_U_CLL_04_calcQuotedTokensCollateral_works_correctly() public withTokenSetup {
        CalcQuotedTokenCollateralTestCase[4] memory cases = [
            CalcQuotedTokenCollateralTestCase({
                name: "One token calc, no target, twv < quota",
                balances: arrayOf(B({t: TOKEN_USDT, balance: 10_000})),
                quotas: arrayOf(Q({t: TOKEN_USDT, quota: 10_000})),
                target: type(uint256).max,
                expectedTotalValueUSD: (10_000 - 1) * prices[TOKEN_USDT],
                expectedTwvUSD: (10_000 - 1) * prices[TOKEN_USDT] * lts[TOKEN_USDT] / PERCENTAGE_FACTOR,
                expectedOrder: arrayOfTokens(TOKEN_USDT)
            }),
            CalcQuotedTokenCollateralTestCase({
                name: "One token calc, no target, twv > quota",
                balances: arrayOf(B({t: TOKEN_USDT, balance: 10_000})),
                quotas: arrayOf(Q({t: TOKEN_USDT, quota: 5_000})),
                target: type(uint256).max,
                expectedTotalValueUSD: (10_000 - 1) * prices[TOKEN_USDT],
                expectedTwvUSD: (5_000 - 1) * prices[TOKEN_DAI],
                expectedOrder: arrayOfTokens(TOKEN_USDT)
            }),
            CalcQuotedTokenCollateralTestCase({
                name: "Two token calc, no target, one twv<quota, another twv > quota",
                balances: arrayOf(B({t: TOKEN_USDT, balance: 70_000}), B({t: TOKEN_LINK, balance: 1_000})),
                quotas: arrayOf(Q({t: TOKEN_USDT, quota: 5_000}), Q({t: TOKEN_LINK, quota: 20_000})),
                target: type(uint256).max,
                expectedTotalValueUSD: (70_000 - 1) * prices[TOKEN_USDT] + (1_000 - 1) * prices[TOKEN_LINK],
                expectedTwvUSD: 5_000 * prices[TOKEN_DAI]
                    + (1_000 - 1) * prices[TOKEN_LINK] * lts[TOKEN_LINK] / PERCENTAGE_FACTOR,
                expectedOrder: arrayOfTokens(TOKEN_USDT, TOKEN_LINK)
            }),
            CalcQuotedTokenCollateralTestCase({
                name: "Stops when target reached",
                balances: arrayOf(B({t: TOKEN_USDT, balance: 20_000})),
                quotas: arrayOf(
                    Q({t: TOKEN_USDT, quota: 5_000}), Q({t: TOKEN_WETH, quota: 50}), Q({t: TOKEN_LINK, quota: 50_000})
                ),
                target: 5_000 * prices[TOKEN_DAI],
                expectedTotalValueUSD: (20_000 - 1) * prices[TOKEN_USDT],
                expectedTwvUSD: 5_000 * prices[TOKEN_DAI],
                expectedOrder: arrayOfTokens(TOKEN_USDT)
            })
        ];

        address creditAccount = makeAddr("creditAccount");

        for (uint256 i; i < cases.length; ++i) {
            uint256 snapshot = vm.snapshot();

            CalcQuotedTokenCollateralTestCase memory _case = cases[i];
            caseName = _case.name;

            setBalances(_case.balances);

            uint256 underlyingPriceRAY = RAY * prices[TOKEN_DAI];

            (address[] memory quotedTokens, uint256[] memory quotasPacked) = getQuotas(_case.quotas);

            startSession();

            (uint256 totalValueUSD, uint256 twvUSD) = CollateralLogic.calcQuotedTokensCollateral({
                quotedTokens: quotedTokens,
                quotasPacked: quotasPacked,
                creditAccount: creditAccount,
                underlyingPriceRAY: underlyingPriceRAY,
                twvUSDTarget: _case.target,
                convertToUSDFn: _convertToUSD,
                priceOracle: PRICE_ORACLE
            });

            expectTokensOrder({tokens: _case.expectedOrder, debug: false});

            assertEq(totalValueUSD, _case.expectedTotalValueUSD, _testCaseErr("Incorrect totalValueUSD"));
            assertEq(twvUSD, _case.expectedTwvUSD, _testCaseErr("Incorrect twvUSD"));

            vm.revertTo(snapshot);
        }
    }

    //
    //
    // CALC COLLATERAL
    //
    //
    struct CalcCollateralTestCase {
        string name;
        B[] balances;
        Q[] quotas;
        uint256 enabledTokensMask;
        uint256 quotedTokensMask;
        bool lazy;
        uint16 minHealthFactor;
        uint256[] collateralHints;
        uint256 totalDebtUSD;
        // expected
        uint256 expectedTotalValueUSD;
        uint256 expectedTwvUSD;
        uint256 expectedTokensToDisable;
        uint256[] expectedOrder;
    }

    /// @dev U:[CLL-5]: calcCollateral works correctly
    function test_U_CLL_05_calcCollateral_works_correctly() public withTokenSetup {
        CalcCollateralTestCase[7] memory cases = [
            CalcCollateralTestCase({
                name: "One non-quoted token calc, no target, no hints",
                balances: arrayOf(B({t: TOKEN_DAI, balance: 10_000})),
                quotas: new Q[](0),
                enabledTokensMask: getTokenMask(arrayOfTokens(TOKEN_DAI)),
                quotedTokensMask: 0,
                lazy: false,
                minHealthFactor: PERCENTAGE_FACTOR,
                collateralHints: new uint256[](0),
                totalDebtUSD: 0,
                expectedTotalValueUSD: (10_000 - 1) * prices[TOKEN_DAI],
                expectedTwvUSD: (10_000 - 1) * prices[TOKEN_DAI] * lts[TOKEN_DAI] / PERCENTAGE_FACTOR,
                expectedTokensToDisable: 0,
                expectedOrder: arrayOfTokens(TOKEN_DAI)
            }),
            CalcCollateralTestCase({
                name: "One quoted token calc, no target, no hints, value < quota",
                balances: arrayOf(B({t: TOKEN_USDT, balance: 10_000})),
                quotas: arrayOf(Q({t: TOKEN_USDT, quota: 10_000})),
                enabledTokensMask: getTokenMask(arrayOfTokens(TOKEN_USDT)),
                quotedTokensMask: getTokenMask(arrayOfTokens(TOKEN_USDT)),
                lazy: false,
                minHealthFactor: PERCENTAGE_FACTOR,
                collateralHints: new uint256[](0),
                totalDebtUSD: 0,
                expectedTotalValueUSD: (10_000 - 1) * prices[TOKEN_USDT],
                expectedTwvUSD: (10_000 - 1) * prices[TOKEN_USDT] * lts[TOKEN_USDT] / PERCENTAGE_FACTOR,
                expectedTokensToDisable: 0,
                expectedOrder: arrayOfTokens(TOKEN_USDT)
            }),
            CalcCollateralTestCase({
                name: "One quoted token calc, no target, no hints, value > quota",
                balances: arrayOf(B({t: TOKEN_USDT, balance: 20_000})),
                quotas: arrayOf(Q({t: TOKEN_USDT, quota: 5_000})),
                enabledTokensMask: getTokenMask(arrayOfTokens(TOKEN_USDT)),
                quotedTokensMask: getTokenMask(arrayOfTokens(TOKEN_USDT)),
                lazy: false,
                minHealthFactor: PERCENTAGE_FACTOR,
                collateralHints: new uint256[](0),
                totalDebtUSD: 0,
                expectedTotalValueUSD: (20_000 - 1) * prices[TOKEN_USDT],
                expectedTwvUSD: 5_000 * prices[TOKEN_DAI],
                expectedTokensToDisable: 0,
                expectedOrder: arrayOfTokens(TOKEN_USDT)
            }),
            CalcCollateralTestCase({
                name: "It removes non-quoted tokens with 0 and 1 balances",
                balances: arrayOf(B({t: TOKEN_USDT, balance: 20_000}), B({t: TOKEN_LINK, balance: 1})),
                quotas: arrayOf(Q({t: TOKEN_USDT, quota: 5_000})),
                enabledTokensMask: getTokenMask(arrayOfTokens(TOKEN_USDT, TOKEN_LINK, TOKEN_DAI)),
                quotedTokensMask: getTokenMask(arrayOfTokens(TOKEN_USDT)),
                lazy: false,
                minHealthFactor: PERCENTAGE_FACTOR,
                collateralHints: new uint256[](0),
                totalDebtUSD: 0,
                expectedTotalValueUSD: (20_000 - 1) * prices[TOKEN_USDT],
                expectedTwvUSD: 5_000 * prices[TOKEN_DAI],
                expectedTokensToDisable: getTokenMask(arrayOfTokens(TOKEN_LINK, TOKEN_DAI)),
                expectedOrder: arrayOfTokens(TOKEN_USDT, TOKEN_DAI, TOKEN_LINK)
            }),
            CalcCollateralTestCase({
                name: "It stops if target reached during quoted token collateral computation",
                balances: arrayOf(B({t: TOKEN_USDT, balance: 20_000}), B({t: TOKEN_LINK, balance: 1})),
                quotas: arrayOf(Q({t: TOKEN_USDT, quota: 5_000}), Q({t: TOKEN_WETH, quota: 5_000})),
                enabledTokensMask: getTokenMask(arrayOfTokens(TOKEN_USDT, TOKEN_WETH, TOKEN_LINK, TOKEN_DAI)),
                quotedTokensMask: getTokenMask(arrayOfTokens(TOKEN_USDT, TOKEN_WETH)),
                lazy: true,
                minHealthFactor: 2 * PERCENTAGE_FACTOR,
                collateralHints: new uint256[](0),
                totalDebtUSD: 5_000 * prices[TOKEN_DAI] / 2,
                expectedTotalValueUSD: (20_000 - 1) * prices[TOKEN_USDT],
                expectedTwvUSD: 5_000 * prices[TOKEN_DAI],
                expectedTokensToDisable: 0,
                expectedOrder: arrayOfTokens(TOKEN_USDT)
            }),
            CalcCollateralTestCase({
                name: "It stops if target reached during non-quoted token collateral computation, and updates target properly after quoted calc",
                balances: arrayOf(B({t: TOKEN_USDT, balance: 20_000}), B({t: TOKEN_DAI, balance: 8_000})),
                quotas: arrayOf(Q({t: TOKEN_USDT, quota: 5_000}), Q({t: TOKEN_WETH, quota: 5_000})),
                enabledTokensMask: getTokenMask(arrayOfTokens(TOKEN_USDT, TOKEN_WETH, TOKEN_LINK, TOKEN_DAI)),
                quotedTokensMask: getTokenMask(arrayOfTokens(TOKEN_USDT, TOKEN_WETH)),
                lazy: true,
                minHealthFactor: PERCENTAGE_FACTOR,
                collateralHints: new uint256[](0),
                totalDebtUSD: 5_000 * prices[TOKEN_DAI] * lts[TOKEN_USDT] / PERCENTAGE_FACTOR
                    + (8_000 - 1) * prices[TOKEN_DAI] * lts[TOKEN_DAI] / PERCENTAGE_FACTOR,
                expectedTotalValueUSD: (20_000 - 1) * prices[TOKEN_USDT] + (8_000 - 1) * prices[TOKEN_DAI],
                expectedTwvUSD: 5_000 * prices[TOKEN_DAI] + (8_000 - 1) * prices[TOKEN_DAI] * lts[TOKEN_DAI] / PERCENTAGE_FACTOR,
                expectedTokensToDisable: 0,
                expectedOrder: arrayOfTokens(TOKEN_USDT, TOKEN_WETH, TOKEN_DAI)
            }),
            CalcCollateralTestCase({
                name: "Collateral hints work for non-quoted tokens",
                balances: arrayOf(B({t: TOKEN_USDT, balance: 20_000}), B({t: TOKEN_DAI, balance: 8_000})),
                quotas: arrayOf(Q({t: TOKEN_USDT, quota: 5_000})),
                enabledTokensMask: getTokenMask(arrayOfTokens(TOKEN_USDT, TOKEN_WETH, TOKEN_LINK, TOKEN_DAI)),
                quotedTokensMask: getTokenMask(arrayOfTokens(TOKEN_USDT)),
                lazy: false,
                minHealthFactor: PERCENTAGE_FACTOR,
                collateralHints: getHints(arrayOfTokens(TOKEN_WETH, TOKEN_LINK)),
                totalDebtUSD: 5_000 * prices[TOKEN_DAI] * lts[TOKEN_USDT] / PERCENTAGE_FACTOR
                    + (8_000 - 1) * prices[TOKEN_DAI] * lts[TOKEN_DAI] / PERCENTAGE_FACTOR,
                expectedTotalValueUSD: (20_000 - 1) * prices[TOKEN_USDT] + (8_000 - 1) * prices[TOKEN_DAI],
                expectedTwvUSD: 5_000 * prices[TOKEN_DAI] + (8_000 - 1) * prices[TOKEN_DAI] * lts[TOKEN_DAI] / PERCENTAGE_FACTOR,
                expectedTokensToDisable: getTokenMask(arrayOfTokens(TOKEN_WETH, TOKEN_LINK)),
                expectedOrder: arrayOfTokens(TOKEN_USDT, TOKEN_WETH, TOKEN_LINK, TOKEN_DAI)
            })
        ];

        address creditAccount = makeAddr("creditAccount");

        for (uint256 i; i < cases.length; ++i) {
            uint256 snapshot = vm.snapshot();

            CalcCollateralTestCase memory _case = cases[i];
            caseName = _case.name;

            setBalances(_case.balances);

            CollateralDebtData memory collateralDebtData;

            collateralDebtData.totalDebtUSD = _case.totalDebtUSD;
            collateralDebtData.enabledTokensMask = _case.enabledTokensMask;
            collateralDebtData.quotedTokensMask = _case.quotedTokensMask;

            uint256[] memory quotasPacked;
            (collateralDebtData.quotedTokens, quotasPacked) = getQuotas(_case.quotas);

            startSession();

            uint256 target = _case.lazy
                ? collateralDebtData.totalDebtUSD * _case.minHealthFactor / PERCENTAGE_FACTOR
                : type(uint256).max;

            (uint256 totalValueUSD, uint256 twvUSD, uint256 tokensToDisable) = CollateralLogic.calcCollateral({
                collateralDebtData: collateralDebtData,
                creditAccount: creditAccount,
                underlying: addressOf[TOKEN_DAI],
                quotasPacked: quotasPacked,
                twvUSDTarget: target,
                collateralHints: _case.collateralHints,
                convertToUSDFn: _convertToUSD,
                collateralTokenByMaskFn: _collateralTokenByMask,
                priceOracle: PRICE_ORACLE
            });

            expectTokensOrder({tokens: _case.expectedOrder, debug: false});

            assertEq(totalValueUSD, _case.expectedTotalValueUSD, _testCaseErr("Incorrect totalValueUSD"));
            assertEq(twvUSD, _case.expectedTwvUSD, _testCaseErr("Incorrect weightedValueUSD"));
            assertEq(tokensToDisable, _case.expectedTokensToDisable, _testCaseErr("Incorrect nonZeroBalance"));

            vm.revertTo(snapshot);
        }
    }
}
