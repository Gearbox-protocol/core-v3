// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Balance} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";
import {BalancesLogic, BalanceWithMask} from "../../../libraries/BalancesLogic.sol";
import {BitMask} from "../../../libraries/BitMask.sol";
import {TestHelper} from "../../lib/helper.sol";
import {BalancesLogicCaller} from "./BalancesLogicCaller.sol";

import {BalanceLessThanMinimumDesiredException, ForbiddenTokensException} from "../../../interfaces/IExceptions.sol";

/// @title BalancesLogic test
/// @notice [BM]: Unit tests for BalancesLogic
contract BalancesLogicTest is TestHelper {
    address creditAccount;
    address[16] tokens;
    mapping(uint256 => uint256) maskToIndex;

    function _setupTokenBalances(uint128[16] calldata balances, uint256 length) internal {
        creditAccount = makeAddr("CREDIT_ACCOUNT");

        for (uint256 i = 0; i < length; ++i) {
            tokens[i] = makeAddr(string(abi.encodePacked("TOKEN", i)));
            maskToIndex[1 << i] = i;
            vm.mockCall(tokens[i], abi.encodeCall(IERC20.balanceOf, (creditAccount)), abi.encode(balances[i]));
        }
    }

    /// @notice U:[BLL-1]: storeBalances works correctly
    function test_BLL_01_storeBalances_works_correctly(
        uint128[16] calldata balances,
        uint128[16] calldata deltas,
        uint256 length
    ) public {
        vm.assume(length <= 16);

        _setupTokenBalances(balances, length);

        Balance[] memory deltaArray = new Balance[](length);

        for (uint256 i = 0; i < length; ++i) {
            deltaArray[i] = Balance({token: tokens[i], balance: deltas[i]});
        }

        Balance[] memory expectedBalances = BalancesLogic.storeBalances(creditAccount, deltaArray);

        assertEq(expectedBalances.length, deltaArray.length, "Wrong length array was returned");

        for (uint256 i = 0; i < length; ++i) {
            assertEq(expectedBalances[i].token, tokens[i]);

            assertEq(
                expectedBalances[i].balance, uint256(balances[i]) + uint256(deltas[i]), "Incorrect expected balance"
            );
        }
    }

    /// @notice U:[BLL-2]: compareBalances works correctly
    function test_BLL_02_compareBalances_works_correctly(
        uint128[16] calldata balances,
        uint128[16] calldata expectedBalances,
        uint256 length
    ) public {
        vm.assume(length <= 16);

        BalancesLogicCaller caller = new BalancesLogicCaller();

        _setupTokenBalances(balances, length);

        bool expectRevert;
        address exceptionToken;

        for (uint256 i = 0; i < length; ++i) {
            if (expectedBalances[i] > balances[i]) {
                expectRevert = true;
                exceptionToken = tokens[i];
                break;
            }
        }

        Balance[] memory expectedArray = new Balance[](length);

        for (uint256 i = 0; i < length; ++i) {
            expectedArray[i] = Balance({token: tokens[i], balance: expectedBalances[i]});
        }

        if (expectRevert) {
            vm.expectRevert(abi.encodeWithSelector(BalanceLessThanMinimumDesiredException.selector, exceptionToken));
        }

        caller.compareBalances(creditAccount, expectedArray);
    }

    function _getTokenByMask(uint256 mask) internal view returns (address) {
        return tokens[maskToIndex[mask]];
    }

    /// @notice U:[BLL-3]: storeForbiddenBalances works correctly
    function test_BLL_03_storeForbiddenBalances_works_correctly(
        uint128[16] calldata balances,
        uint256 enabledTokensMask,
        uint256 forbiddenTokensMask
    ) public {
        enabledTokensMask %= (2 ** 16);
        forbiddenTokensMask %= (2 ** 16);

        _setupTokenBalances(balances, 16);

        BalanceWithMask[] memory forbiddenBalances =
            BalancesLogic.storeForbiddenBalances(creditAccount, enabledTokensMask, forbiddenTokensMask, _getTokenByMask);

        uint256 j;

        for (uint256 i = 0; i < 16; ++i) {
            uint256 tokenMask = 1 << i;
            if (tokenMask & enabledTokensMask & forbiddenTokensMask > 0) {
                assertEq(forbiddenBalances[j].balance, balances[i], "Incorrect forbidden token balance");

                assertEq(forbiddenBalances[j].token, tokens[i], "Incorrect forbidden token address");

                assertEq(forbiddenBalances[j].tokenMask, tokenMask, "Incorrect forbidden token mask");
                ++j;
            }
        }
    }

    //     /// @dev Checks that no new forbidden tokens were enabled and that balances of existing forbidden tokens
    // ///      were not increased
    // /// @param creditAccount Credit Account to check
    // /// @param enabledTokensMaskBefore Mask of enabled tokens on the account before operations
    // /// @param enabledTokensMaskAfter Mask of enabled tokens on the account after operations
    // /// @param forbiddenBalances Array of balances of forbidden tokens (received from `storeForbiddenBalances`)
    // /// @param forbiddenTokenMask Mask of forbidden tokens
    // function checkForbiddenBalances(
    //     address creditAccount,
    //     uint256 enabledTokensMaskBefore,
    //     uint256 enabledTokensMaskAfter,
    //     BalanceWithMask[] memory forbiddenBalances,
    //     uint256 forbiddenTokenMask
    // ) internal view {
    //     uint256 forbiddenTokensOnAccount = enabledTokensMaskAfter & forbiddenTokenMask;
    //     if (forbiddenTokensOnAccount == 0) return;

    //     /// A diff between the forbidden tokens before and after is computed
    //     /// If there are forbidden tokens enabled during operations, the function would revert
    //     uint256 forbiddenTokensOnAccountBefore = enabledTokensMaskBefore & forbiddenTokenMask;
    //     if (forbiddenTokensOnAccount & ~forbiddenTokensOnAccountBefore != 0) revert ForbiddenTokensException();

    //     /// Then, the function checks that any remaining forbidden tokens didn't have their balances increased
    //     unchecked {
    //         uint256 len = forbiddenBalances.length;
    //         for (uint256 i = 0; i < len; ++i) {
    //             if (forbiddenTokensOnAccount & forbiddenBalances[i].tokenMask != 0) {
    //                 uint256 currentBalance = IERC20Helper.balanceOf(forbiddenBalances[i].token, creditAccount);
    //                 if (currentBalance > forbiddenBalances[i].balance) {
    //                     revert ForbiddenTokensException();
    //                 }
    //             }
    //         }
    //     }
    // }

    /// @notice U:[BLL-4]: checkForbiddenBalances works correctly
    function test_BLL_04_storeForbiddenBalances_works_correctly(
        uint128[16] calldata balancesBefore,
        uint128[16] calldata balancesAfter,
        uint256 enabledTokensMaskBefore,
        uint256 enabledTokensMaskAfter,
        uint256 forbiddenTokensMask
    ) public {
        enabledTokensMaskBefore %= (2 ** 16);
        enabledTokensMaskAfter %= (2 ** 16);
        forbiddenTokensMask %= (2 ** 16);

        BalancesLogicCaller caller = new BalancesLogicCaller();

        _setupTokenBalances(balancesBefore, 16);

        BalanceWithMask[] memory forbiddenBalances = BalancesLogic.storeForbiddenBalances(
            creditAccount, enabledTokensMaskBefore, forbiddenTokensMask, _getTokenByMask
        );

        _setupTokenBalances(balancesAfter, 16);

        bool shouldRevert;

        if ((enabledTokensMaskAfter & ~enabledTokensMaskBefore) & forbiddenTokensMask > 0) shouldRevert = true;

        for (uint256 i = 0; i < 16; ++i) {
            uint256 tokenMask = 1 << i;
            if ((enabledTokensMaskAfter & forbiddenTokensMask & tokenMask > 0) && balancesAfter[i] > balancesBefore[i])
            {
                shouldRevert = true;
                break;
            }
        }

        if (shouldRevert) {
            vm.expectRevert(ForbiddenTokensException.selector);
        }

        caller.checkForbiddenBalances(
            creditAccount, enabledTokensMaskBefore, enabledTokensMaskAfter, forbiddenBalances, forbiddenTokensMask
        );
    }
}