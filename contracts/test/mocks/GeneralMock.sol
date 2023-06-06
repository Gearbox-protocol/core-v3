// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

contract GeneralMock {
    bytes public data;

    fallback() external {
        data = msg.data;
    }

    receive() external payable {}
}
