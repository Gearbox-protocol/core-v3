// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;
pragma abicoder v1;

import {ClaimAction} from "../../../interfaces/IWithdrawalManagerV3.sol";

struct CancellableWithdrawals {
    address token;
    uint256 amount;
}

contract WithdrawalManagerMock {
    uint256 public constant version = 3_00;

    uint40 public delay;

    mapping(bool => CancellableWithdrawals[2]) cancellableWithdrawals;

    bool public claimScheduledWithdrawalsWasCalled;
    bool return_hasScheduled;
    uint256 return_tokensToEnable;

    function cancellableScheduledWithdrawals(address, bool isForceCancel)
        external
        view
        returns (address token1, uint256 amount1, address token2, uint256 amount2)
    {
        CancellableWithdrawals[2] storage cw = cancellableWithdrawals[isForceCancel];
        (token1, amount1) = (cw[0].token, cw[0].amount);
        (token2, amount2) = (cw[1].token, cw[1].amount);
    }

    function setCancellableWithdrawals(
        bool isForceCancel,
        address token1,
        uint256 amount1,
        address token2,
        uint256 amount2
    ) external {
        cancellableWithdrawals[isForceCancel][0] = CancellableWithdrawals({token: token1, amount: amount1});
        cancellableWithdrawals[isForceCancel][1] = CancellableWithdrawals({token: token2, amount: amount2});
    }

    function setDelay(uint40 _delay) external {
        delay = _delay;
    }

    function addScheduledWithdrawal(address creditAccount, address token, uint256 amount, uint8 tokenIndex) external {}

    function claimScheduledWithdrawals(address, address, ClaimAction)
        external
        returns (bool hasScheduled, uint256 tokensToEnable)
    {
        claimScheduledWithdrawalsWasCalled = true;
        hasScheduled = return_hasScheduled;
        tokensToEnable = return_tokensToEnable;
    }

    function setClaimScheduledWithdrawals(bool hasScheduled, uint256 tokensToEnable) external {
        return_hasScheduled = hasScheduled;
        return_tokensToEnable = tokensToEnable;
    }

    function addImmediateWithdrawal(address creditAccount, address to, uint256 amount) external {}
}
