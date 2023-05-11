// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Helper} from "./IERC20Helper.sol";

import {ICreditAccount} from "../interfaces/ICreditAccount.sol";
import {AllowanceFailedException} from "../interfaces/IExceptions.sol";
/// @title CreditAccount Helper library

library CreditAccountHelper {
    using IERC20Helper for IERC20;

    function safeApprove(ICreditAccount creditAccount, address token, address spender, uint256 amount) internal {
        if (!_approve(creditAccount, token, spender, amount, false)) {
            // U:[CAH-1,2]
            _approve(creditAccount, token, spender, 0, true); //U:[CAH-1,2]
            _approve(creditAccount, token, spender, amount, true); // U:[CAH-1,2]
        }
    }

    /// @dev Internal function used to approve token from a Credit Account
    /// Uses Credit Account's execute to properly handle both ERC20-compliant and
    /// non-compliant (no returned value from "approve") tokens
    function _approve(ICreditAccount creditAccount, address token, address spender, uint256 amount, bool revertIfFailed)
        private
        returns (bool)
    {
        // Makes a low-level call to approve from the Credit Account
        // and parses the value. If nothing or true was returned,
        // assumes that the call succeeded
        try creditAccount.execute(token, abi.encodeCall(IERC20.approve, (spender, amount))) returns (
            bytes memory result
        ) {
            if (result.length == 0 || abi.decode(result, (bool)) == true) {
                return true;
            }
        } catch {}

        // On the first try, failure is allowed to handle tokens
        // that prohibit changing allowance from non-zero value;
        // After that, failure results in a revert
        if (revertIfFailed) revert AllowanceFailedException();
        return false;
    }

    function transfer(ICreditAccount creditAccount, address token, address to, uint256 amount) internal {
        ICreditAccount(creditAccount).safeTransfer(token, to, amount);
    }

    function transferDeliveredBalanceControl(ICreditAccount creditAccount, address token, address to, uint256 amount)
        internal
        returns (uint256 delivered)
    {
        uint256 balanceBefore = IERC20Helper.balanceOf(token, to);
        transfer(creditAccount, token, to, amount);
        delivered = IERC20Helper.balanceOf(token, to) - balanceBefore;
    }
}
