// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {ScheduledWithdrawal} from "../interfaces/IWithdrawalManager.sol";

library Withdrawals {
    function clear(ScheduledWithdrawal memory w) internal pure {
        w.maturity = 1;
        w.amount = 1;
    }

    function isInitialized(ScheduledWithdrawal memory w) internal pure returns (bool) {
        return w.maturity > 1;
    }

    function isMature(ScheduledWithdrawal memory w) internal view returns (bool) {
        return isInitialized(w) && block.timestamp >= w.maturity;
    }

    function isImmature(ScheduledWithdrawal memory w) internal view returns (bool) {
        return isInitialized(w) && block.timestamp < w.maturity;
    }

    function tokenMaskAndAmount(ScheduledWithdrawal memory w)
        internal
        pure
        returns (uint256 tokenMask, uint256 amount)
    {
        if (w.amount > 1) {
            unchecked {
                tokenMask = 1 << w.tokenIndex;
                amount = w.amount - 1;
            }
        }
    }

    function status(ScheduledWithdrawal[2] memory ws, bool isEmergency, bool forceClaim)
        internal
        view
        returns (bool[2] memory initialized, bool[2] memory claimable)
    {
        unchecked {
            for (uint8 i; i < 2; ++i) {
                initialized[i] = isInitialized(ws[i]);
                claimable[i] = initialized[i] && !isEmergency && (forceClaim || isMature(ws[i]));
            }
        }
    }

    function findFreeSlot(ScheduledWithdrawal[2] memory ws)
        internal
        view
        returns (bool found, bool claim, uint8 slot)
    {
        (bool[2] memory initialized, bool[2] memory claimable) = status(ws, false, false);

        unchecked {
            for (uint8 i; i < 2; ++i) {
                if (!initialized[i]) {
                    return (true, false, i);
                }
            }
        }

        unchecked {
            for (uint8 i; i < 2; ++i) {
                if (claimable[i]) {
                    return (true, true, i);
                }
            }
        }
    }

    function bothSlotsEmpty(ScheduledWithdrawal[2] memory ws) internal pure returns (bool) {
        return !(isInitialized(ws[0]) || isInitialized(ws[1]));
    }
}
