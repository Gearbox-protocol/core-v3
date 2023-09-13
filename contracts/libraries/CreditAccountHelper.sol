// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {ICreditAccountBase} from "../interfaces/ICreditAccountV3.sol";
import {AllowanceFailedException} from "../interfaces/IExceptions.sol";

/// @title Credit account helper library
/// @notice Implements functions that help manage assets on a credit account
library CreditAccountHelper {
    using SafeERC20 for IERC20;

    /// @dev Requests a credit account to do an approval with support for various kinds of tokens
    /// @dev Supports up-to-spec ERC20 tokens, ERC20 tokens that revert on transfer failure,
    ///      tokens that require 0 allowance before changing to non-zero value, and non-ERC20 tokens
    ///      that do not return a `success` value
    /// @param creditAccount Credit account to approve tokens from
    /// @param token Token to approve
    /// @param spender Address to approve to
    /// @param amount Amount to approve
    function safeApprove(ICreditAccountBase creditAccount, address token, address spender, uint256 amount) internal {
        if (!_approve(creditAccount, token, spender, amount, false)) {
            _approve(creditAccount, token, spender, 0, true); //U:[CAH-1,2]
            _approve(creditAccount, token, spender, amount, true); // U:[CAH-1,2]
        }
    }

    /// @dev Internal function used to approve tokens from a credit account to a third-party contrat.
    ///      Uses credit account's `execute` to properly handle both ERC20-compliant and on-compliant
    ///      (no returned value from "approve") tokens
    /// @param creditAccount Credit account to approve tokens from
    /// @param token Token to approve
    /// @param spender Address to approve to
    /// @param amount Amount to approve
    /// @param revertIfFailed Whether to revert or return `false` on receiving `false` or an error from `approve`
    function _approve(
        ICreditAccountBase creditAccount,
        address token,
        address spender,
        uint256 amount,
        bool revertIfFailed
    ) private returns (bool) {
        // Makes a low-level call to approve from the credit account and parses the value.
        // If nothing or true was returned, assumes that the call succeeded.
        try creditAccount.execute(token, abi.encodeCall(IERC20.approve, (spender, amount))) returns (
            bytes memory result
        ) {
            if (result.length == 0 || abi.decode(result, (bool))) return true;
        } catch {}

        // On the first try, failure is allowed to handle tokens that prohibit changing allowance from non-zero value.
        // After that, failure results in a revert.
        if (revertIfFailed) revert AllowanceFailedException();
        return false;
    }

    /// @dev Performs a token transfer from a credit account, accounting for non-ERC20 tokens
    /// @param creditAccount Credit account to send tokens from
    /// @param token Token to send
    /// @param to Address to send to
    /// @param amount Amount to send
    function transfer(ICreditAccountBase creditAccount, address token, address to, uint256 amount) internal {
        creditAccount.safeTransfer(token, to, amount);
    }

    /// @dev Performs a token transfer from a Credit account and returns the actual amount of token transferred
    /// @dev For some tokens, such as stETH or USDT (with fee enabled), the amount that arrives to the recipient can
    ///      differ from the sent amount. This ensures that calculations are correct in such cases.
    /// @param creditAccount Credit account to send tokens from
    /// @param token Token to send
    /// @param to Address to send to
    /// @param amount Amount to send
    /// @return delivered The actual amount that the `to` address received
    function transferDeliveredBalanceControl(
        ICreditAccountBase creditAccount,
        address token,
        address to,
        uint256 amount
    ) internal returns (uint256 delivered) {
        uint256 balanceBefore = IERC20(token).safeBalanceOf({account: to});
        transfer(creditAccount, token, to, amount);
        delivered = IERC20(token).safeBalanceOf({account: to}) - balanceBefore;
    }
}
