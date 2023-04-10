// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IAddressProvider} from "@gearbox-protocol/core-v2/contracts/interfaces/IAddressProvider.sol";
import {AdapterType} from "@gearbox-protocol/core-v2/contracts/interfaces/adapters/IAdapter.sol";
import {ICreditManagerV2} from "./ICreditManagerV2.sol";

/// @title Adapter interface
interface IAdapter {
    /// @notice Credit Manager the adapter is connected to
    function creditManager() external view returns (ICreditManagerV2);

    /// @notice Address of the contract the adapter is interacting with
    function targetContract() external view returns (address);

    /// @notice Address provider
    function addressProvider() external view returns (IAddressProvider);

    /// @notice Adapter type
    function _gearboxAdapterType() external pure returns (AdapterType);

    /// @notice Adapter version
    function _gearboxAdapterVersion() external pure returns (uint16);
}
