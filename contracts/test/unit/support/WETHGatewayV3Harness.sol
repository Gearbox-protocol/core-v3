// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {WETHGatewayV3} from "../../../support/WETHGatewayV3.sol";

contract WETHGatewayV3Harness is WETHGatewayV3 {
    constructor(address addressProvider_) WETHGatewayV3(addressProvider_) {}

    function setReentrancyStatus(uint8 status) external {
        _reentrancyStatus = status;
    }
}
