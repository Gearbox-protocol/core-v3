// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./base/IVersion.sol";

interface IAccountFactoryV3Events {
    /// @notice Emitted when new credit account is deployed
    event DeployCreditAccount(address indexed creditAccount, address indexed creditManager);

    /// @notice Emitted when credit account is taken by the credit manager
    event TakeCreditAccount(address indexed creditAccount, address indexed creditManager);

    /// @notice Emitted when used credit account is returned to the queue
    event ReturnCreditAccount(address indexed creditAccount, address indexed creditManager);

    /// @notice Emitted when new credit manager is added to the factory
    event AddCreditManager(address indexed creditManager, address masterCreditAccount);

    /// @notice Emitted when the DAO performs a proxy call from Credit Account to rescue funds
    event Rescue(address indexed creditAccount, address indexed target, bytes data);
}

/// @title Account factory V3 interface
interface IAccountFactoryV3 is IVersion, IAccountFactoryV3Events {
    function delay() external view returns (uint40);

    function takeCreditAccount(uint256, uint256) external returns (address creditAccount);

    function returnCreditAccount(address creditAccount) external;

    function addCreditManager(address creditManager) external;

    function rescue(address creditAccount, address target, bytes calldata data) external;
}
