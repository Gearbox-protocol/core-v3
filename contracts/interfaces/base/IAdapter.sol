// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {AdapterType} from "@gearbox-protocol/sdk-gov/contracts/AdapterType.sol";

/// @title Adapter interface
/// @notice Generic interface for an adapter that can be used to interact with external protocols
interface IAdapter {
    /// @notice Adapter type
    function _gearboxAdapterType() external view returns (AdapterType);

    /// @notice Adapter version
    /// @dev Doesn't follow `IVersion` for historic reasons
    function _gearboxAdapterVersion() external view returns (uint16);

    /// @notice Credit manager this adapter is connected to
    /// @dev Assumed to be an immutable state variable
    function creditManager() external view returns (address);

    /// @notice Target contract adapter helps to interact with
    /// @dev Assumed to be an immutable state variable
    function targetContract() external view returns (address);
}
