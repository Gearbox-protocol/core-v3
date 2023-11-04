// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../../../interfaces/IAddressProviderV3.sol";

import {BotListV3} from "../../../core/BotListV3.sol";
import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";

import {ICreditAccountBase} from "../../../interfaces/ICreditAccountV3.sol";
import {SECONDS_PER_YEAR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {
    ICreditManagerV3,
    ICreditManagerV3Events,
    ManageDebtAction,
    BOT_PERMISSIONS_SET_FLAG
} from "../../../interfaces/ICreditManagerV3.sol";

import "../../../interfaces/ICreditFacadeV3.sol";

import {MultiCallBuilder} from "../../lib/MultiCallBuilder.sol";

// DATA

// CONSTANTS

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// TESTS

import "../../lib/constants.sol";

import {IntegrationTestHelper} from "../../helpers/IntegrationTestHelper.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// MOCKS
import {AdapterMock} from "../../mocks/core/AdapterMock.sol";
import {PriceFeedMock} from "../../mocks/oracles/PriceFeedMock.sol";
import {GeneralMock} from "../../mocks/GeneralMock.sol";

// SUITES

import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

import {IPoolV3} from "../../../interfaces/IPoolV3.sol";

import "forge-std/console.sol";

uint256 constant WETH_TEST_AMOUNT = 5 * WAD;
uint16 constant REFERRAL_CODE = 23;

contract CloseCreditAccountIntegrationTest is IntegrationTestHelper, ICreditFacadeV3Events {
    /// @dev I:[CCA-1]: closeCreditAccount reverts if borrower has no account
    function test_I_CCA_01_closeCreditAccount_reverts_if_credit_account_does_not_exist() public creditTest {
        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.closeCreditAccount(DUMB_ADDRESS, MultiCallBuilder.build());

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.closeCreditAccount(
            DUMB_ADDRESS,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            )
        );

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.liquidateCreditAccount(DUMB_ADDRESS, DUMB_ADDRESS, MultiCallBuilder.build());

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.multicall(
            DUMB_ADDRESS,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            )
        );
    }

    /// @dev I:[CCA-2]: closeCreditAccount reverts if debt is not repaid
    function test_I_CCA_02_closeCreditAccount_reverts_if_debt_is_not_repaid() public creditTest {
        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT / 2)
                    )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        vm.roll(block.number + 1);

        // debt not repaid at all
        vm.expectRevert(CloseAccountWithNonZeroDebtException.selector);
        vm.prank(USER);
        creditFacade.closeCreditAccount(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.disableToken, (underlying))
                })
            )
        );

        // debt partially repaid
        vm.expectRevert(CloseAccountWithNonZeroDebtException.selector);
        vm.prank(USER);
        creditFacade.closeCreditAccount(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (DAI_ACCOUNT_AMOUNT / 2))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.disableToken, (underlying))
                })
            )
        );
    }

    /// @dev I:[CCA-3]: closeCreditAccount correctly wraps ETH
    function test_I_CCA_03_closeCreditAccount_correctly_wraps_ETH() public creditTest {
        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, MultiCallBuilder.build(), 0);

        vm.roll(block.number + 1);

        _prepareForWETHTest();
        vm.prank(USER);
        creditFacade.closeCreditAccount{value: WETH_TEST_AMOUNT}(creditAccount, MultiCallBuilder.build());
        _checkForWETHTest();
    }

    /// @dev I:[CCA-4]: closeCreditAccount runs operations in correct order
    function test_I_CCA_04_closeCreditAccount_runs_operations_in_correct_order() public withAdapterMock creditTest {
        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, MultiCallBuilder.build(), 0);

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        address bot = address(new GeneralMock());

        vm.prank(USER);
        creditFacade.setBotPermissions({
            creditAccount: creditAccount,
            bot: bot,
            permissions: uint192(ADD_COLLATERAL_PERMISSION)
        });

        // LIST OF EXPECTED CALLS

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (creditAccount)));

        vm.expectEmit(true, false, false, false);
        emit StartMultiCall({creditAccount: creditAccount, caller: USER});

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.execute, (DUMB_CALLDATA)));

        vm.expectEmit(true, false, false, true);
        emit Execute(creditAccount, address(targetMock));

        vm.expectCall(creditAccount, abi.encodeCall(ICreditAccountBase.execute, (address(targetMock), DUMB_CALLDATA)));

        vm.expectCall(address(targetMock), DUMB_CALLDATA);

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (address(1))));

        vm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        vm.expectCall(
            address(botList), abi.encodeCall(BotListV3.eraseAllBotPermissions, (address(creditManager), creditAccount))
        );

        vm.expectEmit(true, true, false, false);
        emit CloseCreditAccount(creditAccount, USER);

        // increase block number, cause it's forbidden to close ca in the same block
        vm.roll(block.number + 1);

        vm.prank(USER);
        creditFacade.closeCreditAccount(creditAccount, calls);

        assertEq0(targetMock.callData(), DUMB_CALLDATA, "Incorrect calldata");
    }

    /// @dev I:[CCA-5]: closeCreditAccount returns account to the factory and removes owner
    function test_I_CCA_05_closeCreditAccount_returns_account_to_the_factory_and_removes_owner()
        public
        withAccountFactoryV1
        creditTest
    {
        address daiToken = tokenTestSuite.addressOf(Tokens.DAI);
        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (daiToken, DAI_ACCOUNT_AMOUNT / 2))
            })
        );

        // Existing address case
        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        assertTrue(creditAccount != accountFactory.tail(), "credit account is already in tail!");

        // Increase block number cause it's forbidden to close credit account in the same block
        vm.roll(block.number + 1);

        vm.prank(USER);
        creditFacade.closeCreditAccount(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (type(uint256).max))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.withdrawCollateral, (daiToken, type(uint256).max, USER)
                        )
                })
            )
        );

        assertEq(creditAccount, accountFactory.tail(), "credit account is not in accountFactory tail!");

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditManager.getBorrowerOrRevert(creditAccount);
    }
}
