// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../../../core/AddressProviderV3.sol";
import {PriceOracleMock} from "../oracles/PriceOracleMock.sol";
import {WETHGatewayMock} from "../support/WETHGatewayMock.sol";
import "../../lib/constants.sol";
import {Test} from "forge-std/Test.sol";

///
/// @title Address Provider that returns ACL and isConfigurator

contract AddressProviderACLMock is Test, AddressProviderV3 {
    address public owner;
    mapping(address => bool) public isConfigurator;

    mapping(address => bool) public isPool;
    mapping(address => bool) public isCreditManager;

    constructor() AddressProviderV3(address(this)) {
        PriceOracleMock priceOracleMock = new PriceOracleMock();
        _setAddress(AP_PRICE_ORACLE, address(priceOracleMock), priceOracleMock.version());

        WETHGatewayMock wETHGatewayMock = new WETHGatewayMock();
        _setAddress(AP_WETH_GATEWAY, address(wETHGatewayMock), wETHGatewayMock.version());

        _setAddress(AP_CONTRACTS_REGISTER, address(this), 1);

        _setAddress(AP_TREASURY, makeAddr("TREASURY"), 0);

        isConfigurator[msg.sender] = true;
        owner = msg.sender;
    }

    function addPool(address pool) external {
        isPool[pool] = true;
    }

    function addCreditManager(address creditManager) external {
        isCreditManager[creditManager] = true;
    }

    receive() external payable {}
}
