/*
// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {BotListV3} from "../../../core/BotListV3.sol";
import {IBotListV3Events} from "../../../interfaces/IBotListV3.sol";
import {MAX_SANE_ACTIVE_BOTS} from "../../../libraries/Constants.sol";

// TEST
import "../../lib/constants.sol";

// MOCKS
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {BotMock} from "../../mocks/core/BotMock.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

/// @title Bot list V3 unit test
/// @notice U:[BL]: Unit tests for bot list v3
contract BotListV3UnitTest is Test, IBotListV3Events {
    BotListV3 botList;
    address owner;

    address bot;
    address otherBot;
    address creditManager;
    address creditFacade;
    address creditAccount;
    address invalidFacade;
    address invalidAccount;

    function setUp() public {
        AddressProviderV3ACLMock addressProvider = new AddressProviderV3ACLMock();

        bot = address(new BotMock());
        otherBot = address(new BotMock());
        creditManager = makeAddr("CREDIT_MANAGER");
        creditFacade = makeAddr("CREDIT_FACADE");
        creditAccount = makeAddr("CREDIT_ACCOUNT");
        invalidFacade = makeAddr("INVALID_FACADE");
        invalidAccount = makeAddr("INVALID_ACCOUNT");

        vm.mockCall(creditManager, abi.encodeWithSignature("creditFacade()"), abi.encode(creditFacade));
        vm.mockCall(creditAccount, abi.encodeWithSignature("creditManager()"), abi.encode(creditManager));
        vm.mockCall(
            creditManager,
            abi.encodeWithSignature("getBorrowerOrRevert(address)", creditAccount),
            abi.encode(makeAddr("borrower"))
        );

        vm.mockCall(invalidAccount, abi.encodeWithSignature("creditManager()"), abi.encode(creditManager));
        vm.mockCallRevert(
            creditManager,
            abi.encodeWithSignature("getBorrowerOrRevert(address)", invalidAccount),
            abi.encodeWithSignature("CreditAccountDoesNotExistException()")
        );

        botList = new BotListV3(address(addressProvider));
        owner = botList.owner();
    }

    /// @notice U:[BL-1]: `setBotPermissions` works correctly
    function test_U_BL_01_setBotPermissions_works_correctly() public {
        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(creditFacade);
        botList.setBotPermissions({bot: bot, creditAccount: invalidAccount, permissions: type(uint192).max});

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        vm.prank(invalidFacade);
        botList.setBotPermissions({bot: bot, creditAccount: creditAccount, permissions: type(uint192).max});

        BotMock(bot).setRequiredPermissions(1);
        BotMock(otherBot).setRequiredPermissions(1);

        vm.expectRevert(IncorrectBotPermissionsException.selector);
        vm.prank(creditFacade);
        botList.setBotPermissions({bot: bot, creditAccount: creditAccount, permissions: 2});

        vm.prank(owner);
        botList.forbidBot(otherBot);

        vm.expectRevert(InvalidBotException.selector);
        vm.prank(creditFacade);
        botList.setBotPermissions({bot: otherBot, creditAccount: creditAccount, permissions: 1});

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

        vm.prank(owner);
        botList.forbidBot(bot);

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

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(creditFacade);
        botList.eraseAllBotPermissions(invalidAccount);

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

    /// @notice U:[BL-3]: `setBotPermissions` cannot activate more bots than `MAX_SANE_ACTIVE_BOTS`
    function test_U_BL_03_setBotPermissions_cannot_activate_more_bots_than_max() public {
        uint256 activeBotsRemaining;

        // Create MAX_SANE_ACTIVE_BOTS + 1 bots
        address[] memory bots = new address[](MAX_SANE_ACTIVE_BOTS + 1);
        for (uint256 i; i < bots.length; ++i) {
            bots[i] = address(new BotMock());
            BotMock(bots[i]).setRequiredPermissions(1);
        }

        // Add MAX_SANE_ACTIVE_BOTS bots successfully
        for (uint256 i; i < MAX_SANE_ACTIVE_BOTS; ++i) {
            vm.prank(creditFacade);
            activeBotsRemaining =
                botList.setBotPermissions({bot: bots[i], creditAccount: creditAccount, permissions: 1});
            assertEq(activeBotsRemaining, i + 1, "Incorrect number of active bots");
        }

        // Try to add one more bot
        vm.expectRevert(TooManyActiveBotsException.selector);
        vm.prank(creditFacade);
        botList.setBotPermissions({bot: bots[MAX_SANE_ACTIVE_BOTS], creditAccount: creditAccount, permissions: 1});

        // Verify we can still remove and add bots as long as total stays under limit
        vm.prank(creditFacade);
        activeBotsRemaining = botList.setBotPermissions({bot: bots[0], creditAccount: creditAccount, permissions: 0});
        assertEq(activeBotsRemaining, MAX_SANE_ACTIVE_BOTS - 1, "Incorrect number of active bots after removal");

        vm.prank(creditFacade);
        activeBotsRemaining =
            botList.setBotPermissions({bot: bots[MAX_SANE_ACTIVE_BOTS], creditAccount: creditAccount, permissions: 1});
        assertEq(activeBotsRemaining, MAX_SANE_ACTIVE_BOTS, "Incorrect number of active bots after replacement");
    }
}
*/
