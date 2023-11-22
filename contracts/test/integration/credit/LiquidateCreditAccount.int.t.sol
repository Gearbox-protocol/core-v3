// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

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

// TESTS
import "../../lib/constants.sol";
import {IntegrationTestHelper} from "../../helpers/IntegrationTestHelper.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// MOCKS
import {AdapterMock} from "../../mocks/core/AdapterMock.sol";

contract LiquidateCreditAccountIntegrationTest is IntegrationTestHelper, ICreditFacadeV3Events {
    /// @dev I:[LCA-1]: liquidateCreditAccount reverts if borrower has no account
    function test_I_LCA_01_liquidateCreditAccount_reverts_if_credit_account_not_exists() public creditTest {
        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.liquidateCreditAccount(DUMB_ADDRESS, DUMB_ADDRESS, MultiCallBuilder.build());
    }

    /// @dev I:[LCA-2]: liquidateCreditAccount reverts if hf > 1
    function test_I_LCA_2_liquidateCreditAccount_reverts_if_hf_is_greater_than_1() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        vm.expectRevert(CreditAccountNotLiquidatableException.selector);

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, LIQUIDATOR, MultiCallBuilder.build());
    }

    /// @dev I:[LCA-3]: liquidateCreditAccount executes needed calls and emits events
    function test_I_LCA_03_liquidateCreditAccount_executes_needed_calls_and_emits_events()
        public
        withAdapterMock
        creditTest
    {
        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        vm.prank(USER);
        creditFacade.setBotPermissions({
            creditAccount: creditAccount,
            bot: address(adapterMock),
            permissions: uint192(ADD_COLLATERAL_PERMISSION)
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
        emit LiquidateCreditAccount(creditAccount, LIQUIDATOR, FRIEND, 0);

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, calls);
    }

    /// @dev I:[LCA-4]: Borrowing is prohibited after a liquidation with loss
    function test_I_LCA_04_liquidateCreditAccount_prohibits_borrowing_on_loss() public withAdapterMock creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        uint8 maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();

        assertGt(maxDebtPerBlockMultiplier, 0, "SETUP: Increase debt is already enabled");

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        _makeAccountsLiquitable();

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, calls);

        maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();

        assertEq(maxDebtPerBlockMultiplier, 0, "Increase debt wasn't forbidden after loss");
    }

    /// @dev I:[LCA-5]: CreditFacade is paused after too much cumulative loss from liquidations
    function test_I_LCA_05_liquidateCreditAccount_pauses_CreditFacade_on_too_much_loss()
        public
        withAdapterMock
        creditTest
    {
        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxCumulativeLoss(1);

        (address creditAccount,) = _openTestCreditAccount();

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        _makeAccountsLiquitable();

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, calls);

        assertTrue(creditFacade.paused(), "Credit manager was not paused");
    }

    /// @dev I:[LCA-6]: liquidateCreditAccount reverts on internal call in multicall on closure
    function test_I_LCA_06_liquidateCreditAccount_reverts_on_internal_call_in_multicall_on_closure()
        public
        creditTest
    {
        /// TODO: Add all cases with different permissions!

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            })
        );

        (address creditAccount,) = _openTestCreditAccount();

        _makeAccountsLiquitable();
        vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, INCREASE_DEBT_PERMISSION));

        vm.prank(LIQUIDATOR);

        // It's used dumb calldata, cause all calls to creditFacade are forbidden
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, calls);
    }
}
