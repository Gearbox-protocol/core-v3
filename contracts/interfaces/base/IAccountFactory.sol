// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";
import {IStateSerializer} from "./IStateSerializer.sol";

/// @title Account factory interface
/// @notice Generic interface for an account factory that can be used by credit managers to create credit accounts
/// @dev Account factories must have type `ACCOUNT_FACTORY::{POSTFIX}`
interface IAccountFactory is IVersion, IStateSerializer {
    /// @notice Takes `creditAccount` from the account factory
    /// @dev Parameters are kept for backward compatibility
    function takeCreditAccount(uint256, uint256) external returns (address creditAccount);

    /// @notice Returns `creditAccount` to the account factory
    function returnCreditAccount(address creditAccount) external;

    /// @notice Connects `creditManager` to the account factory, allowing it to take and return credit accounts
    function addCreditManager(address creditManager) external;
}
