// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

interface IBytecodeRepositoryEvents {}

/// @title Bot list V3 interface
interface IBytecodeRepository is IBytecodeRepositoryEvents, IVersion {
    function deploy(string memory contactType, uint256 version, bytes memory constructorParams, bytes32 salt)
        external
        returns (address);
}
