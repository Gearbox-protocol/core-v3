// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

interface IContractsRegister {
    function isPool(address) external view returns (bool);
    function getPools() external view returns (address[] memory);
    function isCreditManager(address) external view returns (bool);
    function getCreditManagers() external view returns (address[] memory);
}
