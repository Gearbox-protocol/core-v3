// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";

import {BotListV3} from "../../../core/BotListV3.sol";

import {ICreditAccountV3} from "../../../interfaces/ICreditAccountV3.sol";

import {ICreditManagerV3, ManageDebtAction} from "../../../interfaces/ICreditManagerV3.sol";

import "../../../interfaces/ICreditFacadeV3.sol";

import {MultiCallBuilder} from "../../lib/MultiCallBuilder.sol";

// DATA

// CONSTANTS

import {PERCENTAGE_FACTOR} from "../../../libraries/Constants.sol";

// TESTS

import "../../lib/constants.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// MOCKS
import {AdapterMock} from "../../mocks/core/AdapterMock.sol";
import {BotMock} from "../../mocks/core/BotMock.sol";

// SUITES

import {IntegrationTestHelper} from "../../helpers/IntegrationTestHelper.sol";

uint256 constant WETH_TEST_AMOUNT = 5 * WAD;

/// @title CreditFacadeTest
/// @notice Designed for unit test purposes only
contract BotsIntegrationTest is IntegrationTestHelper {
    /// @dev I:[BOT-01]: botMulticall works correctly
    function test_I_BOT_01_botMulticall_works_correctly() public withAdapterMock creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        address bot = address(new BotMock());
        BotMock(bot).setRequiredPermissions(ALL_PERMISSIONS & ~SET_BOT_PERMISSIONS_PERMISSION);

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        vm.prank(address(creditFacade));
        botList.setBotPermissions(bot, creditAccount, ALL_PERMISSIONS & ~SET_BOT_PERMISSIONS_PERMISSION);

        vm.expectRevert(abi.encodeWithSelector(NotApprovedBotException.selector, (address(this))));
        creditFacade.botMulticall(
            creditAccount, MultiCallBuilder.build(MultiCall({target: address(adapterMock), callData: DUMB_CALLDATA}))
        );

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, ())})
        );

        _setBotPermissions(USER, creditAccount, bot, ALL_PERMISSIONS & ~SET_BOT_PERMISSIONS_PERMISSION);

        botList.getBotPermissions({creditAccount: creditAccount, bot: bot});

        vm.expectEmit(true, true, false, true);
        emit ICreditFacadeV3.StartMultiCall({creditAccount: creditAccount, caller: bot});

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (creditAccount)));

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.execute, (DUMB_CALLDATA)));

        vm.expectEmit(true, false, false, true);
        emit ICreditFacadeV3.Execute(creditAccount, address(targetMock));

        vm.expectCall(creditAccount, abi.encodeCall(ICreditAccountV3.execute, (address(targetMock), DUMB_CALLDATA)));

        vm.expectCall(address(targetMock), DUMB_CALLDATA);

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (address(1))));

        vm.expectEmit(false, false, false, true);
        emit ICreditFacadeV3.FinishMultiCall();

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 1, new uint256[](0), PERCENTAGE_FACTOR, false)
            )
        );

        vm.prank(bot);
        creditFacade.botMulticall(creditAccount, calls);

        vm.prank(CONFIGURATOR);
        botList.forbidBot(bot);

        vm.expectRevert(abi.encodeWithSelector(NotApprovedBotException.selector, (bot)));
        vm.prank(bot);
        creditFacade.botMulticall(creditAccount, calls);
    }

    function _setBotPermissions(address user, address creditAccount, address bot, uint192 permissions) internal {
        vm.prank(user);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall(
                    address(creditFacade),
                    abi.encodeCall(ICreditFacadeV3Multicall.setBotPermissions, (bot, permissions))
                )
            )
        );
    }
}
