// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;
pragma abicoder v1;

/// @title WETHGatewayMock
contract WETHGatewayMock {
    mapping(address => uint256) public balanceOf;

    // CREDIT MANAGERS

    function depositFor(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function withdrawTo(address owner) external {}
}
