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
        creditFacade.closeCreditAccount(DUMB_ADDRESS, FRIEND, 0, false, MultiCallBuilder.build());

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.closeCreditAccount(
            DUMB_ADDRESS,
            FRIEND,
            0,
            false,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            )
        );

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.liquidateCreditAccount(DUMB_ADDRESS, DUMB_ADDRESS, 0, false, MultiCallBuilder.build());

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
        creditFacade.closeCreditAccount(creditAccount, USER, 1, false, MultiCallBuilder.build());

        // debt partially repaid
        vm.expectRevert(CloseAccountWithNonZeroDebtException.selector);
        vm.prank(USER);
        creditFacade.closeCreditAccount(
            creditAccount,
            USER,
            1,
            false,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (DAI_ACCOUNT_AMOUNT / 2))
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
        creditFacade.closeCreditAccount{value: WETH_TEST_AMOUNT}(
            creditAccount, USER, 0, false, MultiCallBuilder.build()
        );
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
        emit CloseCreditAccount(creditAccount, USER, FRIEND);

        // increase block number, cause it's forbidden to close ca in the same block
        vm.roll(block.number + 1);

        vm.prank(USER);
        creditFacade.closeCreditAccount(creditAccount, FRIEND, 10, false, calls);

        assertEq0(targetMock.callData(), DUMB_CALLDATA, "Incorrect calldata");
    }

    /// @dev I:[CCA-5]: closeCreditAccount returns account to the factory and removes owner
    function test_I_CCA_05_closeCreditAccount_returns_account_to_the_factory_and_removes_owner()
        public
        withAccountFactoryV1
        creditTest
    {
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

        // Existing address case
        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        assertTrue(creditAccount != accountFactory.tail(), "credit account is already in tail!");

        // Increase block number cause it's forbidden to close credit account in the same block
        vm.roll(block.number + 1);

        vm.prank(USER);
        creditFacade.closeCreditAccount(
            creditAccount,
            USER,
            1,
            false,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (type(uint256).max))
                })
            )
        );

        assertEq(creditAccount, accountFactory.tail(), "credit account is not in accountFactory tail!");

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditManager.getBorrowerOrRevert(creditAccount);
    }

    /// @dev I:[CCA-6]: closeCreditAccount sends specified tokens
    function test_I_CCA_06_closeCreditAccount_sends_specified_tokens() public creditTest {
        address weth = tokenTestSuite.addressOf(Tokens.WETH);
        uint256 wethMask = creditManager.getTokenMaskOrRevert(weth);

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, MultiCallBuilder.build(), 0);

        tokenTestSuite.mint(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);
        tokenTestSuite.mint(Tokens.LINK, creditAccount, LINK_EXCHANGE_AMOUNT);

        vm.roll(block.number + 1);

        vm.prank(USER);
        creditFacade.closeCreditAccount({
            creditAccount: creditAccount,
            to: FRIEND,
            tokensToTransferMask: wethMask,
            convertToETH: false,
            calls: MultiCallBuilder.build()
        });

        expectBalance(Tokens.WETH, creditAccount, 1);
        expectBalance(Tokens.LINK, creditAccount, LINK_EXCHANGE_AMOUNT);
        expectBalance(Tokens.WETH, FRIEND, WETH_EXCHANGE_AMOUNT - 1);
    }

    /// @dev I:[CCA-7]: closeCreditAccount sends WETH to withdrawal manager
    function test_I_CCA_07_closeCreditAccount_converts_weth_to_eth() public creditTest {
        address weth = tokenTestSuite.addressOf(Tokens.WETH);
        uint256 wethMask = creditManager.getTokenMaskOrRevert(weth);

        vm.prank(CONFIGURATOR);
        withdrawalManager.addCreditManager(address(creditManager));

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, MultiCallBuilder.build(), 0);
        tokenTestSuite.mint(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);

        vm.roll(block.number + 1);

        vm.prank(USER);
        creditFacade.closeCreditAccount({
            creditAccount: creditAccount,
            to: FRIEND,
            tokensToTransferMask: wethMask,
            convertToETH: true,
            calls: MultiCallBuilder.build()
        });

        expectBalance(Tokens.WETH, creditAccount, 1);
        assertEq(FRIEND.balance, WETH_EXCHANGE_AMOUNT - 2);
    }
}
