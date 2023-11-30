// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Balance} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";
import {BalancesLogic, BalanceDelta, BalanceWithMask, Comparison} from "../../../libraries/BalancesLogic.sol";

import {TestHelper} from "../../lib/helper.sol";

/// @title Balances logic library unit test
/// @notice U:[BLL]: Unit tests for balances logic library
contract BalancesLogicUnitTest is TestHelper {
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

    /// @notice U:[BLL-1]: `checkBalance` works correctly
    function test_U_BLL_01_checkBalance_works_correctly(uint128[16] calldata balances, uint128 value, bool greater)
        public
    {
        _setupTokenBalances(balances, 1);

        bool result =
            BalancesLogic.checkBalance(creditAccount, tokens[0], value, greater ? Comparison.GREATER : Comparison.LESS);
        if (greater) {
            assertEq(result, balances[0] >= value);
        } else {
            assertEq(result, balances[0] <= value);
        }
    }

    /// @notice U:[BLL-2]: `storeBalances` with deltas works correctly
    function test_U_BLL_02_storeBalances_with_deltas_works_correctly(
        uint128[16] calldata balances,
        int128[16] calldata deltas,
        uint256 length
    ) public {
        length = bound(length, 0, 16);

        _setupTokenBalances(balances, length);

        BalanceDelta[] memory deltaArray = new BalanceDelta[](length);

        for (uint256 i = 0; i < length; ++i) {
            deltaArray[i] = BalanceDelta({
                token: tokens[i],
                amount: deltas[i] < -int256(uint256(balances[i])) ? -int256(uint256(balances[i])) : deltas[i]
            });
        }

        Balance[] memory expectedBalances = BalancesLogic.storeBalances(creditAccount, deltaArray);

        assertEq(expectedBalances.length, deltaArray.length, "Wrong length array was returned");

        for (uint256 i = 0; i < length; ++i) {
            assertEq(expectedBalances[i].token, tokens[i]);

            assertEq(
                expectedBalances[i].balance,
                uint256(int256(uint256(balances[i])) + deltaArray[i].amount),
                "Incorrect expected balance"
            );
        }
    }

    /// @notice U:[BLL-3]: `compareBalances` without tokens mask works correctly
    function test_U_BLL_03_compareBalances_without_tokens_mask_works_correctly(
        uint128[16] calldata balances,
        uint128[16] calldata expectedBalances,
        uint256 length,
        bool greater
    ) public {
        length = bound(length, 0, 16);

        _setupTokenBalances(balances, length);

        bool expectedResult = true;
        for (uint256 i = 0; i < length; ++i) {
            if (greater && expectedBalances[i] > balances[i]) {
                expectedResult = false;
                break;
            }

            if (!greater && expectedBalances[i] < balances[i]) {
                expectedResult = false;
                break;
            }
        }

        Balance[] memory storedBalances = new Balance[](length);
        for (uint256 i = 0; i < length; ++i) {
            storedBalances[i] = Balance({token: tokens[i], balance: expectedBalances[i]});
        }

        bool result =
            BalancesLogic.compareBalances(creditAccount, storedBalances, greater ? Comparison.GREATER : Comparison.LESS);
        assertEq(result, expectedResult, "Incorrect result");
    }

    /// @notice U:[BLL-4]: `storeBalances` with tokens mask works correctly
    function test_U_BLL_04_storeBalances_with_tokens_mask_works_correctly(
        uint128[16] calldata balances,
        uint256 tokensMask
    ) public {
        tokensMask = bound(tokensMask, 0, type(uint16).max);

        _setupTokenBalances(balances, 16);

        BalanceWithMask[] memory storedBalances =
            BalancesLogic.storeBalances(creditAccount, tokensMask, _getTokenByMask);

        uint256 j;

        for (uint256 i = 0; i < 16; ++i) {
            uint256 tokenMask = 1 << i;
            if (tokenMask & tokensMask > 0) {
                assertEq(storedBalances[j].balance, balances[i], "Incorrect token balance");

                assertEq(storedBalances[j].token, tokens[i], "Incorrect token address");

                assertEq(storedBalances[j].tokenMask, tokenMask, "Incorrect token mask");
                ++j;
            }
        }
    }

    /// @notice U:[BLL-5]: `compareBalances` with tokens mask works correctly
    function test_U_BLL_05_compareBalances_with_tokens_mask_works_correctly(
        uint128[16] calldata balancesBefore,
        uint128[16] calldata balancesAfter,
        uint256 tokensMask,
        bool greater
    ) public {
        tokensMask = bound(tokensMask, 0, type(uint16).max);

        _setupTokenBalances(balancesBefore, 16);

        BalanceWithMask[] memory storedBalances =
            BalancesLogic.storeBalances(creditAccount, tokensMask, _getTokenByMask);

        _setupTokenBalances(balancesAfter, 16);

        bool expectedResult = true;
        for (uint256 i = 0; i < 16; ++i) {
            uint256 tokenMask = 1 << i;
            if (tokensMask & tokenMask > 0) {
                if (greater && balancesAfter[i] < balancesBefore[i]) {
                    expectedResult = false;
                    break;
                }

                if (!greater && balancesAfter[i] > balancesBefore[i]) {
                    expectedResult = false;
                    break;
                }
            }
        }

        bool result = BalancesLogic.compareBalances(
            creditAccount, tokensMask, storedBalances, greater ? Comparison.GREATER : Comparison.LESS
        );
        assertEq(result, expectedResult, "Incorrect result");
    }

    function _getTokenByMask(uint256 mask) internal view returns (address) {
        return tokens[maskToIndex[mask]];
    }
}
