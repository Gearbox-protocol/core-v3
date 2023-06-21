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

/// @title CreditFacadeTest
/// @notice Designed for unit test purposes only
contract BotsIntegrationTest is
    Test,
    BalanceHelper,
    CreditFacadeTestHelper,
    ICreditManagerV3Events,
    ICreditFacadeV3Events
{
    ///
    ///
    ///  TESTS
    ///
    ///

    //
    // BOT LIST INTEGRATION
    //

    /// @dev I:[FA-58]: botMulticall works correctly
    function test_I_FA_58_botMulticall_works_correctly() public {
        (address creditAccount,) = _openTestCreditAccount();

        address bot = address(new GeneralMock());

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        vm.expectRevert(NotApprovedBotException.selector);
        creditFacade.botMulticall(
            creditAccount, MultiCallBuilder.build(MultiCall({target: address(adapterMock), callData: DUMB_CALLDATA}))
        );

        vm.prank(USER);
        creditFacade.setBotPermissions(creditAccount, bot, type(uint192).max, uint72(1 ether), uint72(1 ether / 10));

        botList.getBotStatus({bot: bot, creditAccount: creditAccount});

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        vm.expectEmit(true, true, false, true);
        emit StartMultiCall({creditAccount: creditAccount, caller: bot});

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (creditAccount)));

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.execute, (DUMB_CALLDATA)));

        vm.expectEmit(true, false, false, true);
        emit Execute(creditAccount, address(targetMock));

        vm.expectCall(creditAccount, abi.encodeCall(ICreditAccountBase.execute, (address(targetMock), DUMB_CALLDATA)));

        vm.expectCall(address(targetMock), DUMB_CALLDATA);

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (address(1))));

        vm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 1, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        vm.prank(bot);
        creditFacade.botMulticall(creditAccount, calls);

        vm.prank(CONFIGURATOR);
        botList.setBotForbiddenStatus(bot, true);

        vm.expectRevert(NotApprovedBotException.selector);
        vm.prank(bot);
        creditFacade.botMulticall(creditAccount, calls);
    }

    /// @dev I:[FA-58A]: setBotPermissions works correctly in CF
    function test_I_FA_58A_setBotPermissions_works_correctly() public {
        (address creditAccount,) = _openTestCreditAccount();

        address bot = address(new GeneralMock());

        vm.expectRevert(CallerNotCreditAccountOwnerException.selector);
        vm.prank(FRIEND);
        creditFacade.setBotPermissions(creditAccount, bot, type(uint192).max, uint72(1 ether), uint72(1 ether / 10));

        vm.expectCall(address(botList), abi.encodeCall(BotListV3.eraseAllBotPermissions, (creditAccount)));

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(CreditManagerV3.setFlagFor, (creditAccount, BOT_PERMISSIONS_SET_FLAG, true))
        );

        vm.prank(USER);
        creditFacade.setBotPermissions(creditAccount, bot, type(uint192).max, uint72(1 ether), uint72(1 ether / 10));

        assertTrue(creditManager.flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG > 0, "Flag was not set");

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(CreditManagerV3.setFlagFor, (creditAccount, BOT_PERMISSIONS_SET_FLAG, false))
        );

        vm.prank(USER);
        creditFacade.setBotPermissions(creditAccount, bot, 0, 0, 0);

        assertTrue(creditManager.flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG == 0, "Flag was not set");
    }
}
