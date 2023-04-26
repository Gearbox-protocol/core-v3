// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

enum CancellationType {
    RETURN_FUNDS,
    PUSH_WITHDRAWALS
}

interface IWithdrawManagerEvents {
    /// @dev Emitted when a borrower's claimable balance is increased
    event IncreaseClaimableBalance(address indexed token, address indexed holder, uint256 amount);

    /// @dev Emitted when a borrower claims their tokens
    event Claim(address indexed token, address indexed holder, address to, uint256 amount);

    /// @dev Emitted when a Credit Facade is added to BlacklistHelper
    event CreditFacadeAdded(address indexed creditFacade);

    /// @dev Emitted when a Credit Facade is removed from BlacklistHelper
    event CreditFacadeRemoved(address indexed creditFacade);

    event ScheduleDelayedWithdrawal(address indexed to, address indexed token, uint256 amount, uint256 availableAt);

    event CancelDelayedWithdrawal(address indexed to, address indexed token, uint256 amount);

    event PayDelayedWithdrawal(address indexed to, address indexed token, uint256 amount);
}

interface IWithdrawManager is IWithdrawManagerEvents, IVersion {
    /// @dev Transfers the sender's claimable balance of token to the specified address
    function claim(address token, address to) external;

    function addImmediateWithdrawal(
        address to,
        address token,
        uint256 amount // add check amount >0
    ) external;

    function addDelayedWithdrawal(address creditAccount, address to, address token, uint256 tokenMask, uint256 amount)
        external;

    /// @dev Returns the amount claimable by an account
    /// @param token token the get the amount for
    /// @param holder Acccount to to get the amount for
    function claimable(address holder, address token) external view returns (uint256);

    function cancelWithdrawals(address creditAccount, CancellationType ctype)
        external
        returns (uint256 tokensToEnable);

    function getWithdrawals(address creditManager, address creditAccount)
        external
        view
        returns (uint256 tokenMask1, uint256 amount1, uint256 tokenMask2, uint256 amount2);
}
