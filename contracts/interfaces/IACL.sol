// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";

/// @title ACL interface
interface IACL is IVersion {
    function owner() external view returns (address);
    function isConfigurator(address account) external view returns (bool);

    function isPausableAdmin(address addr) external view returns (bool);
    function addPausableAdmin(address addr) external;

    function isUnpausableAdmin(address addr) external view returns (bool);
    function addUnpausableAdmin(address addr) external;
}
