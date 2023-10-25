// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../../../interfaces/IAddressProviderV3.sol";

import {BotListV3} from "../../../core/BotListV3.sol";
import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";

import {ICreditAccountBase} from "../../../interfaces/ICreditAccountV3.sol";
import {SECONDS_PER_YEAR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {
    ICreditManagerV3,
    ICreditManagerV3Events,
    ManageDebtAction,
    BOT_PERMISSIONS_SET_FLAG
} from "../../../interfaces/ICreditManagerV3.sol";

import "../../../interfaces/ICreditFacadeV3.sol";

import {MultiCallBuilder} from "../../lib/MultiCallBuilder.sol";

// DATA

// CONSTANTS

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// TESTS

import "../../lib/constants.sol";

import {IntegrationTestHelper} from "../../helpers/IntegrationTestHelper.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// MOCKS
import {AdapterMock} from "../../mocks/core/AdapterMock.sol";
import {PriceFeedMock} from "../../mocks/oracles/PriceFeedMock.sol";
import {GeneralMock} from "../../mocks/GeneralMock.sol";

// SUITES

import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

import {IPoolV3} from "../../../interfaces/IPoolV3.sol";

import "forge-std/console.sol";

uint256 constant WETH_TEST_AMOUNT = 5 * WAD;
uint16 constant REFERRAL_CODE = 23;

contract CloseCreditAccountIntegrationTest is IntegrationTestHelper, ICreditFacadeV3Events {
    /// @dev I:[CCA-1]: closeCreditAccount reverts if borrower has no account
    function test_I_CCA_01_closeCreditAccount_reverts_if_credit_account_not_exists() public creditTest {
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

    /// @dev I:[CCA-2]: closeCreditAccount correctly wraps ETH
    function test_I_CCA_02_closeCreditAccount_correctly_wraps_ETH() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        vm.roll(block.number + 1);

        _prepareForWETHTest();
        vm.prank(USER);
        creditFacade.closeCreditAccount{value: WETH_TEST_AMOUNT}(
            creditAccount, USER, 0, false, MultiCallBuilder.build()
        );
        _checkForWETHTest();
    }

    /// @dev I:[CCA-3]: closeCreditAccount runs multicall operations in correct order
    function test_I_CCA_03_closeCreditAccount_runs_operations_in_correct_order() public withAdapterMock creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        address bot = address(new GeneralMock());

        vm.prank(USER);
        creditFacade.setBotPermissions({
            creditAccount: creditAccount,
            bot: bot,
            permissions: uint192(ADD_COLLATERAL_PERMISSION),
            totalFundingAllowance: 0,
            weeklyFundingAllowance: 0
        });

        // LIST OF EXPECTED CALLS

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (creditAccount)));

        vm.expectEmit(true, false, false, false);
        emit StartMultiCall({creditAccount: creditAccount, caller: USER});

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.execute, (DUMB_CALLDATA)));

        vm.expectEmit(true, false, false, true);
        emit Execute(creditAccount, address(targetMock));

        vm.expectCall(creditAccount, abi.encodeCall(ICreditAccountBase.execute, (address(targetMock), DUMB_CALLDATA)));

        vm.expectCall(address(targetMock), DUMB_CALLDATA);

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (address(1))));

        vm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        vm.expectCall(
            address(botList), abi.encodeCall(BotListV3.eraseAllBotPermissions, (address(creditManager), creditAccount))
        );

        // todo: add withdrawal manager call

        // vm.expectCall(
        //     address(creditManager),
        //     abi.encodeCall(
        //         ICreditManagerV3.closeCreditAccount,
        //         (creditAccount, ClosureAction.CLOSE_ACCOUNT, 0, USER, FRIEND, 1, 10, DAI_ACCOUNT_AMOUNT, true)
        //     )
        // );

        vm.expectEmit(true, true, false, false);
        emit CloseCreditAccount(creditAccount, USER, FRIEND);

        // increase block number, cause it's forbidden to close ca in the same block
        vm.roll(block.number + 1);

        vm.prank(USER);
        creditFacade.closeCreditAccount(creditAccount, FRIEND, 10, false, calls);

        assertEq0(targetMock.callData(), DUMB_CALLDATA, "Incorrect calldata");
    }

    /// @dev I:[CCA-4]: closeCreditAccount reverts on internal calls in multicall
    function test_I_CCA_04_closeCreditAccount_reverts_on_internal_call_in_multicall_on_closure() public creditTest {
        /// TODO: CHANGE TEST
        // bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");

        // _openTestCreditAccount();

        // vm.roll(block.number + 1);

        // vm.expectRevert(ForbiddenDuringClosureException.selector);

        // // It's used dumb calldata, cause all calls to creditFacade are forbidden

        // vm.prank(USER);
        // creditFacade.closeCreditAccount(
        //     FRIEND, 0, true, MultiCallBuilder.build(MultiCall({target: address(creditFacade), callData: DUMB_CALLDATA}))
        // );
    }

    /// @dev I:[CCA-5]: closeCreditAccount returns account to the end of AF1s remove borrower from creditAccounts mapping
    function test_I_CCA_05_close_credit_account_updates_pool_correctly() public withAccountFactoryV1 creditTest {
        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT / 2)
                    )
            })
        );

        // Existing address case
        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        assertTrue(
            creditAccount
                != AccountFactory(addressProvider.getAddressOrRevert(AP_ACCOUNT_FACTORY, NO_VERSION_CONTROL)).tail(),
            "credit account is already in tail!"
        );

        // Increase block number cause it's forbidden to close credit account in the same block
        vm.roll(block.number + 1);

        vm.prank(USER);
        creditFacade.closeCreditAccount(creditAccount, USER, 0, false, new MultiCall[](0));

        assertEq(
            creditAccount,
            AccountFactory(addressProvider.getAddressOrRevert(AP_ACCOUNT_FACTORY, NO_VERSION_CONTROL)).tail(),
            "credit account is not in accountFactory tail!"
        );

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditManager.getBorrowerOrRevert(creditAccount);
    }

    /// @dev I:[CCA-6]: closeCreditAccount returns undelying tokens if credit account balance > amounToPool
    ///
    /// This test covers the case:
    /// Closure type: CLOSURE
    /// Underlying balance: > amountToPool
    /// Send all assets: false
    ///
    function test_I_CCA_06_close_credit_account_returns_underlying_token_if_not_liquidated() public creditTest {
        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT / 2)
                    )
            })
        );

        // Existing address case
        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        uint256 poolBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, address(pool));
        uint256 friendBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, FRIEND);

        (uint256 debt, uint256 cumulativeIndexLastUpdate,,,,,,) = creditManager.creditAccountInfo(creditAccount);

        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 1);

        uint256 cumulativeIndexAtClose = pool.baseInterestIndex();

        uint256 interestAccrued = (debt * cumulativeIndexAtClose) / cumulativeIndexLastUpdate - debt;

        (uint16 feeInterest,,,,) = creditManager.fees();

        uint256 profit = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR;

        uint256 amountToPool = debt + interestAccrued + profit;

        vm.expectCall(address(pool), abi.encodeCall(IPoolV3.repayCreditAccount, (debt, profit, 0)));

        vm.prank(USER);
        creditFacade.closeCreditAccount(creditAccount, FRIEND, 0, false, new MultiCall[](0));

        expectBalance(Tokens.DAI, creditAccount, 1);
        expectBalance(Tokens.DAI, address(pool), poolBalanceBefore + amountToPool);
        expectBalance(
            Tokens.DAI,
            FRIEND,
            friendBalanceBefore + 3 * DAI_ACCOUNT_AMOUNT / 2 - amountToPool - 1,
            "Incorrect amount were paid back"
        );
    }

    /// @dev I:[CCA-7]: closeCreditAccount sets correct values and transfers tokens from pool
    ///
    /// This test covers the case:
    /// Closure type: CLOSURE
    /// Underlying balance: < amountToPool
    /// Send all assets: false
    ///
    function test_I_CCA_07_close_credit_account_charges_caller_if_underlying_token_not_enough() public creditTest {
        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT / 2)
                    )
            })
        );

        // Existing address case
        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        tokenTestSuite.mint(Tokens.DAI, USER, 2 * DAI_ACCOUNT_AMOUNT);

        uint256 userBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, USER);
        uint256 friendBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, FRIEND);

        (uint256 debt, uint256 cumulativeIndexLastUpdate,,,,,,) = creditManager.creditAccountInfo(creditAccount);

        uint256 rate = pool.baseInterestRate();

        /// amount on account is 3*2*DAI_ACCOUNT_AMOUNT
        /// debt is DAI_ACCOUNT_AMOUNT
        uint256 warpTime = RAY / rate * SECONDS_PER_YEAR;

        vm.warp(block.timestamp + warpTime);
        vm.roll(block.number + 1);

        uint256 cumulativeIndexAtClose = pool.baseInterestIndex();

        uint256 interestAccrued = (debt * cumulativeIndexAtClose) / cumulativeIndexLastUpdate - debt;

        uint256 amountToPool;
        {
            (uint16 feeInterest,,,,) = creditManager.fees();

            uint256 profit = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR;

            amountToPool = debt + interestAccrued + profit;

            console.log(amountToPool * 10_000 / DAI_ACCOUNT_AMOUNT);

            uint256 poolBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, address(pool));

            vm.expectCall(address(pool), abi.encodeCall(IPoolV3.repayCreditAccount, (debt, profit, 0)));

            vm.prank(USER);
            creditFacade.closeCreditAccount(creditAccount, FRIEND, 0, false, new MultiCall[](0));

            expectBalance(Tokens.DAI, creditAccount, 1, "Credit account balance != 1");

            expectBalance(Tokens.DAI, address(pool), poolBalanceBefore + amountToPool);
        }

        expectBalance(
            Tokens.DAI,
            USER,
            userBalanceBefore + 3 * DAI_ACCOUNT_AMOUNT / 2 - amountToPool - 1,
            "Incorrect amount was charged from user"
        );

        expectBalance(Tokens.DAI, FRIEND, friendBalanceBefore, "Incorrect amount were paid back");
    }

    /// @dev I:[CCA-8]: liquidateCreditAccount sets correct values and transfers tokens from pool
    ///
    /// This test covers the case:
    /// Closure type: LIQUIDATION
    /// Underlying balance: < amountToPool
    /// Send all assets: false
    /// Remaining funds: 0
    ///
    function test_I_CCA_08_liquidate_credit_account_charges_caller_if_underlying_token_not_enough() public creditTest {
        uint256 friendBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, FRIEND);

        uint256 interestAccrued;

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT / 2)
                    )
            })
        );

        // Existing address case
        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        tokenTestSuite.mint(Tokens.DAI, LIQUIDATOR, 2 * DAI_ACCOUNT_AMOUNT);
        uint256 debt;
        {
            uint256 cumulativeIndexLastUpdate;
            (debt, cumulativeIndexLastUpdate,,,,,,) = creditManager.creditAccountInfo(creditAccount);

            uint256 rate = pool.baseInterestRate();

            if (!expirable) {
                /// amount on account is 3*2*DAI_ACCOUNT_AMOUNT
                /// debt is DAI_ACCOUNT_AMOUNT
                uint256 warpTime = RAY / rate * SECONDS_PER_YEAR;

                vm.warp(block.timestamp + warpTime);

                address pf = priceOracle.priceFeeds(tokenTestSuite.addressOf(Tokens.DAI));
                PriceFeedMock(pf).setParams(0, 0, block.timestamp, 0);
            }

            vm.roll(block.number + 1);

            uint256 cumulativeIndexAtClose = pool.baseInterestIndex();

            interestAccrued = (debt * cumulativeIndexAtClose) / cumulativeIndexLastUpdate - debt;
        }

        uint256 poolBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, address(pool));
        uint256 userBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, USER);
        uint256 discount;

        {
            (,, uint16 liquidationDiscount,, uint16 liquidationDiscountExpired) = creditManager.fees();
            discount = expirable ? liquidationDiscountExpired : liquidationDiscount;
        }

        uint256 totalValue = (3 * DAI_ACCOUNT_AMOUNT / 2 - 1) / (10 ** 10) * (10 ** 10);
        uint256 amountToPool = (totalValue * discount) / PERCENTAGE_FACTOR;

        {
            uint256 loss = debt + interestAccrued - amountToPool;

            vm.expectCall(address(pool), abi.encodeCall(IPoolV3.repayCreditAccount, (debt, 0, loss)));
        }

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 0, false, new MultiCall[](0));

        assertEq(tokenTestSuite.balanceOf(Tokens.DAI, USER), userBalanceBefore, "Remaining funds is not zero!");

        expectBalance(Tokens.DAI, creditAccount, 1, "Credit account balance != 1");

        expectBalance(Tokens.DAI, address(pool), poolBalanceBefore + amountToPool);

        // uint256 expectedFriendBalance = friendBalanceBefore
        // + (totalValue * (PERCENTAGE_FACTOR - discount)) / PERCENTAGE_FACTOR - (i == 2 ? 0 : 1);

        uint256 expectedFriendBalance = friendBalanceBefore + 3 * DAI_ACCOUNT_AMOUNT / 2 - amountToPool - 1;

        expectBalance(
            Tokens.DAI, FRIEND, expectedFriendBalance, "Incorrect amount were paid to liqiudator friend address"
        );
    }

    /// @dev I:[CCA-9]: closeCreditAccount sends assets depends on sendAllAssets flag
    ///
    /// This test covers the case:
    /// Closure type: LIQUIDATION
    /// Underlying balance: < amountToPool
    /// Send all assets: false
    /// Remaining funds: >0
    ///

    function test_I_CCA_09_close_credit_account_with_nonzero_skipTokensMask_sends_correct_tokens() public creditTest {
        // (uint256 debt,, address creditAccount) = _openCreditAccount();

        // tokenTestSuite.mint(Tokens.DAI, creditAccount, debt);
        // tokenTestSuite.mint(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);

        // tokenTestSuite.mint(Tokens.USDC, creditAccount, USDC_EXCHANGE_AMOUNT);

        // tokenTestSuite.mint(Tokens.LINK, creditAccount, LINK_EXCHANGE_AMOUNT);

        // uint256 wethTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));
        // uint256 usdcTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDC));
        // uint256 linkTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));

        // CollateralDebtData memory collateralDebtData;
        // collateralDebtData.debt = debt;
        // collateralDebtData.accruedInterest = 0;
        // collateralDebtData.accruedFees = 0;
        // collateralDebtData.enabledTokensMask = wethTokenMask | usdcTokenMask | linkTokenMask;

        // creditManager.closeCreditAccount({
        //     creditAccount: creditAccount,
        //     closureAction: ClosureAction.CLOSE_ACCOUNT,
        //     collateralDebtData: collateralDebtData,
        //     payer: USER,
        //     to: FRIEND,
        //     skipTokensMask: wethTokenMask | usdcTokenMask,
        //     convertToETH: false
        // });

        // expectBalance(Tokens.WETH, FRIEND, 0);
        // expectBalance(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);

        // expectBalance(Tokens.USDC, FRIEND, 0);
        // expectBalance(Tokens.USDC, creditAccount, USDC_EXCHANGE_AMOUNT);

        // expectBalance(Tokens.LINK, FRIEND, LINK_EXCHANGE_AMOUNT - 1);
    }

    /// @dev I:[CCA-10]: closeCreditAccount sends ETH for WETH creditManger to borrower
    /// CASE: CLOSURE
    /// Underlying token: WETH
    function test_I_CCA_10_close_weth_credit_account_sends_eth_to_borrower() public creditTest {
        // // It takes "clean" address which doesn't holds any assets

        // // _connectCreditManagerSuite(Tokens.WETH);

        // /// CLOSURE CASE
        // (uint256 debt, uint256 cumulativeIndexLastUpdate, address creditAccount) = _openCreditAccount();

        // // Transfer additional debt. After that underluying token balance = 2 * debt
        // tokenTestSuite.mint(Tokens.WETH, creditAccount, debt);

        // vm.warp(block.timestamp + 365 days);

        // uint256 cumulativeIndexAtClose = pool.baseInterestIndex();

        // uint256 interestAccrued = (debt * cumulativeIndexAtClose) / cumulativeIndexLastUpdate - debt;

        // // creditManager.closeCreditAccount(USER, ClosureAction.CLOSE_ACCOUNT, 0, USER, USER, 0, true);

        // // creditManager.closeCreditAccount(
        // //     creditAccount, ClosureAction.CLOSE_ACCOUNT, 0, USER, USER, 1, 0, debt + interestAccrued, true
        // // );

        // (uint16 feeInterest,,,,) = creditManager.fees();
        // uint256 profit = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR;

        // CollateralDebtData memory collateralDebtData;
        // collateralDebtData.debt = debt;
        // collateralDebtData.accruedInterest = interestAccrued;
        // collateralDebtData.accruedFees = profit;
        // collateralDebtData.enabledTokensMask = UNDERLYING_TOKEN_MASK;

        // creditManager.closeCreditAccount({
        //     creditAccount: creditAccount,
        //     closureAction: ClosureAction.CLOSE_ACCOUNT,
        //     collateralDebtData: collateralDebtData,
        //     payer: USER,
        //     to: USER,
        //     skipTokensMask: 0,
        //     convertToETH: true
        // });

        // expectBalance(Tokens.WETH, creditAccount, 1);

        // uint256 amountToPool = debt + interestAccrued + profit;

        // assertEq(
        //     withdrawalManager.immediateWithdrawals(address(creditFacade), tokenTestSuite.addressOf(Tokens.WETH)),
        //     2 * debt - amountToPool - 1,
        //     "Incorrect amount deposited to withdrawalManager"
        // );
    }

    /// @dev I:[CCA-11]: closeCreditAccount sends ETH for WETH creditManger to borrower
    /// CASE: CLOSURE
    /// Underlying token: DAI
    function test_I_CCA_11_close_dai_credit_account_sends_eth_to_borrower() public creditTest {
        // /// CLOSURE CASE
        // (uint256 debt,, address creditAccount) = _openCreditAccount();

        // // Transfer additional debt. After that underluying token balance = 2 * debt
        // tokenTestSuite.mint(Tokens.DAI, creditAccount, debt);

        // // Adds WETH to test how it would be converted
        // tokenTestSuite.mint(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);

        // uint256 wethTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));
        // uint256 daiTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI));

        // CollateralDebtData memory collateralDebtData;
        // collateralDebtData.debt = debt;
        // collateralDebtData.accruedInterest = 0;
        // collateralDebtData.accruedFees = 0;
        // collateralDebtData.enabledTokensMask = wethTokenMask | daiTokenMask;

        // creditManager.closeCreditAccount({
        //     creditAccount: creditAccount,
        //     closureAction: ClosureAction.CLOSE_ACCOUNT,
        //     collateralDebtData: collateralDebtData,
        //     payer: USER,
        //     to: USER,
        //     skipTokensMask: 0,
        //     convertToETH: true
        // });

        // expectBalance(Tokens.WETH, creditAccount, 1);

        // assertEq(
        //     withdrawalManager.immediateWithdrawals(address(creditFacade), tokenTestSuite.addressOf(Tokens.WETH)),
        //     WETH_EXCHANGE_AMOUNT - 1,
        //     "Incorrect amount deposited to withdrawalManager"
        // );
    }

    // function test_I_CM_65_closeCreditAccount_reverts_when_paused_and_liquidator_tries_to_close() public creditTest {
    //     vm.startPrank(CONFIGURATOR);
    //     creditManager.pause();
    //     creditManager.addEmergencyLiquidator(LIQUIDATOR);
    //     vm.stopPrank();

    //     vm.expectRevert("Pausable: paused");
    //     // creditManager.closeCreditAccount(USER, ClosureAction.CLOSE_ACCOUNT, 0, LIQUIDATOR, FRIEND, 0, false);
    // }
}
