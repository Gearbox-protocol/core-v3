// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

interface IACL {
    function isConfigurator(address account) external view returns (bool);
    function isPausableAdmin(address addr) external view returns (bool);
    function isUnpausableAdmin(address addr) external view returns (bool);
}
