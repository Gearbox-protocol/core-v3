// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

/// @notice Withdrawal claim type
///         - `CLAIM` only claims mature withdrawals to specified address
///         - `CANCEL` also claims mature withdrawals but cancels immature ones
///         - `FORCE_CLAIM` claims both mature and immature withdrawals
///         - `FORCE_CANCEL` cancels both mature and immature withdrawals
enum ClaimAction {
    CLAIM,
    CANCEL,
    FORCE_CLAIM,
    FORCE_CANCEL
}

/// @notice Scheduled withdrawal data
/// @param tokenIndex Collateral index of withdrawn token in account's credit manager
/// @param maturity Timestamp after which withdrawal can be claimed
/// @param token Token to withdraw
/// @param amount Amount to withdraw
struct ScheduledWithdrawal {
    uint8 tokenIndex;
    uint40 maturity;
    address token;
    uint256 amount;
}

interface IWithdrawalManagerEvents {
    /// @notice Emitted when new immediate withdrawal is added
    /// @param account Account immediate withdrawal was added for
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw
    event AddImmediateWithdrawal(address indexed account, address indexed token, uint256 amount);

    /// @notice Emitted when immediate withdrawal is claimed
    /// @param account Account that claimed tokens
    /// @param token Token claimed
    /// @param to Token recipient
    /// @param amount Amount claimed
    event ClaimImmediateWithdrawal(address indexed account, address indexed token, address to, uint256 amount);

    /// @notice Emitted when new scheduled withdrawal is added
    /// @param creditAccount Account to withdraw from
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw
    /// @param maturity Timestamp after which withdrawal can be claimed
    event AddScheduledWithdrawal(address indexed creditAccount, address indexed token, uint256 amount, uint40 maturity);

    /// @notice Emitted when scheduled withdrawal is cancelled
    /// @param creditAccount Account the token is returned to
    /// @param token Token returned
    /// @param amount Amount returned
    event CancelScheduledWithdrawal(address indexed creditAccount, address indexed token, uint256 amount);

    /// @notice Emitted when scheduled withdrawal is claimed
    /// @param creditAccount Account withdrawal was made from
    /// @param token Token claimed
    /// @param to Token recipient
    /// @param amount Amount claimed
    event ClaimScheduledWithdrawal(address indexed creditAccount, address indexed token, address to, uint256 amount);

    /// @notice Emitted when new scheduled withdrawal delay is set by configurator
    /// @param delay New delay for scheduled withdrawals
    event SetWithdrawalDelay(uint40 delay);

    /// @notice Emitted when new credit manager status is set by configurator
    /// @param creditManager Credit manager for which the status is set
    /// @param status New status of the credit manager
    event SetCreditManagerStatus(address indexed creditManager, bool status);
}

interface IWithdrawalManager is IWithdrawalManagerEvents, IVersion {
    /// --------------------- ///
    /// IMMEDIATE WITHDRAWALS ///
    /// --------------------- ///

    /// @notice Returns amount of token claimable by the account
    function immediateWithdrawals(address account, address token) external view returns (uint256);

    /// @notice Adds new immediate withdrawal for the account
    /// @param account Account to add immediate withdrawal for
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw
    /// @custom:expects Credit manager transferred `amount` of `token` to this contract prior to calling this function
    function addImmediateWithdrawal(address account, address token, uint256 amount) external;

    /// @notice Claims `msg.sender`'s immediate withdrawal
    /// @param token Token to claim
    /// @param to Token recipient
    function claimImmediateWithdrawal(address token, address to) external;

    /// --------------------- ///
    /// SCHEDULED WITHDRAWALS ///
    /// --------------------- ///

    /// @notice Delay for scheduled withdrawals
    function delay() external view returns (uint40);

    /// @notice Returns withdrawals scheduled for a given credit account
    /// @param creditAccount Account to get withdrawals for
    /// @return withdrawals See `ScheduledWithdrawal`
    function scheduledWithdrawals(address creditAccount)
        external
        view
        returns (ScheduledWithdrawal[2] memory withdrawals);

    /// @notice Schedules withdrawal from the credit account
    /// @param creditAccount Account to withdraw from
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw
    /// @param tokenIndex Collateral index of withdrawn token in account's credit manager
    /// @custom:expects Credit manager transferred `amount` of `token` to this contract prior to calling this function
    function addScheduledWithdrawal(address creditAccount, address token, uint256 amount, uint8 tokenIndex) external;

    /// @notice Claims scheduled withdrawals from the credit account
    ///         - Withdrawals are either sent to `to` or returned to `creditAccount` based on maturity and `action`
    ///         - If `to` is blacklisted in claimed token, scheduled withdrawal turns into immediate
    /// @param creditAccount Account withdrawal was made from
    /// @param to Address to send withdrawals to
    /// @param action See `ClaimAction`
    /// @return hasScheduled Whether account has at least one scheduled withdrawal after claiming
    /// @return tokensToEnable Bit mask of returned tokens that should be enabled as account's collateral
    function claimScheduledWithdrawals(address creditAccount, address to, ClaimAction action)
        external
        returns (bool hasScheduled, uint256 tokensToEnable);

    /// @notice Returns scheduled withdrawals from the credit account that can be cancelled
    function cancellableScheduledWithdrawals(address creditAccount, bool isForceCancel)
        external
        view
        returns (address token1, uint256 amount1, address token2, uint256 amount2);

    /// ------------- ///
    /// CONFIGURATION ///
    /// ------------- ///

    /// @notice Whether given address is a supported credit manager
    function creditManagerStatus(address) external view returns (bool);

    /// @notice Sets delay for scheduled withdrawals, only affects new withdrawal requests
    /// @param delay New delay for scheduled withdrawals
    function setWithdrawalDelay(uint40 delay) external;

    /// @notice Sets status for the credit manager
    /// @param creditManager Credit manager to set the status for
    /// @param status New status of the credit manager
    function setCreditManagerStatus(address creditManager, bool status) external;
}
