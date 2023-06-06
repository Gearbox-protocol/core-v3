// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {AdapterType} from "@gearbox-protocol/integration-types/contracts/AdapterType.sol";

/// @title Adapter interface
interface IAdapter {
    function creditManager() external view returns (address);

    function addressProvider() external view returns (address);

    function targetContract() external view returns (address);

    function _gearboxAdapterType() external pure returns (AdapterType);

    function _gearboxAdapterVersion() external pure returns (uint16);
}
