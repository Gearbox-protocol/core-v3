// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {IVersion} from "./base/IVersion.sol";

/// @title Account factory V3 interface
interface IAccountFactoryV3 is IVersion {
    // ------ //
    // EVENTS //
    // ------ //

    /// @notice Emitted when new credit account is deployed
    event DeployCreditAccount(address indexed creditAccount, address indexed creditManager);

    /// @notice Emitted when credit account is taken by the credit manager
    event TakeCreditAccount(address indexed creditAccount, address indexed creditManager);

    /// @notice Emitted when used credit account is returned to the queue
    event ReturnCreditAccount(address indexed creditAccount, address indexed creditManager);

    /// @notice Emitted when new credit manager is added to the factory
    event AddCreditManager(address indexed creditManager, address masterCreditAccount);

    /// @notice Emitted when owner performs a proxy call from credit account to rescue funds
    event Rescue(address indexed creditAccount, address indexed target, bytes data);

    // --------- //
    // FUNCTIONS //
    // --------- //

    function delay() external view returns (uint40);

    function isCreditManagerAdded(address creditManager) external view returns (bool);

    function creditManagers() external view returns (address[] memory);

    function takeCreditAccount(uint256, uint256) external returns (address creditAccount);

    function returnCreditAccount(address creditAccount) external;

    function addCreditManager(address creditManager) external;

    function rescue(address creditAccount, address target, bytes calldata data) external;
}
