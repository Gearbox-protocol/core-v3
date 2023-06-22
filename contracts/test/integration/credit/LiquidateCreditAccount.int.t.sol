// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";

import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";

import {BotListV3} from "../../../core/BotListV3.sol";
import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";

import {ICreditAccountBase} from "../../../interfaces/ICreditAccountV3.sol";

import {
    ICreditManagerV3,
    ICreditManagerV3Events,
    ClosureAction,
    ManageDebtAction,
    BOT_PERMISSIONS_SET_FLAG
} from "../../../interfaces/ICreditManagerV3.sol";
import {AllowanceAction} from "../../../interfaces/ICreditConfiguratorV3.sol";
import "../../../interfaces/ICreditFacadeV3.sol";
import {IDegenNFTV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IDegenNFTV2.sol";

import {MultiCallBuilder} from "../../lib/MultiCallBuilder.sol";

// DATA

import {MultiCall, MultiCallOps} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {Balance} from "../../../libraries/BalancesLogic.sol";

// CONSTANTS

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// TESTS

import "../../lib/constants.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";
import {IntegrationTestHelper} from "../../helpers/IntegrationTestHelper.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// MOCKS
import {AdapterMock} from "../../mocks//core/AdapterMock.sol";
import {TargetContractMock} from "../../mocks/core/TargetContractMock.sol";

import {GeneralMock} from "../../mocks//GeneralMock.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";

import {CreditConfig} from "../../config/CreditConfig.sol";

import "forge-std/console.sol";

uint256 constant WETH_TEST_AMOUNT = 5 * WAD;
uint16 constant REFERRAL_CODE = 23;

contract LiquidateCreditAccountIntegrationTest is IntegrationTestHelper, ICreditFacadeV3Events {
    /// @dev I:[LCA-1]: functions reverts if borrower has no account
    function test_I_LCA_01_functions_reverts_if_credit_account_not_exists() public creditTest {
        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.closeCreditAccount(DUMB_ADDRESS, FRIEND, 0, false, MultiCallBuilder.build());

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.closeCreditAccount(
            DUMB_ADDRESS,
            FRIEND,
            0,
            false,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            )
        );

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.liquidateCreditAccount(DUMB_ADDRESS, DUMB_ADDRESS, 0, false, MultiCallBuilder.build());

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.multicall(
            DUMB_ADDRESS,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            )
        );

        // vm.prank(CONFIGURATOR);
        // creditConfigurator.allowContract(address(targetMock), address(adapterMock));
    }

    /// @dev I:[LCA-2]: liquidateCreditAccount reverts if hf > 1
    function test_I_LCA_2_liquidateCreditAccount_reverts_if_hf_is_greater_than_1() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        vm.expectRevert(CreditAccountNotLiquidatableException.selector);

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, LIQUIDATOR, 0, true, MultiCallBuilder.build());
    }

    /// @dev I:[LCA-3]: liquidateCreditAccount executes needed calls and emits events
    function test_I_LCA_03_liquidateCreditAccount_executes_needed_calls_and_emits_events() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        vm.prank(USER);
        creditFacade.setBotPermissions({
            creditAccount: creditAccount,
            bot: address(adapterMock),
            permissions: uint192(ADD_COLLATERAL_PERMISSION),
            fundingAmount: 0,
            weeklyFundingAllowance: 0
        });

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        _makeAccountsLiquitable();

        // EXPECTED STACK TRACE & EVENTS

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (creditAccount)));

        vm.expectEmit(true, false, false, false);
        emit StartMultiCall({creditAccount: creditAccount, caller: LIQUIDATOR});

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.execute, (DUMB_CALLDATA)));

        vm.expectEmit(true, false, false, false);
        emit Execute(creditAccount, address(targetMock));

        vm.expectCall(creditAccount, abi.encodeCall(ICreditAccountBase.execute, (address(targetMock), DUMB_CALLDATA)));

        vm.expectCall(address(targetMock), DUMB_CALLDATA);

        vm.expectEmit(false, false, false, false);
        emit FinishMultiCall();

        vm.expectCall(address(botList), abi.encodeCall(BotListV3.eraseAllBotPermissions, (creditAccount)));

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (address(1))));

        // Total value = 2 * DAI_ACCOUNT_AMOUNT, cause we have x2 leverage
        // uint256 totalValue = 2 * DAI_ACCOUNT_AMOUNT;
        // uint256 debtWithInterest = DAI_ACCOUNT_AMOUNT;

        // vm.expectCall(
        //     address(creditManager),
        //     abi.encodeCall(
        //         ICreditManagerV3.closeCreditAccount,
        //         (
        //             creditAccount,
        //             ClosureAction.LIQUIDATE_ACCOUNT,
        //             totalValue,
        //             LIQUIDATOR,
        //             FRIEND,
        //             1,
        //             10,
        //             debtWithInterest,
        //             true
        //         )
        //     )
        // );

        vm.expectEmit(true, true, true, true);
        emit LiquidateCreditAccount(creditAccount, USER, LIQUIDATOR, FRIEND, ClosureAction.LIQUIDATE_ACCOUNT, 0);

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 10, false, calls);
    }

    /// @dev I:[LCA-4]: Borrowing is prohibited after a liquidation with loss
    function test_I_LCA_04_liquidateCreditAccount_prohibits_borrowing_on_loss() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        uint8 maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();

        assertGt(maxDebtPerBlockMultiplier, 0, "SETUP: Increase debt is already enabled");

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        _makeAccountsLiquitable();

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 10, false, calls);

        maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();

        assertEq(maxDebtPerBlockMultiplier, 0, "Increase debt wasn't forbidden after loss");
    }

    /// @dev I:[LCA-5]: CreditFacade is paused after too much cumulative loss from liquidations
    function test_I_LCA_05_liquidateCreditAccount_pauses_CreditFacade_on_too_much_loss() public creditTest {
        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxCumulativeLoss(1);

        (address creditAccount,) = _openTestCreditAccount();

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        _makeAccountsLiquitable();

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 10, false, calls);

        assertTrue(creditFacade.paused(), "Credit manager was not paused");
    }

    /// @dev I:[LCA-6]: liquidateCreditAccount reverts on internal call in multicall on closure
    function test_I_LCA_06_liquidateCreditAccount_reverts_on_internal_call_in_multicall_on_closure()
        public
        creditTest
    {
        /// TODO: Add all cases with different permissions!

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
            })
        );

        (address creditAccount,) = _openTestCreditAccount();

        _makeAccountsLiquitable();
        vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, ADD_COLLATERAL_PERMISSION));

        vm.prank(LIQUIDATOR);

        // It's used dumb calldata, cause all calls to creditFacade are forbidden
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 10, true, calls);
    }

    /// @dev I:[LCA-7]: liquidateCreditAccount sets correct values and transfers tokens from pool
    ///
    /// This test covers the case:
    /// Closure type: LIQUIDATION / LIQUIDATION_EXPIRED
    /// Underlying balance: < amountToPool
    /// Send all assets: false
    /// Remaining funds: >0
    ///

    function test_I_LCA_07_liquidate_credit_account_charges_caller_if_underlying_token_not_enough() public creditTest {
        // uint256 debt;
        // address creditAccount;

        // uint256 expectedRemainingFunds = 100 * WAD;

        // uint256 profit;
        // uint256 amountToPool;
        // uint256 totalValue;
        // uint256 interestAccrued;

        // {
        //     uint256 cumulativeIndexLastUpdate;
        //     (debt, cumulativeIndexLastUpdate, creditAccount) = _openCreditAccount();

        //     vm.warp(block.timestamp + 365 days);

        //     uint256 cumulativeIndexAtClose = pool.calcLinearCumulative_RAY();

        //     interestAccrued = (debt * cumulativeIndexAtClose) / cumulativeIndexLastUpdate - debt;

        //     uint16 feeInterest;
        //     uint16 feeLiquidation;
        //     uint16 liquidationDiscount;

        //     {
        //         (feeInterest,,,,) = creditManager.fees();
        //     }

        //     {
        //         uint16 feeLiquidationNormal;
        //         uint16 feeLiquidationExpired;

        //         (, feeLiquidationNormal,, feeLiquidationExpired,) = creditManager.fees();

        //         feeLiquidation = expirable ? feeLiquidationExpired : feeLiquidationNormal;
        //     }

        //     {
        //         uint16 liquidationDiscountNormal;
        //         uint16 liquidationDiscountExpired;

        //         (feeInterest,, liquidationDiscountNormal,, liquidationDiscountExpired) = creditManager.fees();

        //         liquidationDiscount = expirable ? liquidationDiscountExpired : liquidationDiscountNormal;
        //     }

        //     uint256 profitInterest = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR;

        //     amountToPool = debt + interestAccrued + profitInterest;

        //     totalValue =
        //         ((amountToPool + expectedRemainingFunds) * PERCENTAGE_FACTOR) / (liquidationDiscount - feeLiquidation);

        //     uint256 profitLiquidation = (totalValue * feeLiquidation) / PERCENTAGE_FACTOR;

        //     amountToPool += profitLiquidation;

        //     profit = profitInterest + profitLiquidation;
        // }

        // uint256 poolBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, address(pool));

        // tokenTestSuite.mint(Tokens.DAI, LIQUIDATOR, totalValue);
        // expectBalance(Tokens.DAI, USER, 0, "USER has non-zero balance");
        // expectBalance(Tokens.DAI, FRIEND, 0, "FRIEND has non-zero balance");
        // expectBalance(Tokens.DAI, LIQUIDATOR, totalValue, "LIQUIDATOR has incorrect initial balance");

        // expectBalance(Tokens.DAI, creditAccount, debt, "creditAccount has incorrect initial balance");

        // uint256 remainingFunds;

        // {
        //     uint256 loss;

        //     (uint16 feeInterest,,,,) = creditManager.fees();

        //     CollateralDebtData memory collateralDebtData;
        //     collateralDebtData.debt = debt;
        //     collateralDebtData.accruedInterest = interestAccrued;
        //     collateralDebtData.accruedFees = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR;
        //     collateralDebtData.totalValue = totalValue;
        //     collateralDebtData.enabledTokensMask = UNDERLYING_TOKEN_MASK;

        //     vm.expectCall(address(pool), abi.encodeCall(IPoolService.repayCreditAccount, (debt, profit, 0)));

        //     // (remainingFunds, loss) = creditManager.closeCreditAccount({
        //     //     creditAccount: creditAccount,
        //     //     closureAction: i == 1 ? ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT : ClosureAction.LIQUIDATE_ACCOUNT,
        //     //     collateralDebtData: collateralDebtData,
        //     //     payer: LIQUIDATOR,
        //     //     to: FRIEND,
        //     //     skipTokensMask: 0,
        //     //     convertToETH: false
        //     // });

        //     assertLe(expectedRemainingFunds - remainingFunds, 2, "Incorrect remaining funds");

        //     assertEq(loss, 0, "Loss can't be positive with remaining funds");
        // }

        // {
        //     expectBalance(Tokens.DAI, creditAccount, 1, "Credit account balance != 1");
        //     expectBalance(Tokens.DAI, USER, remainingFunds, "USER get incorrect amount as remaning funds");

        //     expectBalance(Tokens.DAI, address(pool), poolBalanceBefore + amountToPool, "INCORRECT POOL BALANCE");
        // }

        // expectBalance(
        //     Tokens.DAI,
        //     LIQUIDATOR,
        //     totalValue + debt - amountToPool - remainingFunds - 1,
        //     "Incorrect amount were paid to lqiudaidator"
        // );
    }

    /// @dev I:[LCA-8]: liquidateCreditAccount sends ETH for WETH creditManger to borrower
    /// CASE: LIQUIDATION
    function test_I_LCA_08_liquidate_credit_account_sends_eth_to_liquidator_and_weth_to_borrower() public {
        // /// Store USER ETH balance

        // // uint256 userBalanceBefore = tokenTestSuite.balanceOf(Tokens.WETH, USER);

        // (,, uint16 liquidationDiscount,,) = creditManager.fees();

        // // It takes "clean" address which doesn't holds any assets

        // // _connectCreditManagerSuite(Tokens.WETH);

        // /// CLOSURE CASE
        // (uint256 debt,, address creditAccount) = _openCreditAccount();

        // // Transfer additional debt. After that underluying token balance = 2 * debt
        // tokenTestSuite.mint(Tokens.WETH, creditAccount, debt);

        // uint256 totalValue = debt * 2;

        // uint256 wethTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));
        // uint256 daiTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI));

        // CollateralDebtData memory collateralDebtData;
        // collateralDebtData.debt = debt;
        // collateralDebtData.accruedInterest = 0;
        // collateralDebtData.accruedFees = 0;
        // collateralDebtData.totalValue = totalValue;
        // collateralDebtData.enabledTokensMask = wethTokenMask | daiTokenMask;

        // creditManager.closeCreditAccount({
        //     creditAccount: creditAccount,
        //     closureAction: ClosureAction.LIQUIDATE_ACCOUNT,
        //     collateralDebtData: collateralDebtData,
        //     payer: LIQUIDATOR,
        //     to: FRIEND,
        //     skipTokensMask: 0,
        //     convertToETH: true
        // });

        // // checks that no eth were sent to USER account
        // expectEthBalance(USER, 0);

        // expectBalance(Tokens.WETH, creditAccount, 1, "Credit account balance != 1");

        // // expectBalance(Tokens.WETH, USER, userBalanceBefore + remainingFunds, "Incorrect amount were paid back");

        // assertEq(
        //     withdrawalManager.immediateWithdrawals(address(creditFacade), tokenTestSuite.addressOf(Tokens.WETH)),
        //     (totalValue * (PERCENTAGE_FACTOR - liquidationDiscount)) / PERCENTAGE_FACTOR,
        //     "Incorrect amount were paid to liqiudator friend address"
        // );
    }

    /// @dev I:[LCA-9]: liquidateCreditAccount sends ETH for WETH creditManger to borrower
    /// CASE: LIQUIDATION
    /// Underlying token: DAI
    function test_I_LCA_09_liquidate_dai_credit_account_sends_eth_to_liquidator() public {
        // /// CLOSURE CASE
        // (uint256 debt,, address creditAccount) = _openCreditAccount();
        // // creditManager.transferAccountOwnership(creditAccount, address(this));

        // // Transfer additional debt. After that underluying token balance = 2 * debt
        // tokenTestSuite.mint(Tokens.DAI, creditAccount, debt);

        // // Adds WETH to test how it would be converted
        // tokenTestSuite.mint(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);

        // // creditManager.transferAccountOwnership(creditAccount, USER);
        // uint256 wethTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));
        // uint256 daiTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI));

        // CollateralDebtData memory collateralDebtData;
        // collateralDebtData.debt = debt;
        // collateralDebtData.accruedInterest = 0;
        // collateralDebtData.accruedFees = 0;
        // collateralDebtData.totalValue = debt;
        // collateralDebtData.enabledTokensMask = wethTokenMask | daiTokenMask;

        // creditManager.closeCreditAccount({
        //     creditAccount: creditAccount,
        //     closureAction: ClosureAction.LIQUIDATE_ACCOUNT,
        //     collateralDebtData: collateralDebtData,
        //     payer: LIQUIDATOR,
        //     to: FRIEND,
        //     skipTokensMask: 0,
        //     convertToETH: true
        // });

        // expectBalance(Tokens.WETH, creditAccount, 1);

        // assertEq(
        //     withdrawalManager.immediateWithdrawals(address(creditFacade), tokenTestSuite.addressOf(Tokens.WETH)),
        //     WETH_EXCHANGE_AMOUNT - 1,
        //     "Incorrect amount were paid to liqiudator friend address"
        // );
    }
}
