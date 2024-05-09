// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {AdapterType} from "@gearbox-protocol/sdk-gov/contracts/AdapterType.sol";

/// @title Adapter interface
interface IAdapter {
    function _gearboxAdapterType() external view returns (AdapterType);

    function _gearboxAdapterVersion() external view returns (uint16);

    function creditManager() external view returns (address);

    function targetContract() external view returns (address);
}
