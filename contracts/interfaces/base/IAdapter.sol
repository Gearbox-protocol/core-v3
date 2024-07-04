// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {IVersion} from "./IVersion.sol";

/// @title Adapter interface
/// @notice Generic interface for an adapter that can be used to interact with external protocols
interface IAdapter is IVersion {
    /// @notice Credit manager this adapter is connected to
    /// @dev Assumed to be an immutable state variable
    function creditManager() external view returns (address);

    /// @notice Target contract adapter helps to interact with
    /// @dev Assumed to be an immutable state variable
    function targetContract() external view returns (address);
}
