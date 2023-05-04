// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {ClaimAction, ScheduledWithdrawal} from "../interfaces/IWithdrawalManager.sol";

library Withdrawals {
    function clear(ScheduledWithdrawal memory w) internal pure {
        w.maturity = 1;
        w.amount = 1;
    }

    function isScheduled(ScheduledWithdrawal memory w) internal pure returns (bool) {
        return w.maturity > 1;
    }

    function isMature(ScheduledWithdrawal memory w) internal view returns (bool) {
        return isScheduled(w) && block.timestamp >= w.maturity;
    }

    function isImmature(ScheduledWithdrawal memory w) internal view returns (bool) {
        return isScheduled(w) && block.timestamp < w.maturity;
    }

    function tokenMaskAndAmount(ScheduledWithdrawal memory w)
        internal
        pure
        returns (address token, uint256 mask, uint256 amount)
    {
        if (w.amount > 1) {
            unchecked {
                token = w.token;
                mask = 1 << w.tokenIndex;
                amount = w.amount - 1;
            }
        }
    }

    function getStatus(ScheduledWithdrawal[2] memory ws, ClaimAction action)
        internal
        view
        returns (bool[2] memory cancellable, bool[2] memory claimable)
    {
        bool scheduled;
        unchecked {
            for (uint8 i; i < 2; ++i) {
                scheduled = isScheduled(ws[i]);
                cancellable[i] = scheduled && action != ClaimAction.FORCE_CLAIM
                    && (action == ClaimAction.FORCE_CANCEL || isImmature(ws[i]));
                claimable[i] = scheduled && action != ClaimAction.FORCE_CANCEL
                    && (action == ClaimAction.FORCE_CLAIM || isMature(ws[i]));
            }
        }
    }

    function findFreeSlot(ScheduledWithdrawal[2] memory ws) internal pure returns (bool found, uint8 slot) {
        unchecked {
            for (uint8 i; i < 2; ++i) {
                if (!isScheduled(ws[i])) {
                    return (true, i);
                }
            }
        }
    }

    function hasScheduled(ScheduledWithdrawal[2] memory ws) internal pure returns (bool) {
        return isScheduled(ws[0]) || isScheduled(ws[1]);
    }
}
