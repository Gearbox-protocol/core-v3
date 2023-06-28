// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Balance} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";
import {BalancesLogic, BalanceWithMask} from "../../../libraries/BalancesLogic.sol";

import {TestHelper} from "../../lib/helper.sol";

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

        _setupTokenBalances(balances, length);

        bool expectedResult = true;
        for (uint256 i = 0; i < length; ++i) {
            if (expectedBalances[i] > balances[i]) {
                expectedResult = false;
                break;
            }
        }

        Balance[] memory expectedArray = new Balance[](length);
        for (uint256 i = 0; i < length; ++i) {
            expectedArray[i] = Balance({token: tokens[i], balance: expectedBalances[i]});
        }

        bool result = BalancesLogic.compareBalances(creditAccount, expectedArray);
        assertEq(result, expectedResult, "Incorrect result");
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

        _setupTokenBalances(balancesBefore, 16);

        BalanceWithMask[] memory forbiddenBalances = BalancesLogic.storeForbiddenBalances(
            creditAccount, enabledTokensMaskBefore, forbiddenTokensMask, _getTokenByMask
        );

        _setupTokenBalances(balancesAfter, 16);

        bool expectedResult = true;
        if ((enabledTokensMaskAfter & ~enabledTokensMaskBefore) & forbiddenTokensMask > 0) expectedResult = false;

        for (uint256 i = 0; i < 16; ++i) {
            uint256 tokenMask = 1 << i;
            if ((enabledTokensMaskAfter & forbiddenTokensMask & tokenMask > 0) && balancesAfter[i] > balancesBefore[i])
            {
                expectedResult = false;
                break;
            }
        }

        bool result = BalancesLogic.checkForbiddenBalances(
            creditAccount, enabledTokensMaskBefore, enabledTokensMaskAfter, forbiddenBalances, forbiddenTokensMask
        );
        assertEq(result, expectedResult, "Incorrect result");
    }

    function _getTokenByMask(uint256 mask) internal view returns (address) {
        return tokens[maskToIndex[mask]];
    }
}
