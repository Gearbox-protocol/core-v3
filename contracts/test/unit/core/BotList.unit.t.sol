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

        invalidCF = address(new InvalidCFMock(creditManager));

        vm.mockCall(
            creditManager, abi.encodeWithSelector(ICreditManagerV3.creditFacade.selector), abi.encode(creditFacade)
        );

        vm.mockCall(
            creditFacade, abi.encodeWithSelector(ICreditFacadeV3.creditManager.selector), abi.encode(creditManager)
        );

        vm.mockCall(
            creditAccount, abi.encodeWithSelector(ICreditAccountBase.creditManager.selector), abi.encode(creditManager)
        );

        vm.prank(CONFIGURATOR);
        addressProvider.addCreditManager(creditManager);

        vm.prank(CONFIGURATOR);
        botList.setCreditManagerApprovedStatus(creditManager, true);
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev [BL-1]: constructor sets correct values
    function test_U_BL_01_constructor_sets_correct_values() public {
        assertEq(botList.treasury(), addressProvider.getAddressOrRevert(AP_TREASURY, 0), "Treasury contract incorrect");
        assertEq(botList.weth(), address(weth), "WETH incorrect");
        assertEq(botList.paymentFee(), 0, "Initial payment fee incorrect");
        assertEq(botList.collectedPaymentFees(), 0, "Initial collected payment fees incorrect");
    }

    /// @dev [BL-2]: setPaymentFee works correctly
    function test_U_BL_02_setPaymentFee_works_correctly() public {
        vm.expectRevert(CallerNotConfiguratorException.selector);
        botList.setPaymentFee(1);

        vm.expectEmit(false, false, false, true);
        emit SetPaymentFee(15);

        vm.prank(CONFIGURATOR);
        botList.setPaymentFee(15);

        assertEq(botList.paymentFee(), 15, "Payment fee incorrect");
    }

    /// @dev [BL-3]: setBotPermissions works correctly
    function test_U_BL_03_setBotPermissions_works_correctly() public {
        vm.expectRevert(CallerNotCreditFacadeException.selector);
        vm.prank(invalidCF);
        botList.setBotPermissions({
            bot: address(bot),
            creditManager: creditManager,
            creditAccount: creditAccount,
            permissions: type(uint192).max,
            totalFundingAllowance: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, DUMB_ADDRESS));
        vm.prank(creditFacade);
        botList.setBotPermissions({
            bot: DUMB_ADDRESS,
            creditManager: creditManager,
            creditAccount: creditAccount,
            permissions: type(uint192).max,
            totalFundingAllowance: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        vm.prank(CONFIGURATOR);
        botList.setBotForbiddenStatus(address(bot), true);

        vm.expectRevert(InvalidBotException.selector);
        vm.prank(creditFacade);
        botList.setBotPermissions({
            bot: address(bot),
            creditManager: creditManager,
            creditAccount: creditAccount,
            permissions: type(uint192).max,
            totalFundingAllowance: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        vm.prank(CONFIGURATOR);
        botList.setBotForbiddenStatus(address(bot), false);

        vm.prank(CONFIGURATOR);
        botList.setBotSpecialPermissions(address(bot), creditManager, 1);

        vm.expectRevert(InvalidBotException.selector);
        vm.prank(creditFacade);
        botList.setBotPermissions({
            bot: address(bot),
            creditManager: creditManager,
            creditAccount: creditAccount,
            permissions: type(uint192).max,
            totalFundingAllowance: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        vm.prank(CONFIGURATOR);
        botList.setBotSpecialPermissions(address(bot), creditManager, 0);

        vm.expectEmit(true, true, true, true);
        emit SetBotPermissions(address(bot), creditManager, creditAccount, 1, uint72(1 ether), uint72(1 ether / 10));

        vm.prank(creditFacade);
        uint256 activeBotsRemaining = botList.setBotPermissions({
            bot: address(bot),
            creditManager: creditManager,
            creditAccount: creditAccount,
            permissions: 1,
            totalFundingAllowance: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        assertEq(activeBotsRemaining, 1, "Incorrect number of bots returned");

        assertEq(botList.botPermissions(address(bot), creditManager, creditAccount), 1, "Bot permissions were not set");

        BotFunding memory bf = botList.botFunding(address(bot), creditManager, creditAccount);

        address[] memory bots = botList.activeBots(creditManager, creditAccount);

        assertEq(bots.length, 1, "Incorrect active bots array length");

        assertEq(bots[0], address(bot), "Incorrect address added to active bots list");

        assertEq(bf.totalFundingAllowance, 1 ether, "Incorrect total funding allowance");

        assertEq(bf.maxWeeklyAllowance, 1 ether / 10, "Incorrect max weekly allowance");

        assertEq(bf.remainingWeeklyAllowance, 1 ether / 10, "Incorrect remaining weekly allowance");

        assertEq(bf.lastAllowanceUpdate, block.timestamp, "Incorrect allowance update timestamp");

        vm.prank(creditFacade);
        activeBotsRemaining = botList.setBotPermissions({
            bot: address(bot),
            creditManager: creditManager,
            creditAccount: creditAccount,
            permissions: 2,
            totalFundingAllowance: uint72(2 ether),
            weeklyFundingAllowance: uint72(2 ether / 10)
        });

        bf = botList.botFunding(address(bot), creditManager, creditAccount);

        assertEq(activeBotsRemaining, 1, "Incorrect number of bots returned");

        assertEq(botList.botPermissions(address(bot), creditManager, creditAccount), 2, "Bot permissions were not set");

        assertEq(bf.totalFundingAllowance, 2 ether, "Incorrect total funding allowance");

        assertEq(bf.maxWeeklyAllowance, 2 ether / 10, "Incorrect max weekly allowance");

        assertEq(bf.remainingWeeklyAllowance, 2 ether / 10, "Incorrect remaining weekly allowance");

        assertEq(bf.lastAllowanceUpdate, block.timestamp, "Incorrect allowance update timestamp");

        bots = botList.activeBots(creditManager, creditAccount);

        assertEq(bots.length, 1, "Incorrect active bots array length");

        assertEq(bots[0], address(bot), "Incorrect address added to active bots list");

        vm.prank(CONFIGURATOR);
        botList.setBotForbiddenStatus(address(bot), true);

        vm.expectEmit(true, true, true, false);
        emit EraseBot(address(bot), creditManager, creditAccount);

        vm.prank(creditFacade);
        activeBotsRemaining = botList.setBotPermissions({
            bot: address(bot),
            creditManager: creditManager,
            creditAccount: creditAccount,
            permissions: 0,
            totalFundingAllowance: 0,
            weeklyFundingAllowance: 0
        });

        bf = botList.botFunding(address(bot), creditManager, creditAccount);

        assertEq(activeBotsRemaining, 0, "Incorrect number of bots returned");

        assertEq(botList.botPermissions(address(bot), creditManager, creditAccount), 0, "Bot permissions were not set");

        assertEq(bf.totalFundingAllowance, 0, "Incorrect total funding allowance");

        assertEq(bf.maxWeeklyAllowance, 0, "Incorrect max weekly allowance");

        assertEq(bf.remainingWeeklyAllowance, 0, "Incorrect remaining weekly allowance");

        assertEq(bf.lastAllowanceUpdate, 0, "Incorrect allowance update timestamp");

        bots = botList.activeBots(creditManager, creditAccount);

        assertEq(bots.length, 0, "Incorrect active bots array length");
    }

    /// @dev [BL-4]: deposit and withdraw work correctly
    function test_U_BL_04_deposit_withdraw_work_correctly() public {
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

        vm.expectRevert(AmountCantBeZeroException.selector);
        vm.prank(USER);
        botList.withdraw(0);

        uint256 userBalance = botList.balanceOf(USER);

        vm.expectRevert(InsufficientBalanceException.selector);
        vm.prank(USER);
        botList.withdraw(userBalance + 1);

        assertEq(botList.balanceOf(USER), 2 ether, "User's bot funding wallet has incorrect balance");

        vm.expectEmit(true, false, false, true);
        emit Withdraw(USER, 1 ether / 2);

        vm.prank(USER);
        botList.withdraw(1 ether / 2);

        assertEq(botList.balanceOf(USER), 3 ether / 2, "User's bot funding wallet has incorrect balance");

        assertEq(USER.balance, 85 ether / 10, "User's balance is incorrect");
    }

    /// @dev [BL-5]: payBot works correctly
    function test_U_BL_05_payBot_works_correctly() public {
        vm.prank(CONFIGURATOR);
        botList.setPaymentFee(5000);

        vm.deal(USER, 10 ether);

        vm.prank(USER);
        botList.deposit{value: 2 ether}();

        vm.prank(creditFacade);
        botList.setBotPermissions({
            bot: address(bot),
            creditManager: creditManager,
            creditAccount: creditAccount,
            permissions: 1,
            totalFundingAllowance: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        vm.prank(invalidCF);
        botList.payBot({
            bot: address(bot),
            creditManager: creditManager,
            creditAccount: creditAccount,
            payer: USER,
            paymentAmount: uint72(1 ether / 20)
        });

        vm.expectEmit(true, true, true, true);
        emit PayBot(address(bot), creditManager, creditAccount, USER, uint72(1 ether / 20), uint72(1 ether / 40));

        vm.prank(creditFacade);
        botList.payBot({
            bot: address(bot),
            creditManager: creditManager,
            creditAccount: creditAccount,
            payer: USER,
            paymentAmount: uint72(1 ether / 20)
        });

        BotFunding memory bf = botList.botFunding(address(bot), creditManager, creditAccount);

        assertEq(
            bf.totalFundingAllowance, 1 ether - (1 ether / 20) - (1 ether / 40), "Bot total funding allowance incorrect"
        );

        assertEq(
            bf.remainingWeeklyAllowance,
            (1 ether / 10) - (1 ether / 20) - (1 ether / 40),
            "Bot remaining weekly allowance incorrect"
        );

        assertEq(
            botList.balanceOf(USER),
            2 ether - (1 ether / 20) - (1 ether / 40),
            "User remaining funding balance incorrect"
        );

        assertEq(bf.lastAllowanceUpdate, block.timestamp - 1 days, "Allowance update timestamp incorrect");

        assertEq(weth.balanceOf(address(bot)), 1 ether / 20, "Bot was sent incorrect WETH amount");

        assertEq(
            botList.collectedPaymentFees(), 1 ether / 40, "Collected payment fees was increased with incorrect amount"
        );

        vm.warp(block.timestamp + 7 days);

        vm.prank(creditFacade);
        botList.payBot({
            bot: address(bot),
            creditManager: creditManager,
            creditAccount: creditAccount,
            payer: USER,
            paymentAmount: uint72(1 ether / 20)
        });

        bf = botList.botFunding(address(bot), creditManager, creditAccount);

        assertEq(
            bf.totalFundingAllowance, 1 ether - (2 ether / 20) - (2 ether / 40), "Bot total funding allowance incorrect"
        );

        assertEq(
            bf.remainingWeeklyAllowance,
            (1 ether / 10) - (1 ether / 20) - (1 ether / 40),
            "Bot remaining weekly allowance incorrect"
        );

        assertEq(bf.lastAllowanceUpdate, block.timestamp, "Allowance update timestamp incorrect");

        assertEq(
            botList.balanceOf(USER),
            2 ether - (2 ether / 20) - (2 ether / 40),
            "User remaining funding balance incorrect"
        );

        assertEq(weth.balanceOf(address(bot)), 2 ether / 20, "Bot was sent incorrect WETH amount");

        assertEq(botList.collectedPaymentFees(), 2 ether / 40, "CollectedPaymentFees was incorrectly chaged");

        vm.expectEmit(false, false, false, true);
        emit TransferCollectedPaymentFees(2 ether / 40);

        botList.transferCollectedPaymentFees();

        assertEq(botList.collectedPaymentFees(), 0, "CollectedPaymentFees was not zeroed");

        assertEq(
            weth.balanceOf(addressProvider.getTreasuryContract()), 2 ether / 40, "Treasury was sent incorrect amount"
        );
    }

    /// @dev [BL-6]: eraseAllBotPermissions works correctly
    function test_U_BL_06_eraseAllBotPermissions_works_correctly() public {
        vm.prank(creditFacade);
        botList.setBotPermissions({
            bot: address(bot),
            creditManager: creditManager,
            creditAccount: creditAccount,
            permissions: 1,
            totalFundingAllowance: uint72(1 ether),
            weeklyFundingAllowance: uint72(1 ether / 10)
        });

        address bot2 = address(new GeneralMock());

        vm.prank(creditFacade);
        uint256 activeBotsRemaining = botList.setBotPermissions({
            bot: address(bot2),
            creditManager: creditManager,
            creditAccount: creditAccount,
            permissions: 2,
            totalFundingAllowance: uint72(2 ether),
            weeklyFundingAllowance: uint72(2 ether / 10)
        });

        assertEq(activeBotsRemaining, 2, "Incorrect number of active bots");

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        vm.prank(invalidCF);
        botList.eraseAllBotPermissions(creditManager, creditAccount);

        // it starts removing bots from the end
        vm.expectEmit(true, true, true, false);
        emit EraseBot(address(bot2), creditManager, creditAccount);

        vm.expectEmit(true, true, true, false);
        emit EraseBot(address(bot), creditManager, creditAccount);

        vm.prank(creditFacade);
        botList.eraseAllBotPermissions(creditManager, creditAccount);

        assertEq(
            botList.botPermissions(address(bot), creditManager, creditAccount),
            0,
            "Permissions were not erased for bot 1"
        );

        assertEq(
            botList.botPermissions(address(bot2), creditManager, creditAccount),
            0,
            "Permissions were not erased for bot 2"
        );

        BotFunding memory bf = botList.botFunding(creditManager, creditAccount, address(bot));

        assertEq(bf.totalFundingAllowance, 0, "total funding allowance was not zeroed for bot 1");

        assertEq(bf.maxWeeklyAllowance, 0, "max weekly allowance was not zeroed for bot 1");

        assertEq(bf.remainingWeeklyAllowance, 0, "Remaining weekly allowance not zeroed for bot 1");

        bf = botList.botFunding(address(bot2), creditManager, creditAccount);

        assertEq(bf.totalFundingAllowance, 0, "total funding allowance was not zeroed for bot 2");

        assertEq(bf.maxWeeklyAllowance, 0, "max weekly allowance was not zeroed for bot 2");

        assertEq(bf.remainingWeeklyAllowance, 0, "Remaining weekly allowance not zeroed for bot 2");

        address[] memory activeBots = botList.activeBots(creditManager, creditAccount);

        assertEq(activeBots.length, 0, "Not all active bots were disabled");
    }

    /// @dev [BL-7]: setBotSpecialPermissions works correctly
    function test_U_BL_07_setBotSpecialPermissions_works_correctly() public {
        vm.expectRevert(CallerNotConfiguratorException.selector);
        botList.setBotSpecialPermissions(address(bot), creditManager, 2);

        vm.expectEmit(true, true, false, true);
        emit SetBotSpecialPermissions(address(bot), creditManager, 2);

        vm.prank(CONFIGURATOR);
        botList.setBotSpecialPermissions(address(bot), creditManager, 2);

        (uint192 permissions,, bool hasSpecialPermissions) =
            botList.getBotStatus(address(bot), creditManager, creditAccount);

        assertEq(permissions, 2, "Special permissions are incorrect");

        assertTrue(hasSpecialPermissions, "Special permissions status returned incorrectly");
    }

    /// @dev [BL-8]: payBot correctly reverts if payment bigger than allowances
    function test_U_BL_08_payBot_correctly_reverts_if_payment_bigger_than_allowances() public {
        uint72 limit = 1 ether;
        vm.prank(creditFacade);
        botList.setBotPermissions({
            bot: address(bot),
            creditManager: creditManager,
            creditAccount: creditAccount,
            permissions: 1,
            totalFundingAllowance: type(uint72).max,
            weeklyFundingAllowance: limit
        });

        vm.expectRevert(InsufficientWeeklyFundingAllowance.selector);
        vm.prank(creditFacade);
        botList.payBot({
            bot: address(bot),
            creditManager: creditManager,
            creditAccount: creditAccount,
            payer: USER,
            paymentAmount: limit + 1
        });

        vm.prank(creditFacade);
        botList.setBotPermissions({
            bot: address(bot),
            creditManager: creditManager,
            creditAccount: creditAccount,
            permissions: 1,
            totalFundingAllowance: limit,
            weeklyFundingAllowance: type(uint72).max
        });

        vm.expectRevert(InsufficientTotalFundingAllowance.selector);
        vm.prank(creditFacade);
        botList.payBot({
            bot: address(bot),
            creditManager: creditManager,
            creditAccount: creditAccount,
            payer: USER,
            paymentAmount: limit + 1
        });
    }
}
