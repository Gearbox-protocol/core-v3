// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

/// @title State serializer interface
/// @notice Generic interface for a contract that can serialize its state into a bytes array
interface IStateSerializer {
    /// @notice Serializes the state of the contract into a bytes array `serializedData`
    function serialize() external view returns (bytes memory serializedData);
}
