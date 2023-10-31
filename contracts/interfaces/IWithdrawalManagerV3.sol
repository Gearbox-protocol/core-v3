// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

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

    function isValidCreditManager(address) external view returns (bool);

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function addCreditManager(address newCreditManager) external;
}
