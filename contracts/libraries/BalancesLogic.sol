// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {BitMask} from "./BitMask.sol";

import {Balance} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";

struct BalanceWithMask {
    address token;
    uint256 tokenMask;
    uint256 balance;
}

struct BalanceDelta {
    address token;
    int256 amount;
}

/// @title Balances logic library
/// @notice Implements functions for before-and-after balance comparisons
library BalancesLogic {
    using BitMask for uint256;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /// @dev Returns an array of expected token balances after operations
    /// @param creditAccount Credit account to compute expected balances for
    /// @param deltas The array of (token, amount) structs that contain expected balance increases
    function storeBalances(address creditAccount, BalanceDelta[] memory deltas)
        internal
        view
        returns (Balance[] memory expected)
    {
        uint256 len = deltas.length;
        expected = new Balance[](len); // U:[BLL-1]
        for (uint256 i = 0; i < len;) {
            int256 balance = IERC20(deltas[i].token).safeBalanceOf({account: creditAccount}).toInt256();
            expected[i] = Balance({token: deltas[i].token, balance: (balance + deltas[i].amount).toUint256()}); // U:[BLL-1]
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Compares current balances to previously saved expected balances
    /// @param creditAccount Credit account to compare balances for
    /// @param expected Expected balances after all operations (from `storeBalances`)
    /// @return success False if at least one balance is lower than expected, true otherwise
    function compareBalances(address creditAccount, Balance[] memory expected) internal view returns (bool success) {
        uint256 len = expected.length;
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                if (IERC20(expected[i].token).safeBalanceOf({account: creditAccount}) < expected[i].balance) {
                    return false; // U:[BLL-2]
                }
            }
        }
        return true; // U:[BLL-2]
    }

    /// @dev Returns balances of enabled forbidden tokens on the credit account
    /// @param creditAccount Credit account to compute balances for
    /// @param enabledTokensMask Current mask of enabled tokens on the credit account
    /// @param forbiddenTokenMask Mask of forbidden tokens in the credit facade
    /// @param getTokenByMaskFn A function that returns a token's address by its mask
    function storeForbiddenBalances(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256 forbiddenTokenMask,
        function (uint256) view returns (address) getTokenByMaskFn
    ) internal view returns (BalanceWithMask[] memory forbiddenBalances) {
        uint256 forbiddenTokensOnAccount = enabledTokensMask & forbiddenTokenMask; // U:[BLL-3]

        if (forbiddenTokensOnAccount != 0) {
            uint256 i = 0;
            forbiddenBalances = new  BalanceWithMask[](forbiddenTokensOnAccount.calcEnabledTokens());
            unchecked {
                while (forbiddenTokensOnAccount != 0) {
                    uint256 tokenMask = forbiddenTokensOnAccount & uint256(-int256(forbiddenTokensOnAccount));
                    forbiddenTokensOnAccount ^= tokenMask;

                    address token = getTokenByMaskFn(tokenMask);
                    forbiddenBalances[i] = BalanceWithMask({
                        token: token,
                        tokenMask: tokenMask,
                        balance: IERC20(token).safeBalanceOf({account: creditAccount})
                    }); // U:[BLL-3]
                    ++i;
                }
            }
        }
    }

    /// @dev Compares current balances of forbidden tokens to previously saved
    /// @param creditAccount Credit account to compare balances for
    /// @param enabledTokensMaskBefore Mask of enabled tokens on the account before operations
    /// @param enabledTokensMaskAfter Mask of enabled tokens on the account after operations
    /// @param forbiddenBalances Balances of forbidden tokens before operations (from `storeForbiddenBalances`)
    /// @param forbiddenTokenMask Mask of forbidden tokens in the credit facade
    /// @return success False if balance of at least one forbidden token increased, true otherwise
    function checkForbiddenBalances(
        address creditAccount,
        uint256 enabledTokensMaskBefore,
        uint256 enabledTokensMaskAfter,
        BalanceWithMask[] memory forbiddenBalances,
        uint256 forbiddenTokenMask
    ) internal view returns (bool success) {
        uint256 forbiddenTokensOnAccount = enabledTokensMaskAfter & forbiddenTokenMask;
        if (forbiddenTokensOnAccount == 0) return true; // U:[BLL-4]

        // Ensure that no new forbidden tokens were enabled
        uint256 forbiddenTokensOnAccountBefore = enabledTokensMaskBefore & forbiddenTokenMask;
        if (forbiddenTokensOnAccount & ~forbiddenTokensOnAccountBefore != 0) return false; // U:[BLL-4]

        // Then, check that any remaining forbidden tokens didn't have their balances increased
        unchecked {
            uint256 len = forbiddenBalances.length;
            for (uint256 i = 0; i < len; ++i) {
                if (forbiddenTokensOnAccount & forbiddenBalances[i].tokenMask != 0) {
                    uint256 currentBalance = IERC20(forbiddenBalances[i].token).safeBalanceOf({account: creditAccount});
                    if (currentBalance > forbiddenBalances[i].balance) {
                        return false; // U:[BLL-4]
                    }
                }
            }
        }
        return true; // U:[BLL-4]
    }
}
