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
import {PriceFeedMock} from "../../mocks/oracles/PriceFeedMock.sol";

contract LiquidateCreditAccountIntegrationTest is IntegrationTestHelper, ICreditFacadeV3Events {
    function _makeCreditAccount() internal returns (address) {
        uint256 debtAmount = DAI_ACCOUNT_AMOUNT;
        uint256 bufferedDebtAmount = 11 * debtAmount / 10;
        uint256 collateralAmount = priceOracle.convert(
            bufferedDebtAmount * PERCENTAGE_FACTOR / creditManager.liquidationThresholds(weth), underlying, weth
        );

        tokenTestSuite.mint(weth, USER, collateralAmount);
        tokenTestSuite.approve(weth, USER, address(creditManager));

        vm.prank(USER);
        return creditFacade.openCreditAccount(
            USER,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (debtAmount))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (underlying, debtAmount, USER))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (weth, collateralAmount))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.updateQuota, (weth, int96(uint96(bufferedDebtAmount)), 0)
                    )
                })
            ),
            0
        );
    }

    /// @dev I:[LCA-1]: liquidateCreditAccount reverts if borrower has no account
    function test_I_LCA_01_liquidateCreditAccount_reverts_if_credit_account_not_exists() public creditTest {
        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.liquidateCreditAccount(DUMB_ADDRESS, DUMB_ADDRESS, MultiCallBuilder.build());
    }

    /// @dev I:[LCA-2]: liquidateCreditAccount reverts if hf > 1
    function test_I_LCA_02_liquidateCreditAccount_reverts_if_hf_is_greater_than_1() public creditTest {
        address creditAccount = _makeCreditAccount();

        vm.expectRevert(CreditAccountNotLiquidatableException.selector);
        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, LIQUIDATOR, MultiCallBuilder.build());
    }

    /// @dev I:[LCA-3]: liquidateCreditAccount executes needed calls
    function test_I_LCA_03_liquidateCreditAccount_executes_needed_calls() public withAdapterMock creditTest {
        address creditAccount = _makeCreditAccount();
        _makeAccountsLiquidatable();

        uint256 collateralAmount = tokenTestSuite.balanceOf(weth, creditAccount);
        (,, uint16 liquidationDiscount,,) = creditManager.fees();
        uint256 repaidAmount =
            priceOracle.convert(collateralAmount, weth, underlying) * liquidationDiscount / PERCENTAGE_FACTOR;

        tokenTestSuite.mint(underlying, LIQUIDATOR, repaidAmount);
        tokenTestSuite.approve(underlying, LIQUIDATOR, address(creditManager), repaidAmount);

        PriceUpdate[] memory priceUpdates;
        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();
        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.onDemandPriceUpdates, (priceUpdates))
            }),
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, ())}),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, repaidAmount))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (weth, collateralAmount, FRIEND))
            })
        );

        vm.expectCall(address(priceOracle), abi.encodeCall(IPriceOracleV3.updatePrices, (priceUpdates)));

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.calcDebtAndCollateral, (creditAccount, CollateralCalcTask.DEBT_COLLATERAL))
        );

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (creditAccount)));

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.execute, (DUMB_CALLDATA)));

        vm.expectCall(address(targetMock), DUMB_CALLDATA);

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (address(1))));

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.addCollateral, (LIQUIDATOR, creditAccount, underlying, repaidAmount))
        );

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.withdrawCollateral, (creditAccount, weth, collateralAmount, FRIEND))
        );

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, calls);
    }

    /// @dev I:[LCA-4]: Borrowing is prohibited after a liquidation with loss
    function test_I_LCA_04_liquidateCreditAccount_prohibits_borrowing_on_loss() public withAdapterMock creditTest {
        address creditAccount = _makeCreditAccount();
        _makeAccountsLiquidatable();

        assertGt(creditFacade.maxDebtPerBlockMultiplier(), 0, "SETUP: Increase debt is already enabled");

        address priceFeed = priceOracle.priceFeeds(weth);
        PriceFeedMock(priceFeed).setPrice(PriceFeedMock(priceFeed).price() / 2);

        uint256 collateralAmount = tokenTestSuite.balanceOf(weth, creditAccount);
        (,, uint16 liquidationDiscount,,) = creditManager.fees();
        uint256 repaidAmount =
            priceOracle.convert(collateralAmount, weth, underlying) * liquidationDiscount / PERCENTAGE_FACTOR;

        tokenTestSuite.mint(underlying, LIQUIDATOR, repaidAmount);
        tokenTestSuite.approve(underlying, LIQUIDATOR, address(creditManager), repaidAmount);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, repaidAmount))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (weth, collateralAmount, FRIEND))
            })
        );

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, calls);

        assertEq(creditFacade.maxDebtPerBlockMultiplier(), 0, "Increase debt wasn't forbidden after loss");
    }

    /// @dev I:[LCA-6]: liquidateCreditAccount reverts on internal call in multicall on closure
    function test_I_LCA_06_liquidateCreditAccount_reverts_on_internal_call_in_multicall_on_closure()
        public
        creditTest
    {
        address creditAccount = _makeCreditAccount();
        _makeAccountsLiquidatable();

        /// TODO: Add all cases with different permissions!
        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            })
        );

        vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, INCREASE_DEBT_PERMISSION));
        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, calls);
    }
}
