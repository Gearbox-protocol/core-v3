// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {
    ICreditManagerV3,
    ICreditManagerV3Events,
    ManageDebtAction,
    BOT_PERMISSIONS_SET_FLAG
} from "../../../interfaces/ICreditManagerV3.sol";
import "../../../interfaces/ICreditFacadeV3.sol";
import {MultiCallBuilder} from "../../lib/MultiCallBuilder.sol";

// TESTS
import "../../lib/constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import {IntegrationTestHelper} from "../../helpers/IntegrationTestHelper.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

contract ManegDebtIntegrationTest is IntegrationTestHelper, ICreditFacadeV3Events {
    /// @dev I:[MD-1]: increaseDebt executes function as expected
    function test_I_MD_01_increaseDebt_executes_actions_as_expected() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();
        vm.roll(block.number + 1);

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.manageDebt, (creditAccount, 512, 1, ManageDebtAction.INCREASE_DEBT))
        );

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 1, new uint256[](0), PERCENTAGE_FACTOR, false)
            )
        );

        vm.expectEmit(true, false, false, true);
        emit IncreaseDebt(creditAccount, 512);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (512))
                })
            )
        );
    }

    /// @dev I:[MD-2]: increaseDebt revets if more than block limit
    function test_I_MD_02_increaseDebt_revets_if_more_than_block_limit() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();
        vm.roll(block.number + 1);

        uint8 maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();
        (, uint128 maxDebt) = creditFacade.debtLimits();

        vm.expectRevert(BorrowedBlockLimitException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.increaseDebt, (maxDebt * maxDebtPerBlockMultiplier + 1)
                        )
                })
            )
        );
    }

    /// @dev I:[MD-3]: increaseDebt revets if more than maxDebt
    function test_I_MD_03_increaseDebt_revets_if_more_than_block_limit() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();
        vm.roll(block.number + 1);

        (, uint128 maxDebt) = creditFacade.debtLimits();

        uint256 amount = maxDebt - DAI_ACCOUNT_AMOUNT + 1;

        tokenTestSuite.mint(Tokens.DAI, address(pool), amount);

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (amount))
                })
            )
        );
    }

    /// @dev I:[MD-4]: increaseDebt revets isIncreaseDebtForbidden is enabled
    function test_I_MD_04_increaseDebt_revets_isIncreaseDebtForbidden_is_enabled() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();
        vm.roll(block.number + 1);

        vm.prank(CONFIGURATOR);
        creditConfigurator.forbidBorrowing();

        vm.expectRevert(BorrowedBlockLimitException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (1))
                })
            )
        );
    }

    /// @dev I:[MD-5]: increaseDebt reverts if there is a forbidden token on account
    function test_I_MD_05_increaseDebt_reverts_with_forbidden_tokens() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();
        vm.roll(block.number + 1);

        address link = tokenTestSuite.addressOf(Tokens.LINK);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.enableToken, (link))
                })
            )
        );

        vm.prank(CONFIGURATOR);
        creditConfigurator.forbidToken(link);

        vm.expectRevert(ForbiddenTokensException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (1))
                })
            )
        );
    }

    /// @dev I:[MD-6]: decreaseDebt executes function as expected
    function test_I_MD_06_decreaseDebt_executes_actions_as_expected() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();
        vm.roll(block.number + 1);

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.manageDebt, (creditAccount, 512, 1, ManageDebtAction.DECREASE_DEBT))
        );

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 1, new uint256[](0), PERCENTAGE_FACTOR, false)
            )
        );

        vm.expectEmit(true, false, false, true);
        emit DecreaseDebt(creditAccount, 512);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (512))
                })
            )
        );
    }

    /// @dev I:[MD-7]:decreaseDebt revets if less than minDebt
    function test_I_MD_07_decreaseDebt_revets_if_less_than_minDebt() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();
        vm.roll(block.number + 1);

        (uint128 minDebt,) = creditFacade.debtLimits();

        uint256 amount = DAI_ACCOUNT_AMOUNT - minDebt + 1;

        tokenTestSuite.mint(Tokens.DAI, address(pool), amount);

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (amount))
                })
            )
        );
    }

    /// @dev I:[MD-8]: manageDebt correctly increases debt
    function test_I_MD_08_manageDebt_correctly_increases_debt(uint120 amount) public creditTest {
        tokenTestSuite.mint(Tokens.DAI, INITIAL_LP, amount);

        vm.assume(amount > 1);

        vm.prank(INITIAL_LP);
        pool.deposit(amount, INITIAL_LP);

        vm.prank(CONFIGURATOR);
        pool.setCreditManagerDebtLimit(address(creditManager), type(uint256).max);

        // (uint256 debt, uint256 cumulativeIndexLastUpdate, address creditAccount) = _openCreditAccount();

        // pool.setCumulativeIndexNow(cumulativeIndexLastUpdate * 2);

        vm.warp(block.timestamp + 365 days);

        // uint256 expectedNewCulumativeIndex =
        //     (2 * cumulativeIndexLastUpdate * (debt + amount)) / (2 * debt + amount);

        // uint256 moreDebt = amount / 2;

        // (uint256 newBorrowedAmount,,) =
        //     creditManager.manageDebt(creditAccount, moreDebt, 1, ManageDebtAction.INCREASE_DEBT);

        // assertEq(newBorrowedAmount, debt + moreDebt, "Incorrect returned newBorrowedAmount");

        // assertLe(
        //     (ICreditAccount(creditAccount).cumulativeIndexLastUpdate() * (10 ** 6)) / expectedNewCulumativeIndex,
        //     10 ** 6,
        //     "Incorrect cumulative index"
        // );

        // (uint256 debt,,,,,,,) = creditManager.creditAccountInfo(creditAccount);
        // assertEq(debt, newBorrowedAmount, "Incorrect debt");

        // expectBalance(Tokens.DAI, creditAccount, newBorrowedAmount, "Incorrect balance on credit account");

        // assertEq(pool.lendAmount(), amount, "Incorrect lend amount");

        // assertEq(pool.lendAccount(), creditAccount, "Incorrect lend account");
    }

    /// @dev I:[MD-9]: manageDebt correctly decreases debt
    function test_I_MD_09_manageDebt_correctly_decreases_debt(uint128 amount) public creditTest {
        // tokenTestSuite.mint(Tokens.DAI, address(pool), (uint256(type(uint128).max) * 14) / 10);

        // (uint256 debt, uint256 cumulativeIndexLastUpdate, uint256 cumulativeIndexNow, address creditAccount) =
        //     cft.openCreditAccount((uint256(type(uint128).max) * 14) / 10);

        // (,, uint256 totalDebt) = creditManager.calcAccruedInterestAndFees(creditAccount);

        // uint256 expectedInterestAndFees;
        // uint256 expectedBorrowAmount;
        // if (amount >= totalDebt - debt) {
        //     expectedInterestAndFees = 0;
        //     expectedBorrowAmount = totalDebt - amount;
        // } else {
        //     expectedInterestAndFees = totalDebt - debt - amount;
        //     expectedBorrowAmount = debt;
        // }

        // (uint256 newBorrowedAmount,) =
        //     creditManager.manageDebt(creditAccount, amount, 1, ManageDebtAction.DECREASE_DEBT);

        // assertEq(newBorrowedAmount, expectedBorrowAmount, "Incorrect returned newBorrowedAmount");

        // if (amount >= totalDebt - debt) {
        //     (,, uint256 newTotalDebt) = creditManager.calcAccruedInterestAndFees(creditAccount);

        //     assertEq(newTotalDebt, newBorrowedAmount, "Incorrect new interest");
        // } else {
        //     (,, uint256 newTotalDebt) = creditManager.calcAccruedInterestAndFees(creditAccount);

        //     assertLt(
        //         (RAY * (newTotalDebt - newBorrowedAmount)) / expectedInterestAndFees - RAY,
        //         10000,
        //         "Incorrect new interest"
        //     );
        // }
        // uint256 cumulativeIndexLastUpdateAfter;
        // {
        //     uint256 debt;
        //     (debt, cumulativeIndexLastUpdateAfter,,,,) = creditManager.creditAccountInfo(creditAccount);

        //     assertEq(debt, newBorrowedAmount, "Incorrect debt");
        // }

        // expectBalance(Tokens.DAI, creditAccount, debt - amount, "Incorrect balance on credit account");

        // if (amount >= totalDebt - debt) {
        //     assertEq(cumulativeIndexLastUpdateAfter, cumulativeIndexNow, "Incorrect cumulativeIndexLastUpdate");
        // } else {
        //     CreditManagerTestInternal cmi = new CreditManagerTestInternal(
        //         creditManager.pool(), address(withdrawalManager)
        //     );

        //     {
        //         (uint256 feeInterest,,,,) = creditManager.fees();
        //         amount = uint128((uint256(amount) * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest));
        //     }

        //     assertEq(
        //         cumulativeIndexLastUpdateAfter,
        //         cmi.calcNewCumulativeIndex(debt, amount, cumulativeIndexNow, cumulativeIndexLastUpdate, false),
        //         "Incorrect cumulativeIndexLastUpdate"
        //     );
        // }
    }
}
