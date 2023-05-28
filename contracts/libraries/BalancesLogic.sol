// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20Helper} from "./IERC20Helper.sol";

import "../interfaces/IExceptions.sol";

import {BitMask} from "./BitMask.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RAY} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

struct Balance {
    address token;
    uint256 tokenMask;
    uint256 balance;
}

/// @title Balances logic library
/// @notice Implements functions that used for before-and-after balance comparisons

library BalancesLogic {
    using BitMask for uint256;

    /// @dev Returns an array of balances that are expected after operations
    /// @param creditAccount Credit Account to compute new balances for
    /// @param deltas The array of (token, amount) objects that contain expected balance increases
    function storeBalances(address creditAccount, Balance[] memory deltas)
        internal
        view
        returns (Balance[] memory expected)
    {
        expected = deltas;
        uint256 len = deltas.length;

        for (uint256 i = 0; i < len;) {
            expected[i].balance += IERC20Helper.balanceOf(expected[i].token, creditAccount);
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

    /// @dev Computes balances of forbidden tokens and returns them for later checks
    /// @param creditAccount Credit Account to store balances for
    /// @param enabledTokensMask Current mask of enabled tokens
    /// @param forbiddenTokenMask Mask of forbidden tokens
    /// @param getTokenByMaskFn A function that returns the token's address by its mask
    function storeForbiddenBalances(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256 forbiddenTokenMask,
        function (uint256) view returns (address) getTokenByMaskFn
    ) internal view returns (Balance[] memory forbiddenBalances) {
        uint256 forbiddenTokensOnAccount = enabledTokensMask & forbiddenTokenMask;

        if (forbiddenTokensOnAccount != 0) {
            forbiddenBalances = new Balance[](forbiddenTokensOnAccount.calcEnabledTokens());
            unchecked {
                uint256 i;
                for (uint256 tokenMask = 1; tokenMask < forbiddenTokensOnAccount; tokenMask <<= 1) {
                    if (forbiddenTokensOnAccount & tokenMask != 0) {
                        address token = getTokenByMaskFn(tokenMask);
                        forbiddenBalances[i].token = token;
                        forbiddenBalances[i].tokenMask = tokenMask;
                        forbiddenBalances[i].balance = IERC20Helper.balanceOf(token, creditAccount);
                        ++i;
                    }
                }
            }
        }
    }

    /// @dev Checks that no new forbidden tokens were enabled and that balances of existing forbidden tokens
    ///      were not increased
    /// @param creditAccount Credit Account to check
    /// @param enabledTokensMaskBefore Mask of enabled tokens on the account before operations
    /// @param enabledTokensMaskAfter Mask of enabled tokens on the account after operations
    /// @param forbiddenBalances Array of balances of forbidden tokens (received from `storeForbiddenBalances`)
    /// @param forbiddenTokenMask Mask of forbidden tokens
    function checkForbiddenBalances(
        address creditAccount,
        uint256 enabledTokensMaskBefore,
        uint256 enabledTokensMaskAfter,
        Balance[] memory forbiddenBalances,
        uint256 forbiddenTokenMask
    ) internal view {
        uint256 forbiddenTokensOnAccount = enabledTokensMaskAfter & forbiddenTokenMask;
        if (forbiddenTokensOnAccount == 0) return;

        /// A diff between the forbidden tokens before and after is computed
        /// If there are forbidden tokens enabled during operations, the function would revert
        uint256 forbiddenTokensOnAccountBefore = enabledTokensMaskBefore & forbiddenTokenMask;
        if (forbiddenTokensOnAccount & ~forbiddenTokensOnAccountBefore != 0) revert ForbiddenTokensException();

        /// Then, the function checks that any remaining forbidden tokens didn't have their balances increased
        unchecked {
            uint256 len = forbiddenBalances.length;
            for (uint256 i = 0; i < len; ++i) {
                if (forbiddenTokensOnAccount & forbiddenBalances[i].tokenMask != 0) {
                    uint256 currentBalance = IERC20Helper.balanceOf(forbiddenBalances[i].token, creditAccount);
                    if (currentBalance > forbiddenBalances[i].balance) {
                        revert ForbiddenTokensException();
                    }
                }
            }
        }
    }
}
