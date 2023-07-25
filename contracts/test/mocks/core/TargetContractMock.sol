// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

/// @title Target Contract Mock
contract TargetContractMock {
    bytes public callData;

    constructor() {}

    fallback() external {
        callData = msg.data;
    }
}
