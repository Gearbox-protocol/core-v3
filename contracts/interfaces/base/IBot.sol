// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";

/// @title Bot interface
/// @notice Minimal interface contracts must conform to in order to be used as bots in Gearbox V3
/// @dev Bots must have type `BOT::{POSTFIX}`
interface IBot is IVersion {
    /// @notice Mask of permissions required for bot operation, see `ICreditFacadeV3Multicall`
    function requiredPermissions() external view returns (uint192);
}
