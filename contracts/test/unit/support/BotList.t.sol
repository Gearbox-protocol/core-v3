// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {BotList} from "../../../support/BotList.sol";
import {IBotListEvents, BotFunding} from "../../../interfaces/IBotList.sol";
import {ICreditAccount} from "../../../interfaces/ICreditAccount.sol";
import {ICreditManagerV3} from "../../../interfaces/ICreditManagerV3.sol";

// TEST
import "../../lib/constants.sol";

// MOCKS
import {AddressProviderACLMock} from "../../mocks/core/AddressProviderACLMock.sol";
import {ERC20BlacklistableMock} from "../../mocks/token/ERC20Blacklistable.sol";
import {GeneralMock} from "../../mocks/GeneralMock.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

/// @title LPPriceFeedTest
/// @notice Designed for unit test purposes only
contract BotListTest is Test, IBotListEvents {
    AddressProviderACLMock public addressProvider;

    BotList botList;

    TokensTestSuite tokenTestSuite;

    GeneralMock bot;
    GeneralMock creditAccount;
    GeneralMock creditManager;
    GeneralMock creditFacade;

    function setUp() public {
        vm.prank(CONFIGURATOR);
        addressProvider = new AddressProviderACLMock();

        tokenTestSuite = new TokensTestSuite();

        botList = new BotList(address(addressProvider));

        bot = new GeneralMock();
        creditAccount = new GeneralMock();
        creditManager = new GeneralMock();
        creditFacade = new GeneralMock();

        vm.mockCall(
            address(creditAccount),
            abi.encodeWithSelector(ICreditAccount.creditManager.selector),
            abi.encode(address(creditManager))
        );

        vm.mockCall(
            address(creditManager),
            abi.encodeWithSelector(ICreditManagerV3.creditFacade.selector),
            abi.encode(address(creditFacade))
        );
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev [BL-1]: constructor sets correct values
    function test_BL_01_constructor_sets_correct_values() public {
        assertEq(botList.treasury(), FRIEND2, "Treasury contract incorrect");
        assertEq(botList.daoFee(), 0, "Initial DAO fee incorrect");
    }

    /// @dev [BL-2]: setDAOFee works correctly
    function test_BL_02_setDAOFee_works_correctly() public {
        vm.expectRevert(CallerNotConfiguratorException.selector);
        botList.setDAOFee(1);

        vm.expectEmit(false, false, false, true);
        emit SetBotDAOFee(15);

        vm.prank(CONFIGURATOR);
        botList.setDAOFee(15);

        assertEq(botList.daoFee(), 15, "DAO fee incorrect");
    }

    /// @dev [BL-3]: setBotPermissions works correctly
    function test_BL_03_setBotPermissions_works_correctly() public {
        vm.expectRevert(CallerNotCreditAccountFacadeException.selector);
        vm.prank(USER);
        botList.setBotPermissions({
            creditAccount: address(creditAccount),
            bot: address(bot),
            permissions: type(uint192).max,
            fundingAmount: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, DUMB_ADDRESS));
        vm.prank(address(creditFacade));
        botList.setBotPermissions({
            creditAccount: address(creditAccount),
            bot: DUMB_ADDRESS,
            permissions: type(uint192).max,
            fundingAmount: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        vm.prank(CONFIGURATOR);
        botList.setBotForbiddenStatus(address(bot), true);

        vm.expectRevert(InvalidBotException.selector);
        vm.prank(address(creditFacade));
        botList.setBotPermissions({
            creditAccount: address(creditAccount),
            bot: address(bot),
            permissions: type(uint192).max,
            fundingAmount: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        vm.expectRevert(PositiveFundingForInactiveBotException.selector);
        vm.prank(address(creditFacade));
        botList.setBotPermissions({
            creditAccount: address(creditAccount),
            bot: address(bot),
            permissions: 0,
            fundingAmount: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        vm.prank(address(creditFacade));
        botList.setBotPermissions({
            creditAccount: address(creditAccount),
            bot: address(bot),
            permissions: 0,
            fundingAmount: 0,
            weeklyFundingAllowance: 0
        });

        vm.prank(CONFIGURATOR);
        botList.setBotForbiddenStatus(address(bot), false);

        vm.expectEmit(true, true, false, true);
        emit SetBotPermissions(address(creditAccount), address(bot), 1, uint72(1 ether), uint72(1 ether / 10));

        vm.prank(address(creditFacade));
        uint256 activeBotsRemaining = botList.setBotPermissions({
            creditAccount: address(creditAccount),
            bot: address(bot),
            permissions: 1,
            fundingAmount: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        assertEq(activeBotsRemaining, 1, "Incorrect number of bots returned");

        assertEq(botList.botPermissions(address(creditAccount), address(bot)), 1, "Bot permissions were not set");

        (uint256 remainingFunds, uint256 maxWeeklyAllowance, uint256 remainingWeeklyAllowance, uint256 allowanceLU) =
            botList.botFunding(address(creditAccount), address(bot));

        address[] memory bots = botList.getActiveBots(address(creditAccount));

        assertEq(bots.length, 1, "Incorrect active bots array length");

        assertEq(bots[0], address(bot), "Incorrect address added to active bots list");

        assertEq(remainingFunds, 1 ether, "Incorrect remaining funds value");

        assertEq(maxWeeklyAllowance, 1 ether / 10, "Incorrect max weekly allowance");

        assertEq(remainingWeeklyAllowance, 1 ether / 10, "Incorrect remaining weekly allowance");

        assertEq(allowanceLU, block.timestamp, "Incorrect allowance update timestamp");

        vm.prank(address(creditFacade));
        activeBotsRemaining = botList.setBotPermissions({
            creditAccount: address(creditAccount),
            bot: address(bot),
            permissions: 2,
            fundingAmount: uint72(2 ether),
            weeklyFundingAllowance: uint72(2 ether / 10)
        });

        (remainingFunds, maxWeeklyAllowance, remainingWeeklyAllowance, allowanceLU) =
            botList.botFunding(address(creditAccount), address(bot));

        assertEq(activeBotsRemaining, 1, "Incorrect number of bots returned");

        assertEq(botList.botPermissions(address(creditAccount), address(bot)), 2, "Bot permissions were not set");

        assertEq(remainingFunds, 2 ether, "Incorrect remaining funds value");

        assertEq(maxWeeklyAllowance, 2 ether / 10, "Incorrect max weekly allowance");

        assertEq(remainingWeeklyAllowance, 2 ether / 10, "Incorrect remaining weekly allowance");

        assertEq(allowanceLU, block.timestamp, "Incorrect allowance update timestamp");

        bots = botList.getActiveBots(address(creditAccount));

        assertEq(bots.length, 1, "Incorrect active bots array length");

        assertEq(bots[0], address(bot), "Incorrect address added to active bots list");

        vm.prank(address(creditFacade));
        activeBotsRemaining = botList.setBotPermissions({
            creditAccount: address(creditAccount),
            bot: address(bot),
            permissions: 0,
            fundingAmount: 0,
            weeklyFundingAllowance: 0
        });

        (remainingFunds, maxWeeklyAllowance, remainingWeeklyAllowance, allowanceLU) =
            botList.botFunding(address(creditAccount), address(bot));

        assertEq(activeBotsRemaining, 0, "Incorrect number of bots returned");

        assertEq(botList.botPermissions(address(creditAccount), address(bot)), 0, "Bot permissions were not set");

        assertEq(remainingFunds, 0, "Incorrect remaining funds value");

        assertEq(maxWeeklyAllowance, 0, "Incorrect max weekly allowance");

        assertEq(remainingWeeklyAllowance, 0, "Incorrect remaining weekly allowance");

        assertEq(allowanceLU, block.timestamp, "Incorrect allowance update timestamp");

        bots = botList.getActiveBots(address(creditAccount));

        assertEq(bots.length, 0, "Incorrect active bots array length");
    }

    /// @dev [BL-4]: addFunding and removeFunding work correctly
    function test_BL_04_addFunding_removeFunding_work_correctly() public {
        vm.deal(USER, 10 ether);

        vm.expectRevert(AmountCantBeZeroException.selector);
        botList.addFunding();

        vm.expectEmit(true, false, false, true);
        emit ChangeFunding(USER, 1 ether);

        vm.prank(USER);
        botList.addFunding{value: 1 ether}();

        assertEq(botList.fundingBalances(USER), 1 ether, "User's bot funding wallet has incorrect balance");

        vm.expectEmit(true, false, false, true);
        emit ChangeFunding(USER, 2 ether);

        vm.prank(USER);
        botList.addFunding{value: 1 ether}();

        assertEq(botList.fundingBalances(USER), 2 ether, "User's bot funding wallet has incorrect balance");

        vm.expectEmit(true, false, false, true);
        emit ChangeFunding(USER, 3 ether / 2);

        vm.prank(USER);
        botList.removeFunding(1 ether / 2);

        assertEq(botList.fundingBalances(USER), 3 ether / 2, "User's bot funding wallet has incorrect balance");

        assertEq(USER.balance, 85 ether / 10, "User's balance is incorrect");
    }

    /// @dev [BL-5]: pullPayment works correctly
    function test_BL_05_pullPayment_works_correctly() public {
        vm.prank(CONFIGURATOR);
        botList.setDAOFee(5000);

        vm.mockCall(
            address(creditManager),
            abi.encodeWithSelector(ICreditManagerV3.getBorrowerOrRevert.selector, address(creditAccount)),
            abi.encode(USER)
        );

        vm.deal(USER, 10 ether);

        vm.prank(USER);
        botList.addFunding{value: 2 ether}();

        vm.prank(address(creditFacade));
        botList.setBotPermissions({
            creditAccount: address(creditAccount),
            bot: address(bot),
            permissions: 1,
            fundingAmount: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        vm.warp(block.timestamp + 1 days);

        vm.expectEmit(true, true, true, true);
        emit PullBotPayment(USER, address(creditAccount), address(bot), uint72(1 ether / 20), uint72(1 ether / 40));

        vm.prank(address(bot));
        botList.pullPayment({creditAccount: address(creditAccount), paymentAmount: uint72(1 ether / 20)});

        (uint256 remainingFunds, uint256 maxWeeklyAllowance, uint256 remainingWeeklyAllowance, uint256 allowanceLU) =
            botList.botFunding(address(creditAccount), address(bot));

        assertEq(remainingFunds, 1 ether - (1 ether / 20) - (1 ether / 40), "Bot funding remaining funds incorrect");

        assertEq(
            remainingWeeklyAllowance,
            (1 ether / 10) - (1 ether / 20) - (1 ether / 40),
            "Bot remaining weekly allowance incorrect"
        );

        assertEq(
            botList.fundingBalances(USER),
            2 ether - (1 ether / 20) - (1 ether / 40),
            "User remaining funding balance incorrect"
        );

        assertEq(allowanceLU, block.timestamp - 1 days, "Allowance update timestamp incorrect");

        assertEq(address(bot).balance, 1 ether / 20, "Bot was sent incorrect ETH amount");

        assertEq(FRIEND2.balance, 1 ether / 40, "Treasury was sent incorrect amount");

        vm.warp(block.timestamp + 7 days);

        vm.prank(address(bot));
        botList.pullPayment({creditAccount: address(creditAccount), paymentAmount: uint72(1 ether / 20)});

        (remainingFunds, maxWeeklyAllowance, remainingWeeklyAllowance, allowanceLU) =
            botList.botFunding(address(creditAccount), address(bot));

        assertEq(remainingFunds, 1 ether - (2 ether / 20) - (2 ether / 40), "Bot funding remaining funds incorrect");

        assertEq(
            remainingWeeklyAllowance,
            (1 ether / 10) - (1 ether / 20) - (1 ether / 40),
            "Bot remaining weekly allowance incorrect"
        );

        assertEq(allowanceLU, block.timestamp, "Allowance update timestamp incorrect");

        assertEq(
            botList.fundingBalances(USER),
            2 ether - (2 ether / 20) - (2 ether / 40),
            "User remaining funding balance incorrect"
        );

        assertEq(address(bot).balance, 2 ether / 20, "Bot was sent incorrect ETH amount");

        assertEq(FRIEND2.balance, 2 ether / 40, "Treasury was sent incorrect amount");
    }

    /// @dev [BL-6]: eraseAllBotPermissions works correctly
    function test_BL_06_eraseAllBotPermissions_works_correctly() public {
        vm.prank(address(creditFacade));
        botList.setBotPermissions({
            creditAccount: address(creditAccount),
            bot: address(bot),
            permissions: 1,
            fundingAmount: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        address bot2 = address(new GeneralMock());

        vm.prank(address(creditFacade));
        uint256 activeBotsRemaining = botList.setBotPermissions({
            creditAccount: address(creditAccount),
            bot: address(bot2),
            permissions: 2,
            fundingAmount: uint72(2 ether),
            weeklyFundingAllowance: uint72(2 ether / 10)
        });

        assertEq(activeBotsRemaining, 2, "Incorrect number of active bots");

        vm.expectEmit(true, false, false, false);
        emit EraseBots(address(creditAccount));

        vm.prank(address(creditFacade));
        botList.eraseAllBotPermissions(address(creditAccount));

        assertEq(
            botList.botPermissions(address(creditAccount), address(bot)), 0, "Permissions were not erased for bot 1"
        );

        assertEq(
            botList.botPermissions(address(creditAccount), address(bot2)), 0, "Permissions were not erased for bot 2"
        );

        (uint256 remainingFunds, uint256 maxWeeklyAllowance, uint256 remainingWeeklyAllowance, uint256 allowanceLU) =
            botList.botFunding(address(creditAccount), address(bot));

        assertEq(remainingFunds, 0, "Remaining funds were not zeroed");

        assertEq(maxWeeklyAllowance, 0, "Remaining funds were not zeroed");

        assertEq(remainingWeeklyAllowance, 0, "Remaining funds were not zeroed");

        assertEq(allowanceLU, block.timestamp, "Allowance update timestamp incorrect");

        (remainingFunds, maxWeeklyAllowance, remainingWeeklyAllowance, allowanceLU) =
            botList.botFunding(address(creditAccount), address(bot2));

        assertEq(remainingFunds, 0, "Remaining funds were not zeroed");

        assertEq(maxWeeklyAllowance, 0, "Remaining funds were not zeroed");

        assertEq(remainingWeeklyAllowance, 0, "Remaining funds were not zeroed");

        assertEq(allowanceLU, block.timestamp, "Allowance update timestamp incorrect");

        address[] memory activeBots = botList.getActiveBots(address(creditAccount));

        assertEq(activeBots.length, 0, "Not all active bots were disabled");
    }
}
