// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

/// @notice Scheduled withdrawal data
/// @param tokenIndex Collateral index of withdrawn token in account's credit manager
/// @param borrower Account owner that should claim tokens
/// @param maturity Timestamp after which withdrawal can be claimed
/// @param amount Amount to withdraw
/// @dev Keeping token index instead of mask allows to pack struct into 2 slots
struct ScheduledWithdrawal {
    uint8 tokenIndex;
    address borrower;
    uint40 maturity;
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
    /// @param borrower Account owner that should claim tokens
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw
    /// @param maturity Timestamp after which withdrawal can be claimed
    event AddScheduledWithdrawal(
        address indexed creditAccount, address indexed borrower, address indexed token, uint256 amount, uint40 maturity
    );

    /// @notice Emitted when scheduled withdrawal is cancelled
    /// @param creditAccount Account the token is returned to
    /// @param token Token returned
    /// @param amount Amount returned
    event CancelScheduledWithdrawal(address indexed creditAccount, address indexed token, uint256 amount);

    /// @notice Emitted when scheduled withdrawal is claimed
    /// @param creditAccount Account withdrawal was made from
    /// @param token Token claimed
    /// @param amount Amount claimed
    event ClaimScheduledWithdrawal(address indexed creditAccount, address indexed token, uint256 amount);

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
    /// @custom:expects `amount` is greater than 1
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

    /// @notice Returns withdrawals scheduled for a given credit account in raw form,
    ///         see `ScheduledWithdrawal` for details
    function scheduledWithdrawals(address creditManager, address creditAccount)
        external
        view
        returns (ScheduledWithdrawal[2] memory);

    /// @notice Returns scheduled withdrawals for a given credit account that can be cancelled
    ///         - Under normal operation, these are all immature withdrawals
    ///         - In emergency mode, all account's scheduled withdrawals can be cancelled
    function cancellableScheduledWithdrawals(address creditManager, address creditAccount)
        external
        view
        returns (uint256[2] memory tokenMasks, uint256[2] memory amounts);

    /// @notice Returns scheduled withdrawals for a given credit account that can be claimed
    ///         - Under normal operation, these are all mature withdrawals
    ///         - In emergency mode, claiming is disabled so no withdrawals can be claimed
    function claimableScheduledWithdrawals(address creditManager, address creditAccount)
        external
        view
        returns (uint256[2] memory tokenMasks, uint256[2] memory amounts);

    /// @notice Schedules withdrawal of given token from the credit account,
    ///         might claim a mature withdrawal first if it's needed to free the slot
    /// @param creditAccount Account to withdraw from
    /// @param borrower Account owner that should claim tokens
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw
    /// @param tokenIndex Collateral index of withdrawn token in account's credit manager
    /// @custom:expects `amount` is greater than 1
    /// @custom:expects Credit manager transferred `amount` of `token` to this contract prior to calling this function
    /// @custom:expects Credit manager is not in emergency mode
    function addScheduledWithdrawal(
        address creditAccount,
        address borrower,
        address token,
        uint256 amount,
        uint8 tokenIndex
    ) external;

    /// @notice Cancels scheduled withdrawals from the credit account
    ///         - Under normal operation, cancels immature withdrawals and claims mature ones
    ///         - In emergency mode, cancels all withdrawals
    /// @param creditAccount Account to cancel withdrawals from
    /// @param forceClaim If true and not in emergency mode, claim both mature and immature withdrawals
    /// @param tokensToEnable Bit mask of tokens that should be enabled as collateral on the credit account
    /// @custom:expects Credit account has at least one scheduled withdrawal
    function cancelScheduledWithdrawals(address creditAccount, bool forceClaim)
        external
        returns (uint256 tokensToEnable);

    /// @notice Claims scheduled withdrawals from the credit account by turning them into immediate withdrawals
    ///         - Under normal operation, claims all mature withdrawals
    ///         - In emergency mode, claiming is disabled so it reverts
    /// @param creditManager Manager the account is connected to
    /// @param creditAccount Account withdrawal was made from
    /// @dev If there remains no withdrawals scheduled for account after claiming, disables account's
    ///       withdrawal flag in the credit manager
    function claimScheduledWithdrawals(address creditManager, address creditAccount) external;

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
