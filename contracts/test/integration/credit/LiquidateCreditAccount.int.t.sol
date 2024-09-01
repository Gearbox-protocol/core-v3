// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {ICreditAccountV3} from "../../../interfaces/ICreditAccountV3.sol";
import {
    CollateralCalcTask,
    ICreditManagerV3,
    ICreditManagerV3Events,
    ManageDebtAction
} from "../../../interfaces/ICreditManagerV3.sol";
import {IPriceOracleV3, PriceUpdate} from "../../../interfaces/IPriceOracleV3.sol";

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

        PriceUpdate[] memory priceUpdates;
        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.onDemandPriceUpdates, (priceUpdates))
            }),
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, ())})
        );

        _makeAccountsLiquitable();

        // EXPECTED STACK TRACE & EVENTS

        vm.expectCall(address(priceOracle), abi.encodeCall(IPriceOracleV3.updatePrices, (priceUpdates)));

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.calcDebtAndCollateral, (creditAccount, CollateralCalcTask.DEBT_COLLATERAL))
        );

        vm.expectEmit(true, false, false, false);
        emit StartMultiCall({creditAccount: creditAccount, caller: LIQUIDATOR});

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (creditAccount)));

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.execute, (DUMB_CALLDATA)));

        vm.expectCall(creditAccount, abi.encodeCall(ICreditAccountV3.execute, (address(targetMock), DUMB_CALLDATA)));

        vm.expectCall(address(targetMock), DUMB_CALLDATA);

        vm.expectEmit(true, false, false, false);
        emit Execute(creditAccount, address(targetMock));

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (address(1))));

        vm.expectEmit(false, false, false, false);
        emit FinishMultiCall();

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
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, ())})
        );

        _makeAccountsLiquitable();

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, calls);

        maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();

        assertEq(maxDebtPerBlockMultiplier, 0, "Increase debt wasn't forbidden after loss");
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
