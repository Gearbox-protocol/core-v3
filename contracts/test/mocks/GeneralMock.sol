// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

contract GeneralMock {
    bytes public data;

    fallback() external {
        data = msg.data;
    }
}
