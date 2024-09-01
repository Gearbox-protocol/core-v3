// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {BotListV3} from "../../../core/BotListV3.sol";
import {IBotListV3Events} from "../../../interfaces/IBotListV3.sol";

// TEST
import "../../lib/constants.sol";

// MOCKS
import {BotMock} from "../../mocks/core/BotMock.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

/// @title Bot list V3 unit test
/// @notice U:[BL]: Unit tests for bot list v3
contract BotListV3UnitTest is Test, IBotListV3Events {
    BotListV3 botList;

    address bot;
    address otherBot;
    address creditManager;
    address creditFacade;
    address creditAccount;
    address invalidFacade;

    function setUp() public {
        bot = address(new BotMock());
        otherBot = address(new BotMock());
        creditManager = makeAddr("CREDIT_MANAGER");
        creditFacade = makeAddr("CREDIT_FACADE");
        creditAccount = makeAddr("CREDIT_ACCOUNT");
        invalidFacade = makeAddr("INVALID_FACADE");

        vm.mockCall(creditManager, abi.encodeWithSignature("creditFacade()"), abi.encode(creditFacade));
        vm.mockCall(creditFacade, abi.encodeWithSignature("creditManager()"), abi.encode(creditManager));
        vm.mockCall(invalidFacade, abi.encodeWithSignature("creditManager()"), abi.encode(creditManager));
        vm.mockCall(creditAccount, abi.encodeWithSignature("creditManager()"), abi.encode(creditManager));

        botList = new BotListV3(CONFIGURATOR);
        vm.prank(CONFIGURATOR);
        botList.setCreditManagerApprovedStatus(creditManager, true);
    }

    /// @notice U:[BL-1]: `setBotPermissions` works correctly
    function test_U_BL_01_setBotPermissions_works_correctly() public {
        vm.expectRevert(CallerNotCreditFacadeException.selector);
        vm.prank(invalidFacade);
        botList.setBotPermissions({bot: bot, creditAccount: creditAccount, permissions: type(uint192).max});

        BotMock(bot).setRequiredPermissions(1);

        vm.expectRevert(IncorrectBotPermissionsException.selector);
        vm.prank(creditFacade);
        botList.setBotPermissions({bot: bot, creditAccount: creditAccount, permissions: 2});

        vm.prank(CONFIGURATOR);
        botList.setBotForbiddenStatus(bot, true);

        vm.expectRevert(InvalidBotException.selector);
        vm.prank(creditFacade);
        botList.setBotPermissions({bot: bot, creditAccount: creditAccount, permissions: 1});

        vm.prank(CONFIGURATOR);
        botList.setBotForbiddenStatus(bot, false);

        vm.expectEmit(true, true, true, true);
        emit SetBotPermissions(bot, creditManager, creditAccount, 1);

        vm.prank(creditFacade);
        uint256 activeBotsRemaining =
            botList.setBotPermissions({bot: bot, creditAccount: creditAccount, permissions: 1});

        assertEq(activeBotsRemaining, 1, "Incorrect number of bots returned");
        assertEq(botList.botPermissions(bot, creditAccount), 1, "Bot permissions were not set");

        address[] memory bots = botList.activeBots(creditAccount);
        assertEq(bots.length, 1, "Incorrect active bots array length");
        assertEq(bots[0], bot, "Incorrect address added to active bots list");

        BotMock(bot).setRequiredPermissions(2);

        vm.prank(creditFacade);
        activeBotsRemaining = botList.setBotPermissions({bot: bot, creditAccount: creditAccount, permissions: 2});

        assertEq(activeBotsRemaining, 1, "Incorrect number of bots returned");
        assertEq(botList.botPermissions(bot, creditAccount), 2, "Bot permissions were not set");

        bots = botList.activeBots(creditAccount);
        assertEq(bots.length, 1, "Incorrect active bots array length");
        assertEq(bots[0], bot, "Incorrect address added to active bots list");

        vm.prank(CONFIGURATOR);
        botList.setBotForbiddenStatus(bot, true);

        vm.expectEmit(true, true, true, true);
        emit SetBotPermissions(bot, creditManager, creditAccount, 0);

        vm.prank(creditFacade);
        activeBotsRemaining = botList.setBotPermissions({bot: bot, creditAccount: creditAccount, permissions: 0});

        assertEq(activeBotsRemaining, 0, "Incorrect number of bots returned");
        assertEq(botList.botPermissions(bot, creditAccount), 0, "Bot permissions were not set");

        bots = botList.activeBots(creditAccount);
        assertEq(bots.length, 0, "Incorrect active bots array length");
    }

    /// @dev U:[BL-2]: `eraseAllBotPermissions` works correctly
    function test_U_BL_02_eraseAllBotPermissions_works_correctly() public {
        BotMock(bot).setRequiredPermissions(1);
        vm.prank(creditFacade);
        botList.setBotPermissions({bot: bot, creditAccount: creditAccount, permissions: 1});

        BotMock(otherBot).setRequiredPermissions(2);
        vm.prank(creditFacade);
        uint256 activeBotsRemaining =
            botList.setBotPermissions({bot: otherBot, creditAccount: creditAccount, permissions: 2});

        assertEq(activeBotsRemaining, 2, "Incorrect number of active bots");

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        vm.prank(invalidFacade);
        botList.eraseAllBotPermissions(creditAccount);

        vm.expectEmit(true, true, true, true);
        emit SetBotPermissions(otherBot, creditManager, creditAccount, 0);

        vm.expectEmit(true, true, true, true);
        emit SetBotPermissions(bot, creditManager, creditAccount, 0);

        vm.prank(creditFacade);
        botList.eraseAllBotPermissions(creditAccount);

        assertEq(botList.botPermissions(bot, creditAccount), 0, "Permissions not erased for bot 1");
        assertEq(botList.botPermissions(otherBot, creditAccount), 0, "Permissions not erased for bot 2");

        address[] memory activeBots = botList.activeBots(creditAccount);
        assertEq(activeBots.length, 0, "Not all active bots were disabled");
    }
}
