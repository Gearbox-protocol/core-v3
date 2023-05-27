// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20Helper} from "./IERC20Helper.sol";

import "../interfaces/IExceptions.sol";

import {BitMask} from "./BitMask.sol";

import {Balance} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";

uint256 constant INDEX_PRECISION = 10 ** 9;

/// @title Credit Logic Library
library BalancesLogic {
    using BitMask for uint256;

    /// @param creditAccount Credit Account to compute balances for
    function storeBalances(address creditAccount, Balance[] memory desired)
        internal
        view
        returns (Balance[] memory expected)
    {
        // Retrieves the balance list from calldata

        expected = desired; // F:[FA-45]
        uint256 len = expected.length; // F:[FA-45]

        for (uint256 i = 0; i < len;) {
            expected[i].balance += IERC20Helper.balanceOf(expected[i].token, creditAccount); // F:[FA-45]
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Compares current balances to previously saved expected balances.
    /// Reverts if at least one balance is lower than expected
    /// @param creditAccount Credit Account to check
    /// @param expected Expected balances after all operations

    function compareBalances(address creditAccount, Balance[] memory expected) internal view {
        uint256 len = expected.length; // F:[FA-45]
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                if (IERC20Helper.balanceOf(expected[i].token, creditAccount) < expected[i].balance) {
                    revert BalanceLessThanMinimumDesiredException(expected[i].token);
                } // F:[FA-45]
            }
        }
    }

    function storeForbiddenBalances(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256 forbiddenTokenMask,
        function (uint256) view returns (address) getTokenByMaskFn
    ) internal view returns (uint256[] memory forbiddenBalances) {
        uint256 forbiddenTokensOnAccount = enabledTokensMask & forbiddenTokenMask;

        if (forbiddenTokensOnAccount != 0) {
            forbiddenBalances = new uint256[](forbiddenTokensOnAccount.calcEnabledTokens());
            unchecked {
                uint256 i;
                for (uint256 tokenMask = 1; tokenMask < forbiddenTokensOnAccount; tokenMask <<= 1) {
                    if (forbiddenTokensOnAccount & tokenMask != 0) {
                        address token = getTokenByMaskFn(tokenMask);
                        forbiddenBalances[i] = IERC20Helper.balanceOf(token, creditAccount);
                        ++i;
                    }
                }
            }
        }
    }

    function checkForbiddenBalances(
        address creditAccount,
        uint256 enabledTokensMaskBefore,
        uint256 enabledTokensMaskAfter,
        uint256[] memory forbiddenBalances,
        uint256 forbiddenTokenMask,
        function (uint256) view returns (address) getTokenByMaskFn
    ) internal view {
        uint256 forbiddenTokensOnAccount = enabledTokensMaskAfter & forbiddenTokenMask;
        if (forbiddenTokensOnAccount == 0) return;

        uint256 forbiddenTokensOnAccountBefore = enabledTokensMaskBefore & forbiddenTokenMask;
        if (forbiddenTokensOnAccount & ~forbiddenTokensOnAccountBefore != 0) revert ForbiddenTokensException();

        unchecked {
            uint256 i;
            for (uint256 tokenMask = 1; tokenMask < forbiddenTokensOnAccountBefore; tokenMask <<= 1) {
                if (forbiddenTokensOnAccountBefore & tokenMask != 0) {
                    if (forbiddenTokensOnAccount & tokenMask != 0) {
                        address token = getTokenByMaskFn(tokenMask);
                        uint256 balance = IERC20Helper.balanceOf(token, creditAccount);
                        if (balance > forbiddenBalances[i]) {
                            revert ForbiddenTokensException();
                        }
                    }

                    ++i;
                }
            }
        }
    }
}
