// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IAccountFactory} from "./base/IAccountFactory.sol";

interface IDefaultAccountFactoryV3Events {
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

/// @title Default account factory V3 interface
interface IDefaultAccountFactoryV3 is IAccountFactory, IDefaultAccountFactoryV3Events {
    function delay() external view returns (uint40);

    function rescue(address creditAccount, address target, bytes calldata data) external;
}
