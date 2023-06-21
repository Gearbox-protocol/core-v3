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
import {CreditFacadeTestHelper} from "../../helpers/CreditFacadeTestHelper.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// MOCKS
import {AdapterMock} from "../../mocks//core/AdapterMock.sol";
import {TargetContractMock} from "../../mocks/core/TargetContractMock.sol";

import {GeneralMock} from "../../mocks//GeneralMock.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";
import {CreditFacadeTestSuite} from "../../suites/CreditFacadeTestSuite.sol";
import {CreditConfig} from "../../config/CreditConfig.sol";

import "forge-std/console.sol";

uint256 constant WETH_TEST_AMOUNT = 5 * WAD;
uint16 constant REFERRAL_CODE = 23;

/// @title CreditFacadeTest
/// @notice Designed for unit test purposes only
contract LiquidateCreditAccountIntegrationTest is
    Test,
    BalanceHelper,
    CreditFacadeTestHelper,
    ICreditManagerV3Events,
    ICreditFacadeV3Events
{
    // function setUp() public {
    //     _setUp(Tokens.DAI);
    // }

    // function _setUp(Tokens _underlying) internal {
    //     _setUp(_underlying, false, false, false, 1);
    // }

    // function _setUp(
    //     Tokens _underlying,
    //     bool withDegenNFT,
    //     bool withExpiration,
    //     bool supportQuotas,
    //     uint8 accountFactoryVer
    // ) internal {
    //     tokenTestSuite = new TokensTestSuite();
    //     tokenTestSuite.topUpWETH{value: 100 * WAD}();

    //     CreditConfig creditConfig = new CreditConfig(
    //         tokenTestSuite,
    //         _underlying
    //     );

    //     cft = new CreditFacadeTestSuite({ _creditConfig: creditConfig,
    //      _supportQuotas: supportQuotas,
    //      withDegenNFT: withDegenNFT,
    //      withExpiration:  withExpiration,
    //      accountFactoryVer:  accountFactoryVer});

    //     underlying = tokenTestSuite.addressOf(_underlying);
    //     creditManager = cft.creditManager();
    //     creditFacade = cft.creditFacade();
    //     creditConfigurator = cft.creditConfigurator();

    //     accountFactory = cft.af();
    //     botList = cft.botList();

    //     targetMock = new TargetContractMock();
    //     adapterMock = new AdapterMock(
    //         address(creditManager),
    //         address(targetMock)
    //     );

    //     vm.prank(CONFIGURATOR);
    //     creditConfigurator.allowAdapter(address(adapterMock));

    //     vm.label(address(adapterMock), "AdapterMock");
    //     vm.label(address(targetMock), "TargetContractMock");
    // }

    ///
    ///
    ///  HELPERS
    ///
    ///

    function _prepareMockCall() internal returns (bytes memory callData) {
        vm.prank(CONFIGURATOR);
        creditConfigurator.allowAdapter(address(adapterMock));

        callData = abi.encodeWithSignature("hello(string)", "world");
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    //
    // ALL FUNCTIONS REVERTS IF USER HAS NO ACCOUNT
    //

    /// @dev I:[FA-2]: functions reverts if borrower has no account
    function test_I_FA_02_functions_reverts_if_credit_account_not_exists() public {
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

    /// @dev I:[FA-14]: liquidateCreditAccount reverts if hf > 1
    function test_I_FA_14_liquidateCreditAccount_reverts_if_hf_is_greater_than_1() public {
        (address creditAccount,) = _openTestCreditAccount();

        vm.expectRevert(CreditAccountNotLiquidatableException.selector);

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, LIQUIDATOR, 0, true, MultiCallBuilder.build());
    }

    /// @dev I:[FA-15]: liquidateCreditAccount executes needed calls and emits events
    function test_I_FA_15_liquidateCreditAccount_executes_needed_calls_and_emits_events() public {
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

    /// @dev I:[FA-15A]: Borrowing is prohibited after a liquidation with loss
    function test_I_FA_15A_liquidateCreditAccount_prohibits_borrowing_on_loss() public {
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

    /// @dev I:[FA-15B]: CreditFacade is paused after too much cumulative loss from liquidations
    function test_I_FA_15B_liquidateCreditAccount_pauses_CreditFacade_on_too_much_loss() public {
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

    function test_I_FA_16_liquidateCreditAccount_reverts_on_internal_call_in_multicall_on_closure() public {
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
}
