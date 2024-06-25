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
        vm.mockCall(
            creditManager,
            abi.encodeWithSignature("getBorrowerOrRevert(address)", creditAccount),
            abi.encode(address(0))
        );

        botList = new BotListV3(CONFIGURATOR);
        vm.prank(CONFIGURATOR);
        botList.addCreditManager(creditManager);
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

        vm.expectCall(creditManager, abi.encodeWithSignature("getBorrowerOrRevert(address)", creditAccount));

        vm.expectEmit(true, true, true, true);
        emit SetBotPermissions(bot, creditManager, creditAccount, 1);

        vm.prank(creditFacade);
        botList.setBotPermissions({bot: bot, creditAccount: creditAccount, permissions: 1});

        assertEq(botList.getBotPermissions(bot, creditAccount), 1, "Bot permissions were not set");

        address[] memory bots = botList.getActiveBots(creditAccount);
        assertEq(bots.length, 1, "Incorrect active bots array length");
        assertEq(bots[0], bot, "Incorrect address added to active bots list");

        vm.prank(CONFIGURATOR);
        botList.forbidBot(bot);

        vm.expectRevert(ForbiddenBotException.selector);
        vm.prank(creditFacade);
        botList.setBotPermissions({bot: bot, creditAccount: creditAccount, permissions: 1});

        assertEq(botList.getBotPermissions(bot, creditAccount), 0, "Bot permissions were not cleared after forbidding");
        assertEq(botList.getActiveBots(creditAccount).length, 0, "Bot was not removed from active after forbidding");
    }

    /// @dev U:[BL-2]: `eraseAllBotPermissions` works correctly
    function test_U_BL_02_eraseAllBotPermissions_works_correctly() public {
        BotMock(bot).setRequiredPermissions(1);
        vm.prank(creditFacade);
        botList.setBotPermissions({bot: bot, creditAccount: creditAccount, permissions: 1});

        BotMock(otherBot).setRequiredPermissions(2);
        vm.prank(creditFacade);
        botList.setBotPermissions({bot: otherBot, creditAccount: creditAccount, permissions: 2});

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        vm.prank(invalidFacade);
        botList.eraseAllBotPermissions(creditAccount);

        vm.expectCall(creditManager, abi.encodeWithSignature("getBorrowerOrRevert(address)", creditAccount));

        vm.expectEmit(true, true, true, true);
        emit SetBotPermissions(otherBot, creditManager, creditAccount, 0);

        vm.expectEmit(true, true, true, true);
        emit SetBotPermissions(bot, creditManager, creditAccount, 0);

        vm.prank(creditFacade);
        botList.eraseAllBotPermissions(creditAccount);

        assertEq(botList.getBotPermissions(bot, creditAccount), 0, "Permissions not erased for bot 1");
        assertEq(botList.getBotPermissions(otherBot, creditAccount), 0, "Permissions not erased for bot 2");

        address[] memory activeBots = botList.getActiveBots(creditAccount);
        assertEq(activeBots.length, 0, "Not all active bots were disabled");
    }
}
