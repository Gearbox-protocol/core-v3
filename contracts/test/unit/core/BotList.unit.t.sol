// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {BotListV3} from "../../../core/BotListV3.sol";
import {IBotListV3Events, BotFunding} from "../../../interfaces/IBotListV3.sol";
import {ICreditAccountBase} from "../../../interfaces/ICreditAccountV3.sol";
import {ICreditManagerV3} from "../../../interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3} from "../../../interfaces/ICreditFacadeV3.sol";

// TEST
import "../../lib/constants.sol";

// MOCKS
import {AddressProviderV3ACLMock, AP_WETH_TOKEN, AP_TREASURY} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {WETHMock} from "../../mocks/token/WETHMock.sol";
import {GeneralMock} from "../../mocks/GeneralMock.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

contract InvalidCFMock {
    address public creditManager;

    constructor(address _creditManager) {
        creditManager = _creditManager;
    }
}

/// @title LPPriceFeedTest
/// @notice Designed for unit test purposes only
contract BotListTest is Test, IBotListV3Events {
    AddressProviderV3ACLMock public addressProvider;
    WETHMock public weth;

    BotListV3 botList;

    TokensTestSuite tokenTestSuite;

    GeneralMock bot;
    address creditManager;
    address creditFacade;
    address creditAccount;

    address invalidCF;

    function setUp() public {
        vm.prank(CONFIGURATOR);
        addressProvider = new AddressProviderV3ACLMock();
        weth = WETHMock(payable(addressProvider.getAddressOrRevert(AP_WETH_TOKEN, 0)));

        tokenTestSuite = new TokensTestSuite();

        botList = new BotListV3(address(addressProvider));

        bot = new GeneralMock();
        creditManager = makeAddr("CREDIT_MANAGER");
        creditFacade = makeAddr("CREDIT_FACADE");
        creditAccount = makeAddr("CREDIT_ACCOUNT");

        invalidCF = address(new InvalidCFMock(address(creditManager)));

        vm.mockCall(
            address(creditManager),
            abi.encodeWithSelector(ICreditManagerV3.creditFacade.selector),
            abi.encode(address(creditFacade))
        );

        vm.mockCall(
            address(creditFacade),
            abi.encodeWithSelector(ICreditFacadeV3.creditManager.selector),
            abi.encode(address(creditManager))
        );

        vm.mockCall(
            creditAccount,
            abi.encodeWithSelector(ICreditAccountBase.creditManager.selector),
            abi.encode(address(creditManager))
        );

        vm.prank(CONFIGURATOR);
        botList.setApprovedCreditManagerStatus(address(creditManager), true);
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev [BL-1]: constructor sets correct values
    function test_BL_01_constructor_sets_correct_values() public {
        assertEq(botList.treasury(), addressProvider.getAddressOrRevert(AP_TREASURY, 0), "Treasury contract incorrect");
        assertEq(botList.weth(), address(weth), "WETH incorrect");
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
        vm.expectRevert(CallerNotCreditFacadeException.selector);
        vm.prank(invalidCF);
        botList.setBotPermissions({
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: address(bot),
            permissions: type(uint192).max,
            fundingAmount: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, DUMB_ADDRESS));
        vm.prank(address(creditFacade));
        botList.setBotPermissions({
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: DUMB_ADDRESS,
            permissions: type(uint192).max,
            fundingAmount: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        vm.prank(CONFIGURATOR);
        botList.setBotForbiddenStatus(address(creditManager), address(bot), true);

        vm.expectRevert(InvalidBotException.selector);
        vm.prank(address(creditFacade));
        botList.setBotPermissions({
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: address(bot),
            permissions: type(uint192).max,
            fundingAmount: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        vm.prank(CONFIGURATOR);
        botList.setBotForbiddenStatus(address(creditManager), address(bot), false);

        vm.prank(CONFIGURATOR);
        botList.setBotSpecialPermissions(address(creditManager), address(bot), 1);

        vm.expectRevert(InvalidBotException.selector);
        vm.prank(address(creditFacade));
        botList.setBotPermissions({
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: address(bot),
            permissions: type(uint192).max,
            fundingAmount: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        vm.prank(CONFIGURATOR);
        botList.setBotSpecialPermissions(address(creditManager), address(bot), 0);

        vm.expectEmit(true, true, true, true);
        emit SetBotPermissions(creditManager, creditAccount, address(bot), 1, uint72(1 ether), uint72(1 ether / 10));

        vm.prank(address(creditFacade));
        uint256 activeBotsRemaining = botList.setBotPermissions({
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: address(bot),
            permissions: 1,
            fundingAmount: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        assertEq(activeBotsRemaining, 1, "Incorrect number of bots returned");

        assertEq(botList.botPermissions(creditManager, creditAccount, address(bot)), 1, "Bot permissions were not set");

        (uint256 remainingFunds, uint256 maxWeeklyAllowance, uint256 remainingWeeklyAllowance, uint256 allowanceLU) =
            botList.botFunding(creditManager, creditAccount, address(bot));

        address[] memory bots = botList.getActiveBots(creditManager, creditAccount);

        assertEq(bots.length, 1, "Incorrect active bots array length");

        assertEq(bots[0], address(bot), "Incorrect address added to active bots list");

        assertEq(remainingFunds, 1 ether, "Incorrect remaining funds value");

        assertEq(maxWeeklyAllowance, 1 ether / 10, "Incorrect max weekly allowance");

        assertEq(remainingWeeklyAllowance, 1 ether / 10, "Incorrect remaining weekly allowance");

        assertEq(allowanceLU, block.timestamp, "Incorrect allowance update timestamp");

        vm.prank(address(creditFacade));
        activeBotsRemaining = botList.setBotPermissions({
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: address(bot),
            permissions: 2,
            fundingAmount: uint72(2 ether),
            weeklyFundingAllowance: uint72(2 ether / 10)
        });

        (remainingFunds, maxWeeklyAllowance, remainingWeeklyAllowance, allowanceLU) =
            botList.botFunding(creditManager, creditAccount, address(bot));

        assertEq(activeBotsRemaining, 1, "Incorrect number of bots returned");

        assertEq(botList.botPermissions(creditManager, creditAccount, address(bot)), 2, "Bot permissions were not set");

        assertEq(remainingFunds, 2 ether, "Incorrect remaining funds value");

        assertEq(maxWeeklyAllowance, 2 ether / 10, "Incorrect max weekly allowance");

        assertEq(remainingWeeklyAllowance, 2 ether / 10, "Incorrect remaining weekly allowance");

        assertEq(allowanceLU, block.timestamp, "Incorrect allowance update timestamp");

        bots = botList.getActiveBots(creditManager, creditAccount);

        assertEq(bots.length, 1, "Incorrect active bots array length");

        assertEq(bots[0], address(bot), "Incorrect address added to active bots list");

        vm.prank(CONFIGURATOR);
        botList.setBotForbiddenStatus(address(creditManager), address(bot), true);

        vm.expectEmit(true, true, true, false);
        emit EraseBot(address(creditManager), address(creditAccount), address(bot));

        vm.prank(address(creditFacade));
        activeBotsRemaining = botList.setBotPermissions({
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: address(bot),
            permissions: 0,
            fundingAmount: 0,
            weeklyFundingAllowance: 0
        });

        (remainingFunds, maxWeeklyAllowance, remainingWeeklyAllowance, allowanceLU) =
            botList.botFunding(creditManager, creditAccount, address(bot));

        assertEq(activeBotsRemaining, 0, "Incorrect number of bots returned");

        assertEq(botList.botPermissions(creditManager, creditAccount, address(bot)), 0, "Bot permissions were not set");

        assertEq(remainingFunds, 0, "Incorrect remaining funds value");

        assertEq(maxWeeklyAllowance, 0, "Incorrect max weekly allowance");

        assertEq(remainingWeeklyAllowance, 0, "Incorrect remaining weekly allowance");

        assertEq(allowanceLU, 0, "Incorrect allowance update timestamp");

        bots = botList.getActiveBots(creditManager, creditAccount);

        assertEq(bots.length, 0, "Incorrect active bots array length");
    }

    /// @dev [BL-4]: deposit and withdraw work correctly
    function test_BL_04_deposit_withdraw_work_correctly() public {
        vm.deal(USER, 10 ether);

        vm.expectRevert(AmountCantBeZeroException.selector);
        botList.deposit();

        vm.expectEmit(true, false, false, true);
        emit Deposit(USER, 1 ether);

        vm.prank(USER);
        botList.deposit{value: 1 ether}();

        assertEq(botList.balanceOf(USER), 1 ether, "User's bot funding wallet has incorrect balance");

        vm.expectEmit(true, false, false, true);
        emit Deposit(USER, 1 ether);

        vm.prank(USER);
        botList.deposit{value: 1 ether}();

        assertEq(botList.balanceOf(USER), 2 ether, "User's bot funding wallet has incorrect balance");

        vm.expectEmit(true, false, false, true);
        emit Withdraw(USER, 1 ether / 2);

        vm.prank(USER);
        botList.withdraw(1 ether / 2);

        assertEq(botList.balanceOf(USER), 3 ether / 2, "User's bot funding wallet has incorrect balance");

        assertEq(USER.balance, 85 ether / 10, "User's balance is incorrect");
    }

    /// @dev [BL-5]: payBot works correctly
    function test_BL_05_payBot_works_correctly() public {
        vm.prank(CONFIGURATOR);
        botList.setDAOFee(5000);

        vm.mockCall(
            address(creditManager),
            abi.encodeWithSelector(ICreditManagerV3.getBorrowerOrRevert.selector, creditAccount),
            abi.encode(USER)
        );

        vm.deal(USER, 10 ether);

        vm.prank(USER);
        botList.deposit{value: 2 ether}();

        vm.prank(address(creditFacade));
        botList.setBotPermissions({
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: address(bot),
            permissions: 1,
            fundingAmount: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        vm.prank(invalidCF);
        botList.payBot({
            payer: USER,
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: address(bot),
            paymentAmount: uint72(1 ether / 20)
        });

        vm.expectEmit(true, true, true, true);
        emit PayBot(USER, creditAccount, address(bot), uint72(1 ether / 20), uint72(1 ether / 40));

        vm.prank(address(creditFacade));
        botList.payBot({
            payer: USER,
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: address(bot),
            paymentAmount: uint72(1 ether / 20)
        });

        (uint256 remainingFunds, uint256 maxWeeklyAllowance, uint256 remainingWeeklyAllowance, uint256 allowanceLU) =
            botList.botFunding(creditManager, creditAccount, address(bot));

        assertEq(remainingFunds, 1 ether - (1 ether / 20) - (1 ether / 40), "Bot funding remaining funds incorrect");

        assertEq(
            remainingWeeklyAllowance,
            (1 ether / 10) - (1 ether / 20) - (1 ether / 40),
            "Bot remaining weekly allowance incorrect"
        );

        assertEq(
            botList.balanceOf(USER),
            2 ether - (1 ether / 20) - (1 ether / 40),
            "User remaining funding balance incorrect"
        );

        assertEq(allowanceLU, block.timestamp - 1 days, "Allowance update timestamp incorrect");

        assertEq(weth.balanceOf(address(bot)), 1 ether / 20, "Bot was sent incorrect WETH amount");

        assertEq(
            weth.balanceOf(addressProvider.getTreasuryContract()), 1 ether / 40, "Treasury was sent incorrect amount"
        );

        vm.warp(block.timestamp + 7 days);

        vm.prank(address(creditFacade));
        botList.payBot({
            payer: USER,
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: address(bot),
            paymentAmount: uint72(1 ether / 20)
        });

        (remainingFunds, maxWeeklyAllowance, remainingWeeklyAllowance, allowanceLU) =
            botList.botFunding(creditManager, creditAccount, address(bot));

        assertEq(remainingFunds, 1 ether - (2 ether / 20) - (2 ether / 40), "Bot funding remaining funds incorrect");

        assertEq(
            remainingWeeklyAllowance,
            (1 ether / 10) - (1 ether / 20) - (1 ether / 40),
            "Bot remaining weekly allowance incorrect"
        );

        assertEq(allowanceLU, block.timestamp, "Allowance update timestamp incorrect");

        assertEq(
            botList.balanceOf(USER),
            2 ether - (2 ether / 20) - (2 ether / 40),
            "User remaining funding balance incorrect"
        );

        assertEq(weth.balanceOf(address(bot)), 2 ether / 20, "Bot was sent incorrect WETH amount");

        assertEq(
            weth.balanceOf(addressProvider.getTreasuryContract()), 2 ether / 40, "Treasury was sent incorrect amount"
        );
    }

    /// @dev [BL-6]: eraseAllBotPermissions works correctly
    function test_BL_06_eraseAllBotPermissions_works_correctly() public {
        vm.prank(address(creditFacade));
        botList.setBotPermissions({
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: address(bot),
            permissions: 1,
            fundingAmount: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        address bot2 = address(new GeneralMock());

        vm.prank(address(creditFacade));
        uint256 activeBotsRemaining = botList.setBotPermissions({
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: address(bot2),
            permissions: 2,
            fundingAmount: uint72(2 ether),
            weeklyFundingAllowance: uint72(2 ether / 10)
        });

        assertEq(activeBotsRemaining, 2, "Incorrect number of active bots");

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        vm.prank(invalidCF);
        botList.eraseAllBotPermissions(creditManager, creditAccount);

        // it starts removing bots from the end
        vm.expectEmit(true, true, true, false);
        emit EraseBot(creditManager, creditAccount, address(bot2));

        vm.expectEmit(true, true, true, false);
        emit EraseBot(creditManager, creditAccount, address(bot));

        vm.prank(address(creditFacade));
        botList.eraseAllBotPermissions(creditManager, creditAccount);

        assertEq(
            botList.botPermissions(creditManager, creditAccount, address(bot)),
            0,
            "Permissions were not erased for bot 1"
        );

        assertEq(
            botList.botPermissions(creditManager, creditAccount, address(bot2)),
            0,
            "Permissions were not erased for bot 2"
        );

        (uint256 remainingFunds, uint256 maxWeeklyAllowance, uint256 remainingWeeklyAllowance, uint256 allowanceLU) =
            botList.botFunding(creditManager, creditAccount, address(bot));

        assertEq(remainingFunds, 0, "Remaining funds were not zeroed");

        assertEq(maxWeeklyAllowance, 0, "Remaining funds were not zeroed");

        assertEq(remainingWeeklyAllowance, 0, "Remaining funds were not zeroed");

        (remainingFunds, maxWeeklyAllowance, remainingWeeklyAllowance, allowanceLU) =
            botList.botFunding(creditManager, creditAccount, address(bot2));

        assertEq(remainingFunds, 0, "Remaining funds were not zeroed");

        assertEq(maxWeeklyAllowance, 0, "Remaining funds were not zeroed");

        assertEq(remainingWeeklyAllowance, 0, "Remaining funds were not zeroed");

        address[] memory activeBots = botList.getActiveBots(creditManager, creditAccount);

        assertEq(activeBots.length, 0, "Not all active bots were disabled");
    }

    /// @dev [BL-7]: setBotSpecialPermissions works correctly
    function test_BL_07_setBotSpecialPermissions_works_correctly() public {
        vm.expectRevert(CallerNotConfiguratorException.selector);
        botList.setBotSpecialPermissions(address(creditManager), address(bot), 2);

        vm.expectEmit(true, true, false, true);
        emit SetBotSpecialPermissions(address(creditManager), address(bot), 2);

        vm.prank(CONFIGURATOR);
        botList.setBotSpecialPermissions(address(creditManager), address(bot), 2);

        (uint192 permissions,, bool hasSpecialPermissions) =
            botList.getBotStatus(address(creditManager), address(creditAccount), address(bot));

        assertEq(permissions, 2, "Special permissions are incorrect");

        assertTrue(hasSpecialPermissions, "Special permissions status returned incorrectly");
    }
}
