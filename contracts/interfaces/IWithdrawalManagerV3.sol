// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
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

/// @dev Special address that denotes pure ETH
address constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

interface IWithdrawalManagerV3Events {
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
    /// @param newDelay New delay for scheduled withdrawals
    event SetWithdrawalDelay(uint40 newDelay);

    /// @notice Emitted when new credit manager is added
    /// @param creditManager Added credit manager
    event AddCreditManager(address indexed creditManager);
}

/// @title Withdrawal manager interface
interface IWithdrawalManagerV3 is IWithdrawalManagerV3Events, IVersion {
    // --------------------- //
    // IMMEDIATE WITHDRAWALS //
    // --------------------- //

    function weth() external view returns (address);

    function immediateWithdrawals(address account, address token) external view returns (uint256);

    function addImmediateWithdrawal(address token, address to, uint256 amount) external;

    function claimImmediateWithdrawal(address token, address to) external;

    // --------------------- //
    // SCHEDULED WITHDRAWALS //
    // --------------------- //

    function delay() external view returns (uint40);

    function scheduledWithdrawals(address creditAccount)
        external
        view
        returns (ScheduledWithdrawal[2] memory withdrawals);

    function addScheduledWithdrawal(address creditAccount, address token, uint256 amount, uint8 tokenIndex) external;

    function claimScheduledWithdrawals(address creditAccount, address to, ClaimAction action)
        external
        returns (bool hasScheduled, uint256 tokensToEnable);

    function cancellableScheduledWithdrawals(address creditAccount, bool isForceCancel)
        external
        view
        returns (address token1, uint256 amount1, address token2, uint256 amount2);

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function creditManagers() external view returns (address[] memory);

    function setWithdrawalDelay(uint40 newDelay) external;

    function addCreditManager(address newCreditManager) external;
}
