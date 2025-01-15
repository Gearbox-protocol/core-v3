// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

interface IAddressProvider {
    function getAddressOrRevert(bytes32 key, uint256 version) external view returns (address);
}
