// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

/// @title Account factory base interface
/// @notice Functions shared accross newer and older versions
interface IAccountFactoryBase is IVersion {
    function takeCreditAccount(uint256, uint256) external returns (address creditAccount);
    function returnCreditAccount(address creditAccount) external;
}

interface IAccountFactoryV3Events {
    /// @notice Emitted when new credit account is deployed
    event DeployCreditAccount(address indexed creditAccount, address indexed creditManager);

    /// @notice Emitted when credit account is taken by the credit manager
    event TakeCreditAccount(address indexed creditAccount, address indexed creditManager);

    /// @notice Emitted when used credit account is returned to the queue
    event ReturnCreditAccount(address indexed creditAccount, address indexed creditManager);

    /// @notice Emitted when new credit manager is added to the factory
    event AddCreditManager(address indexed creditManager, address masterCreditAccount);
}

/// @title Account factory V3 interface
interface IAccountFactoryV3 is IAccountFactoryBase, IAccountFactoryV3Events {
    /// @notice Delay after which returned credit accounts can be reused
    function delay() external view returns (uint40);

    /// @notice Provides a reusable credit account from the queue to the credit manager.
    ///         If there are no accounts that can be reused in the queue, deploys a new one.
    /// @return creditAccount Address of the provided credit account
    /// @dev Parameters are ignored and only kept for backward compatibility
    /// @custom:expects Credit manager sets account's borrower to non-zero address after calling this function
    function takeCreditAccount(uint256, uint256) external override returns (address creditAccount);

    /// @notice Returns a used credit account to the queue
    /// @param creditAccount Address of the returned credit account
    /// @custom:expects Credit account is connected to the calling credit manager
    /// @custom:expects Credit manager sets account's borrower to zero-address before calling this function
    function returnCreditAccount(address creditAccount) external override;

    /// @notice Adds a credit manager to the factory and deploys the master credit account for it
    /// @param creditManager Credit manager address
    function addCreditManager(address creditManager) external;

    /// @notice Executes function call from the account to the target contract with provided data,
    ///         can only be called by configurator when account is not in use by anyone.
    ///         Allows to rescue funds that were accidentally left on the account upon closure.
    /// @param creditAccount Credit account to execute the call from
    /// @param target Contract to call
    /// @param data Data to call the target contract with
    function rescue(address creditAccount, address target, bytes calldata data) external;
}
