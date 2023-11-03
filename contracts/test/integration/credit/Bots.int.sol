// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";

import {BotListV3} from "../../../core/BotListV3.sol";

import {ICreditAccountBase} from "../../../interfaces/ICreditAccountV3.sol";

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

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// MOCKS
import {AdapterMock} from "../../mocks//core/AdapterMock.sol";

import {GeneralMock} from "../../mocks//GeneralMock.sol";

// SUITES

import {IntegrationTestHelper} from "../../helpers/IntegrationTestHelper.sol";

uint256 constant WETH_TEST_AMOUNT = 5 * WAD;

/// @title CreditFacadeTest
/// @notice Designed for unit test purposes only
contract BotsIntegrationTest is IntegrationTestHelper, ICreditFacadeV3Events {
    /// @dev I:[BOT-01]: botMulticall works correctly
    function test_I_BOT_01_botMulticall_works_correctly() public withAdapterMock creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        address bot = address(new GeneralMock());

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        vm.prank(address(creditFacade));
        botList.setBotPermissions(bot, address(creditManager), creditAccount, uint192(ALL_PERMISSIONS));

        vm.expectRevert(NotApprovedBotException.selector);
        creditFacade.botMulticall(
            creditAccount, MultiCallBuilder.build(MultiCall({target: address(adapterMock), callData: DUMB_CALLDATA}))
        );

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        vm.prank(CONFIGURATOR);
        botList.setBotSpecialPermissions(address(bot), address(creditManager), type(uint192).max);
        vm.prank(bot);
        creditFacade.botMulticall(creditAccount, calls);
        vm.prank(CONFIGURATOR);
        botList.setBotSpecialPermissions(address(bot), address(creditManager), 0);

        vm.prank(USER);
        creditFacade.setBotPermissions(creditAccount, bot, uint192(ALL_PERMISSIONS));

        botList.getBotStatus({creditManager: address(creditManager), creditAccount: creditAccount, bot: bot});

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
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 1, new uint256[](0), PERCENTAGE_FACTOR, false)
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

    /// @dev I:[BOT-02]: setBotPermissions works correctly in CF
    function test_I_BOT_02_setBotPermissions_works_correctly() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        address bot = address(new GeneralMock());

        vm.expectRevert(CallerNotCreditAccountOwnerException.selector);
        vm.prank(FRIEND);
        creditFacade.setBotPermissions(creditAccount, bot, uint192(ALL_PERMISSIONS));

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(CreditManagerV3.setFlagFor, (creditAccount, BOT_PERMISSIONS_SET_FLAG, true))
        );

        vm.prank(USER);
        creditFacade.setBotPermissions(creditAccount, bot, uint192(ALL_PERMISSIONS));

        assertTrue(creditManager.flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG > 0, "Flag was not set");

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(CreditManagerV3.setFlagFor, (creditAccount, BOT_PERMISSIONS_SET_FLAG, false))
        );

        vm.prank(USER);
        creditFacade.setBotPermissions(creditAccount, bot, 0);

        assertTrue(creditManager.flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG == 0, "Flag was not set");
    }
}
