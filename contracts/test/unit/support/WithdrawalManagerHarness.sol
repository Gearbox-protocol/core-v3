// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {ClaimAction, ScheduledWithdrawal} from "../../../interfaces/IWithdrawalManagerV3.sol";
import {WithdrawalManagerV3} from "../../../support/WithdrawalManagerV3.sol";

contract WithdrawalManagerHarness is WithdrawalManagerV3 {
    constructor(address _addressProvider, uint40 _delay) WithdrawalManagerV3(_addressProvider, _delay) {}

    function setWithdrawalSlot(address creditAccount, uint8 slot, ScheduledWithdrawal memory w) external {
        _scheduled[creditAccount][slot] = w;
    }

    function processScheduledWithdrawal(address creditAccount, uint8 slot, ClaimAction action, address to)
        external
        returns (bool scheduled, bool claimed, uint256 tokensToEnable)
    {
        return _processScheduledWithdrawal(_scheduled[creditAccount][slot], action, creditAccount, to);
    }

    function claimScheduledWithdrawal(address creditAccount, uint8 slot, address to) external {
        _claimScheduledWithdrawal(_scheduled[creditAccount][slot], creditAccount, to);
    }

    function cancelScheduledWithdrawal(address creditAccount, uint8 slot) external returns (uint256 tokensToEnable) {
        return _cancelScheduledWithdrawal(_scheduled[creditAccount][slot], creditAccount);
    }
}
