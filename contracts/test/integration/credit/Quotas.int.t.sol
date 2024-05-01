// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../../../interfaces/ICreditFacadeV3Multicall.sol";

import {
    ICreditManagerV3,
    ICreditManagerV3Events,
    CollateralTokenData,
    ManageDebtAction,
    CollateralCalcTask,
    CollateralDebtData
} from "../../../interfaces/ICreditManagerV3.sol";
import {IPoolQuotaKeeperV3, AccountQuota} from "../../../interfaces/IPoolQuotaKeeperV3.sol";

import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {MultiCallBuilder} from "../../lib/MultiCallBuilder.sol";

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {CreditLogic} from "../../../libraries/CreditLogic.sol";

// TESTS
import "../../lib/constants.sol";

// MOCKS

// import {PoolMock} from "../../mocks//pool/PoolMock.sol";

// SUITES

import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

import {IntegrationTestHelper} from "../../helpers/IntegrationTestHelper.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

contract QuotasIntegrationTest is IntegrationTestHelper, ICreditManagerV3Events {
    using CreditLogic for CollateralDebtData;

    function _addQuotedToken(address token, uint16 rate, uint96 limit) internal {
        makeTokenQuoted(token, rate, limit);
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev I:[CMQ-2]: setQuotedMask works correctly
    function test_I_CMQ_02_setQuotedMask_works_correctly() public creditTest {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500, uint96(1_000_000 * WAD));

        uint256 usdtMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDT));
        uint256 linkMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));

        assertEq(creditManager.quotedTokensMask(), usdtMask | linkMask, "New limited mask is incorrect");
    }

    /// @dev I:[CMQ-3]: updateQuotas works correctly
    function test_I_CMQ_03_updateQuotas_works_correctly() public creditTest {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500, uint96(1_000_000 * WAD));

        (address creditAccount,) = _openTestCreditAccount();

        (,, uint128 cumulativeQuotaInterest,,,,,) = creditManager.creditAccountInfo(creditAccount);

        assertEq(cumulativeQuotaInterest, 1, "SETUP: Cumulative quota interest was not updated correctly");

        {
            address link = tokenTestSuite.addressOf(Tokens.LINK);
            vm.expectRevert(CallerNotCreditFacadeException.selector);
            vm.prank(FRIEND);
            creditManager.updateQuota({
                creditAccount: creditAccount,
                token: link,
                quotaChange: 100_000,
                minQuota: 0,
                maxQuota: type(uint96).max
            });
        }

        (, uint256 maxDebt) = creditFacade.debtLimits();
        uint96 maxQuota = uint96(creditFacade.maxQuotaMultiplier() * maxDebt);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota, (tokenTestSuite.addressOf(Tokens.LINK), 100_000, 0)
                    )
            })
        );

        vm.expectCall(
            address(poolQuotaKeeper),
            abi.encodeCall(
                IPoolQuotaKeeperV3.updateQuota,
                (creditAccount, tokenTestSuite.addressOf(Tokens.LINK), 100_000, 0, maxQuota)
            )
        );

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        expectTokenIsEnabled(creditAccount, tokenTestSuite.addressOf(Tokens.LINK), true, "Incorrect tokensToEnble");

        vm.warp(block.timestamp + 365 days);

        calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota, (tokenTestSuite.addressOf(Tokens.LINK), -100_000, 0)
                    )
            })
        );

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        expectTokenIsEnabled(creditAccount, tokenTestSuite.addressOf(Tokens.LINK), false, "Incorrect tokensToEnble");

        (,, cumulativeQuotaInterest,,,,,) = creditManager.creditAccountInfo(creditAccount);

        assertEq(
            cumulativeQuotaInterest,
            (100000 * 1000) / PERCENTAGE_FACTOR + 1,
            "Cumulative quota interest was not updated correctly"
        );

        address usdc = tokenTestSuite.addressOf(Tokens.USDC);

        calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (usdc, 100_000, 0))
            })
        );

        vm.expectRevert(TokenIsNotQuotedException.selector);
        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);
    }

    /// @dev I:[CMQ-4]: Quotas are handled correctly on debt decrease: amount < quota interest case
    function test_I_CMQ_04_quotas_are_handled_correctly_at_repayment_partial_case() public creditTest {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500, uint96(1_000_000 * WAD));

        (address creditAccount,) = _openTestCreditAccount();
        vm.roll(block.timestamp + 1);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota, (tokenTestSuite.addressOf(Tokens.LINK), 100_000, 0)
                    )
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota, (tokenTestSuite.addressOf(Tokens.USDT), 200_000, 0)
                    )
            })
        );

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        vm.warp(block.timestamp + 365 days);

        (uint16 feeInterest,,,,) = creditManager.fees();

        uint256 amountRepaid = 15000;

        uint256 expectedQuotaInterestRepaid = (amountRepaid * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest);

        CollateralDebtData memory cdd1 =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

        calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (amountRepaid))
            })
        );

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        // creditManager.manageDebt(creditAccount, amountRepaid, enabledTokensMask, ManageDebtAction.DECREASE_DEBT);

        CollateralDebtData memory cdd2 =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

        assertEq(
            cdd1.accruedInterest, cdd2.accruedInterest + expectedQuotaInterestRepaid, "Interest updated incorrectly"
        );

        assertEq(
            cdd1.accruedFees, cdd2.accruedFees + amountRepaid - expectedQuotaInterestRepaid, "Fees updated incorrectly"
        );
    }

    /// @dev I:[CMQ-5]: Quotas are handled correctly on debt decrease: amount >= quota interest case
    function test_I_CMQ_05_quotas_are_handled_correctly_at_repayment_full_case() public creditTest {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 1000, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500, uint96(1_000_000 * WAD));

        (address creditAccount,) = _openTestCreditAccount();
        vm.roll(block.timestamp + 1);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota, (tokenTestSuite.addressOf(Tokens.LINK), 100_000, 0)
                    )
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota, (tokenTestSuite.addressOf(Tokens.USDT), 200_000, 0)
                    )
            })
        );

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        vm.warp(block.timestamp + 365 days);

        uint256 amountRepaid = 35000;

        CollateralDebtData memory cdd1 =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

        calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (amountRepaid))
            })
        );

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        CollateralDebtData memory cdd2 =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

        assertEq(cdd2.cumulativeQuotaInterest, 0, "Interest updated incorrectly");

        assertEq(cdd1.calcTotalDebt(), cdd2.calcTotalDebt() + amountRepaid, "Total debt updated incorrectly");
    }

    /// @dev I:[CMQ-6]: Quotas are disabled on closing an account
    function test_I_CMQ_06_quotas_are_disabled_on_close_account_and_all_quota_fees_are_repaid() public creditTest {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 5_00, uint96(1_000_000 * WAD));

        (address creditAccount,) = _openTestCreditAccount();

        (uint256 borrowedAmount, uint256 cumulativeIndexLastUpdate,,,,,,) =
            creditManager.creditAccountInfo(creditAccount);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota,
                    (tokenTestSuite.addressOf(Tokens.LINK), int96(uint96(100 * WAD)), 0)
                    )
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota,
                    (tokenTestSuite.addressOf(Tokens.USDT), int96(uint96(200 * WAD)), 0)
                    )
            })
        );

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 100);

        uint256 cumulativeIndexAtClose = pool.baseInterestIndex();

        (uint16 feeInterest,,,,) = creditManager.fees();

        uint256 interestAccured = (borrowedAmount * cumulativeIndexAtClose / cumulativeIndexLastUpdate - borrowedAmount)
            * (PERCENTAGE_FACTOR + feeInterest) / PERCENTAGE_FACTOR;

        uint256 expectedQuotasInterest = (100 * WAD * 10_00 / PERCENTAGE_FACTOR + 200 * WAD * 5_00 / PERCENTAGE_FACTOR)
            * (PERCENTAGE_FACTOR + feeInterest) / PERCENTAGE_FACTOR;

        tokenTestSuite.mint(Tokens.DAI, creditAccount, borrowedAmount);

        uint256 poolBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, address(pool));

        vm.startPrank(USER);
        creditFacade.closeCreditAccount(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.updateQuota, (tokenTestSuite.addressOf(Tokens.LINK), type(int96).min, 0)
                        )
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.updateQuota, (tokenTestSuite.addressOf(Tokens.USDT), type(int96).min, 0)
                        )
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (type(uint256).max))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.withdrawCollateral, (underlying, type(uint256).max, USER)
                        )
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.withdrawCollateral,
                        (tokenTestSuite.addressOf(Tokens.LINK), type(uint256).max, USER)
                        )
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.withdrawCollateral,
                        (tokenTestSuite.addressOf(Tokens.USDT), type(uint256).max, USER)
                        )
                })
            )
        );

        vm.stopPrank();

        expectBalance(
            Tokens.DAI,
            address(pool),
            poolBalanceBefore + borrowedAmount + interestAccured + expectedQuotasInterest,
            "Incorrect pool balance"
        );

        (uint96 quota, uint192 cumulativeIndexLU) =
            poolQuotaKeeper.getQuota(creditAccount, tokenTestSuite.addressOf(Tokens.LINK));

        assertEq(uint256(quota), 0, "Quota was not set to 0");

        (quota, cumulativeIndexLU) = poolQuotaKeeper.getQuota(creditAccount, tokenTestSuite.addressOf(Tokens.USDT));
        assertEq(uint256(quota), 0, "Quota was not set to 0");
    }

    /// @dev I:[CMQ-07]: calcDebtAndCollateral correctly counts quota interest
    function test_I_CMQ_07_calcDebtAndCollateral_correctly_includes_quota_interest(uint96 quotaLink, uint96 quotaUsdt)
        public
        creditTest
    {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(100_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500, uint96(100_000 * WAD));

        quotaLink = uint96(bound(quotaLink, 0, uint96(type(int96).max)));
        quotaUsdt = uint96(bound(quotaUsdt, 0, uint96(type(int96).max)));

        (address creditAccount,) = _openTestCreditAccount();

        (uint256 borrowedAmount, uint256 cumulativeIndexLastUpdate,,,,,,) =
            creditManager.creditAccountInfo(creditAccount);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota, (tokenTestSuite.addressOf(Tokens.LINK), int96(quotaLink), 0)
                    )
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota, (tokenTestSuite.addressOf(Tokens.USDT), int96(quotaUsdt), 0)
                    )
            })
        );

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        vm.warp(block.timestamp + 365 days);

        uint256 cumulativeIndexAtClose = pool.baseInterestIndex();

        (uint16 feeInterest,,,,) = creditManager.fees();

        quotaLink = quotaLink > uint96(100_000 * WAD) ? uint96(100_000 * WAD) : quotaLink / 10_000 * 10_000;
        quotaUsdt = quotaUsdt > uint96(100_000 * WAD) ? uint96(100_000 * WAD) : quotaUsdt / 10_000 * 10_000;

        uint256 expectedTotalDebt = (borrowedAmount * cumulativeIndexAtClose) / cumulativeIndexLastUpdate;
        expectedTotalDebt += (quotaLink * 1000) / PERCENTAGE_FACTOR;
        expectedTotalDebt += (quotaUsdt * 500) / PERCENTAGE_FACTOR;
        expectedTotalDebt += (expectedTotalDebt - borrowedAmount) * feeInterest / PERCENTAGE_FACTOR;

        CollateralDebtData memory cdd = creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

        assertEq(cdd.calcTotalDebt(), expectedTotalDebt, "Total debt updated incorrectly");
    }

    /// @dev I:[CMQ-08]: Credit Manager zeroes limits on quoted tokens upon incurring a loss
    function test_I_CMQ_08_creditManager_triggers_limit_zeroing_on_loss() public creditTest {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), type(uint16).max, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500_00, uint96(1_000_000 * WAD));

        (address creditAccount,) = _openTestCreditAccount();

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota,
                    (tokenTestSuite.addressOf(Tokens.LINK), int96(uint96(100_000 * WAD)), 0)
                    )
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota,
                    (tokenTestSuite.addressOf(Tokens.USDT), int96(uint96(200 * WAD)), 0)
                    )
            })
        );

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 100);

        address[2] memory quotedTokens = [tokenTestSuite.addressOf(Tokens.USDT), tokenTestSuite.addressOf(Tokens.LINK)];

        vm.prank(USER);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, new MultiCall[](0));

        for (uint256 i = 0; i < quotedTokens.length; ++i) {
            (,,, uint96 limit,,) = poolQuotaKeeper.getTokenQuotaParams(quotedTokens[i]);

            assertEq(limit, 0, "Limit was not zeroed");
        }
    }

    /// @dev I:[CMQ-09]: positive updateQuotas reverts on zero debt
    function test_I_CMQ_09_updateQuotas_with_positive_value_reverts_on_zero_debt() public creditTest {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));

        address creditAccount = _openCreditAccount(0, USER, 0, 0);

        // (, uint256 maxDebt) = creditFacade.debtLimits();
        // uint96 maxQuota = uint96(creditFacade.maxQuotaMultiplier() * maxDebt);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota, (tokenTestSuite.addressOf(Tokens.LINK), 100_000, 0)
                    )
            })
        );

        vm.expectRevert(UpdateQuotaOnZeroDebtAccountException.selector);

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);
    }
}
