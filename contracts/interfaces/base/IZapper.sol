// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";

/// @title Zapper interface
/// @notice Generic interface for a zapper contract contract that can be used to perform complex batched
///         deposits into a pool which can, e.g., involve native token wrapping or staking pool's shares
/// @dev Zappers must have contract type `ZAPPER::{POSTFIX}`
interface IZapper is IVersion {
    /// @notice Pool a zapper deposits into
    function pool() external view returns (address);

    /// @notice Pool's underlying token
    function underlying() external view returns (address);

    /// @notice Zapper's input token
    function tokenIn() external view returns (address);

    /// @notice Zapper's output token
    function tokenOut() external view returns (address);
}
