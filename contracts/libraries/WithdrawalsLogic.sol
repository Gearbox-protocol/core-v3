// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {ClaimAction, ScheduledWithdrawal} from "../interfaces/IWithdrawalManagerV3.sol";

/// @title Withdrawals logic library
library WithdrawalsLogic {
    /// @dev Clears withdrawal in storage
    function clear(ScheduledWithdrawal storage w) internal {
        w.maturity = 1; // U:[WL-1]
        w.amount = 1; // U:[WL-1]
    }

    /// @dev If withdrawal is scheduled, returns withdrawn token, its mask in credit manager and withdrawn amount
    function tokenMaskAndAmount(ScheduledWithdrawal storage w)
        internal
        view
        returns (address token, uint256 mask, uint256 amount)
    {
        uint256 amount_ = w.amount;
        if (amount_ > 1) {
            unchecked {
                token = w.token; // U:[WL-2]
                mask = 1 << w.tokenIndex; // U:[WL-2]
                amount = amount_ - 1; // U:[WL-2]
            }
        }
    }

    /// @dev Returns flag indicating whether there are free withdrawal slots and the index of first such slot
    function findFreeSlot(ScheduledWithdrawal[2] storage ws) internal view returns (bool found, uint8 slot) {
        if (ws[0].maturity <= 1) {
            found = true; // U:[WL-3]
        } else if (ws[1].maturity <= 1) {
            found = true; // U:[WL-3]
            slot = 1; // U:[WL-3]
        }
    }

    /// @dev Returns true if withdrawal with given maturity can be claimed under given action
    function claimAllowed(ClaimAction action, uint40 maturity) internal view returns (bool) {
        if (maturity <= 1) return false; // U:[WL-4]
        if (action == ClaimAction.FORCE_CANCEL) return false; // U:[WL-4]
        if (action == ClaimAction.FORCE_CLAIM) return true; // U:[WL-4]
        return block.timestamp >= maturity; // U:[WL-4]
    }

    /// @dev Returns true if withdrawal with given maturity can be cancelled under given action
    function cancelAllowed(ClaimAction action, uint40 maturity) internal view returns (bool) {
        if (maturity <= 1) return false; // U:[WL-5]
        if (action == ClaimAction.FORCE_CANCEL) return true; // U:[WL-5]
        if (action == ClaimAction.FORCE_CLAIM || action == ClaimAction.CLAIM) return false; // U:[WL-5]
        return block.timestamp < maturity; // U:[WL-5]
    }
}
