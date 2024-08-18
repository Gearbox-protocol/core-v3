// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CollateralLogic} from "../../../libraries/CollateralLogic.sol";
import {TestHelper} from "../../lib/helper.sol";

import {PERCENTAGE_FACTOR} from "../../../libraries/Constants.sol";

import "../../lib/constants.sol";
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import {CollateralLogicHelper, PRICE_ORACLE, B, Q} from "./CollateralLogicHelper.sol";

/// @title CollateralLogic unit test
contract CollateralLogicUnitTest is TestHelper, CollateralLogicHelper {
    ///
    ///  TESTS
    ///

    modifier withTokenSetup() {
        setTokenParams({t: Tokens.DAI, lt: 95_00, price: 1});
        setTokenParams({t: Tokens.USDT, lt: 90_00, price: 1});
        setTokenParams({t: Tokens.LINK, lt: 75_00, price: 15});
        _;
    }

    struct CalcOneTokenCollateralTestCase {
        // scenario
        string name;
        uint256 balance;
        uint256 price;
        uint16 liquidationThreshold;
        uint256 quotaUSD;
        // expected behavior
        uint256 expectedValueUSD;
        uint256 expectedWeightedValueUSD;
        bool priceOracleCalled;
    }

    /// @dev U:[CLL-1]: calcOneTokenCollateral works correctly
    function test_U_CLL_01_calcOneTokenCollateral_works_correctly() public {
        CalcOneTokenCollateralTestCase[3] memory cases = [
            CalcOneTokenCollateralTestCase({
                name: "Balance is zero",
                balance: 0,
                price: 0,
                liquidationThreshold: 80_00,
                quotaUSD: 0,
                expectedValueUSD: 0,
                expectedWeightedValueUSD: 0,
                priceOracleCalled: false
            }),
            CalcOneTokenCollateralTestCase({
                name: "Quota fully covers value",
                balance: 5000,
                price: 2,
                liquidationThreshold: 80_00,
                quotaUSD: 10_001,
                expectedValueUSD: 5_000 * 2,
                expectedWeightedValueUSD: 5_000 * 2 * 80_00 / PERCENTAGE_FACTOR,
                priceOracleCalled: true
            }),
            CalcOneTokenCollateralTestCase({
                name: "Quota partially covers value",
                balance: 5000,
                price: 2,
                liquidationThreshold: 80_00,
                quotaUSD: 40_00,
                expectedValueUSD: 5_000 * 2,
                expectedWeightedValueUSD: 40_00,
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
            (uint256 valueUSD, uint256 weightedValueUSD) = CollateralLogic.calcOneTokenCollateral({
                creditAccount: creditAccount,
                convertToUSDFn: _convertToUSD,
                priceOracle: PRICE_ORACLE,
                token: token,
                liquidationThreshold: _case.liquidationThreshold,
                quotaUSD: _case.quotaUSD
            });

            assertEq(valueUSD, _case.expectedValueUSD, _testCaseErr("Incorrect valueUSD"));
            assertEq(weightedValueUSD, _case.expectedWeightedValueUSD, _testCaseErr("Incorrect weightedValueUSD"));

            vm.revertTo(snapshot);
        }
    }

    struct CalcCollateralTestCase {
        // scenario
        string name;
        B[] balances;
        Q[] quotas;
        uint256 target;
        // expected behavior
        uint256 expectedTotalValueUSD;
        uint256 expectedTwvUSD;
        Tokens[] expectedOrder;
    }

    /// @dev U:[CLL-2]: calcCollateral works correctly
    function test_U_CLL_02_calcCollateral_works_correctly() public withTokenSetup {
        CalcCollateralTestCase[4] memory cases = [
            CalcCollateralTestCase({
                name: "No target, one quoted token and underlying",
                balances: arrayOf(B({t: Tokens.USDT, balance: 10_000}), B({t: Tokens.DAI, balance: 5_000})),
                quotas: arrayOf(Q({t: Tokens.USDT, quota: 10_000})),
                target: type(uint256).max,
                expectedTotalValueUSD: 10_000 * prices[Tokens.USDT] + 5_000 * prices[Tokens.DAI],
                expectedTwvUSD: 10_000 * prices[Tokens.USDT] * lts[Tokens.USDT] / PERCENTAGE_FACTOR
                    + 5_000 * prices[Tokens.DAI] * lts[Tokens.DAI] / PERCENTAGE_FACTOR,
                expectedOrder: arrayOf(Tokens.USDT, Tokens.DAI)
            }),
            CalcCollateralTestCase({
                name: "No target, two quoted tokens",
                balances: arrayOf(B({t: Tokens.USDT, balance: 10_000}), B({t: Tokens.LINK, balance: 1_000})),
                quotas: arrayOf(Q({t: Tokens.USDT, quota: 10_000}), Q({t: Tokens.LINK, quota: 20_000})),
                target: type(uint256).max,
                expectedTotalValueUSD: 10_000 * prices[Tokens.USDT] + 1_000 * prices[Tokens.LINK],
                expectedTwvUSD: 10_000 * prices[Tokens.USDT] * lts[Tokens.USDT] / PERCENTAGE_FACTOR
                    + 1_000 * prices[Tokens.LINK] * lts[Tokens.LINK] / PERCENTAGE_FACTOR,
                expectedOrder: arrayOf(Tokens.USDT, Tokens.LINK, Tokens.DAI)
            }),
            CalcCollateralTestCase({
                name: "Finite target, one quoted token and underlying",
                balances: arrayOf(B({t: Tokens.USDT, balance: 10_000}), B({t: Tokens.DAI, balance: 5_000})),
                quotas: arrayOf(Q({t: Tokens.USDT, quota: 10_000})),
                target: 8_000 * prices[Tokens.DAI],
                expectedTotalValueUSD: 10_000 * prices[Tokens.USDT],
                expectedTwvUSD: 10_000 * prices[Tokens.USDT] * lts[Tokens.USDT] / PERCENTAGE_FACTOR,
                expectedOrder: arrayOf(Tokens.USDT)
            }),
            CalcCollateralTestCase({
                name: "Finite target, two quoted tokens",
                balances: arrayOf(B({t: Tokens.USDT, balance: 10_000}), B({t: Tokens.LINK, balance: 1_000})),
                quotas: arrayOf(Q({t: Tokens.USDT, quota: 10_000}), Q({t: Tokens.LINK, quota: 20_000})),
                target: 8_000 * prices[Tokens.DAI],
                expectedTotalValueUSD: 10_000 * prices[Tokens.USDT],
                expectedTwvUSD: 10_000 * prices[Tokens.USDT] * lts[Tokens.USDT] / PERCENTAGE_FACTOR,
                expectedOrder: arrayOf(Tokens.USDT)
            })
        ];

        address creditAccount = makeAddr("creditAccount");

        for (uint256 i; i < cases.length; ++i) {
            uint256 snapshot = vm.snapshot();

            CalcCollateralTestCase memory _case = cases[i];
            caseName = _case.name;

            setBalances(_case.balances);
            (address[] memory quotedTokens, uint256[] memory quotasPacked) = getQuotas(_case.quotas);

            startSession();

            (uint256 totalValueUSD, uint256 twvUSD) = CollateralLogic.calcCollateral({
                quotedTokens: quotedTokens,
                quotasPacked: quotasPacked,
                creditAccount: creditAccount,
                underlying: addressOf[Tokens.DAI],
                ltUnderlying: lts[Tokens.DAI],
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
}
