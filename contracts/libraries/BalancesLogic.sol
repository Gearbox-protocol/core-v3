// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {BitMask} from "./BitMask.sol";

struct Balance {
    address token;
    uint256 balance;
}

struct BalanceWithMask {
    address token;
    uint256 tokenMask;
    uint256 balance;
}

struct BalanceDelta {
    address token;
    int256 amount;
}

enum Comparison {
    GREATER,
    LESS
}

/// @title Balances logic library
/// @notice Implements functions for before-and-after balance comparisons
library BalancesLogic {
    using BitMask for uint256;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /// @dev Compares current `token` balance with `value`
    /// @param token Token to check balance for
    /// @param value Value to compare current token balance with
    /// @param comparison Whether current balance must be greater/less than or equal to `value`
    function checkBalance(address creditAccount, address token, uint256 value, Comparison comparison)
        internal
        view
        returns (bool)
    {
        uint256 current = IERC20(token).safeBalanceOf(creditAccount);
        return (comparison == Comparison.GREATER && current >= value)
            || (comparison == Comparison.LESS && current <= value); // U:[BLL-1]
    }

    /// @dev Returns an array of expected token balances after operations
    /// @param creditAccount Credit account to compute balances for
    /// @param deltas Array of expected token balance changes
    function storeBalances(address creditAccount, BalanceDelta[] memory deltas)
        internal
        view
        returns (Balance[] memory balances)
    {
        uint256 len = deltas.length;
        balances = new Balance[](len); // U:[BLL-2]
        for (uint256 i = 0; i < len;) {
            int256 balance = IERC20(deltas[i].token).safeBalanceOf(creditAccount).toInt256();
            balances[i] = Balance({token: deltas[i].token, balance: (balance + deltas[i].amount).toUint256()}); // U:[BLL-2]
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Compares current balances with the previously stored ones
    /// @param creditAccount Credit account to compare balances for
    /// @param balances Array of previously stored balances
    /// @param comparison Whether current balances must be greater/less than or equal to stored ones
    /// @return failedToken The first token for which the condition specified by `comparison` fails, if any
    function compareBalances(address creditAccount, Balance[] memory balances, Comparison comparison)
        internal
        view
        returns (address failedToken)
    {
        unchecked {
            uint256 len = balances.length;
            for (uint256 i; i < len; ++i) {
                if (!BalancesLogic.checkBalance(creditAccount, balances[i].token, balances[i].balance, comparison)) {
                    return balances[i].token; // U:[BLL-3]
                }
            }
        }
    }

    /// @dev Returns balances of specified tokens on the credit account
    /// @param creditAccount Credit account to compute balances for
    /// @param tokensMask Bit mask of tokens to compute balances for
    /// @param getTokenByMaskFn Function that returns token's address by its mask
    function storeBalances(
        address creditAccount,
        uint256 tokensMask,
        function (uint256) view returns (address) getTokenByMaskFn
    ) internal view returns (BalanceWithMask[] memory balances) {
        if (tokensMask == 0) return balances;

        balances = new BalanceWithMask[](tokensMask.calcEnabledTokens()); // U:[BLL-4]
        unchecked {
            uint256 i;
            while (tokensMask != 0) {
                uint256 tokenMask = tokensMask.lsbMask();
                tokensMask ^= tokenMask;

                address token = getTokenByMaskFn(tokenMask);
                balances[i] = BalanceWithMask({
                    token: token,
                    tokenMask: tokenMask,
                    balance: IERC20(token).safeBalanceOf(creditAccount)
                }); // U:[BLL-4]
                ++i;
            }
        }
    }

    /// @dev Compares current balances of specified tokens with the previously stored ones
    /// @param creditAccount Credit account to compare balances for
    /// @param tokensMask Bit mask of tokens to compare balances for
    /// @param balances Array of previously stored balances
    /// @param comparison Whether current balances must be greater/less than or equal to stored ones
    /// @return failedToken The first token for which the condition specified by `comparison` fails, if any
    /// @dev This function assumes that `tokensMask` encodes a subset of tokens from `balances`
    function compareBalances(
        address creditAccount,
        uint256 tokensMask,
        BalanceWithMask[] memory balances,
        Comparison comparison
    ) internal view returns (address failedToken) {
        if (tokensMask == 0) return address(0);

        unchecked {
            uint256 len = balances.length;
            for (uint256 i; i < len; ++i) {
                if (tokensMask & balances[i].tokenMask == 0) continue;
                if (!BalancesLogic.checkBalance(creditAccount, balances[i].token, balances[i].balance, comparison)) {
                    return balances[i].token; // U:[BLL-5]
                }
            }
        }
    }
}
