// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

/// @notice Withdrawal cancellation type
///         - `CANCEL` returns immature withdrawals to credit account and claims mature ones
///         - `FORCE_CANCEL` returns all withdrawals to credit account
enum CancelAction {
    CANCEL,
    FORCE_CANCEL
}

/// @notice Withdrawal claim type
///         - `CLAIM` only claims mature withdrawals
///         - `FORCE_CLAIM` claims both mature and immature withdrawals
enum ClaimAction {
    CLAIM,
    FORCE_CLAIM
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

    /// @notice Returns scheduled withdrawals for a given credit account that can be cancelled
    function cancellableScheduledWithdrawals(address creditAccount, CancelAction action)
        external
        view
        returns (address[2] memory tokens, uint256[2] memory amounts);

    /// @notice Schedules withdrawal from the credit account
    /// @param creditAccount Account to withdraw from
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw
    /// @param tokenIndex Collateral index of withdrawn token in account's credit manager
    /// @custom:expects `amount` is greater than 1
    /// @custom:expects Credit manager transferred `amount` of `token` to this contract prior to calling this function
    function addScheduledWithdrawal(address creditAccount, address token, uint256 amount, uint8 tokenIndex) external;

    /// @notice Cancels scheduled withdrawals from the credit account
    /// @param creditAccount Account to cancel withdrawals from
    /// @param to Address to send mature withdrawals to when `action` is `CLAIM`
    ///           If `to` is blacklisted in token, turns scheduled withdrawal into immediate
    /// @param action See `CancelAction`
    /// @param tokensToEnable Bit mask of tokens that should be enabled as collateral on the credit account
    /// @custom:expects Credit account has at least one scheduled withdrawal
    function cancelScheduledWithdrawals(address creditAccount, address to, CancelAction action)
        external
        returns (uint256 tokensToEnable);

    /// @notice Claims scheduled withdrawals from the credit account
    /// @param creditAccount Account withdrawal was made from
    /// @param to Address to send withdrawals to
    /// @param action See `ClaimAction`
    /// @param hasScheduled If account has at least one scheduled withdrawal after claiming
    function claimScheduledWithdrawals(address creditAccount, address to, ClaimAction action)
        external
        returns (bool hasScheduled);

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
