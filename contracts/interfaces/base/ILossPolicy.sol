// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";

/// @title Loss policy interface
/// @notice Generic interface for a loss policy contract that dictates conditions under which a liquidation with bad debt
///         can proceed. For example, it can restrict such liquidations to only be performed by whitelisted accounts that
///         can return premium to the DAO to recover part of the losses, or prevent liquidations of an asset whose market
///         price drops for a short period of time while its fundamental value doesn't change.
/// @dev Loss policies must have type `LOSS_POLICY::{POSTFIX}`
interface ILossPolicy is IVersion {
    /// @notice Whether `creditAccount` can be liquidated with loss by `caller`, `data` is an optional field
    ///         that can be used to pass some off-chain data specific to the loss policy implementation
    function isLiquidatable(address creditAccount, address caller, bytes calldata data) external returns (bool);

    /// @notice Emergency function which forces `isLiquidatable` to always return `false`
    function disable() external;

    /// @notice Emergency function which forces `isLiquidatable` to always return `true`
    function enable() external;
}
