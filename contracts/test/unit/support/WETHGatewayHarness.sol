// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {WETHGateway} from "../../../support/WETHGateway.sol";

contract WETHGatewayHarness is WETHGateway {
    constructor(address addressProvider_) WETHGateway(addressProvider_) {}

    function setReentrancyStatus(uint8 status) external {
        _reentrancyStatus = status;
    }
}
