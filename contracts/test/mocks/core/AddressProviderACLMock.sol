// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../../../interfaces/IAddressProviderV3.sol";
import {PriceOracleMock} from "../oracles/PriceOracleMock.sol";
import {WETHGatewayMock} from "../support/WETHGatewayMock.sol";
import "../../lib/constants.sol";
import {Test} from "forge-std/Test.sol";

///
/// @title Address Provider that returns ACL and isConfigurator

contract AddressProviderACLMock is Test, IAddressProviderV3 {
    address public owner;

    mapping(address => bool) public isConfigurator;

    mapping(bytes32 => address) public getAddress;

    address public getACL;

    address public getPriceOracle;

    address public getTreasuryContract;

    address public getGearToken;

    address public getWethGateway;

    address public getWethToken;

    uint256 public constant version = 3_00;

    constructor() {
        getACL = address(this);
        getAddress[AP_ACL] = getACL;

        getPriceOracle = address(new PriceOracleMock());
        getAddress[AP_PRICE_ORACLE] = getPriceOracle;

        getWethGateway = address(new WETHGatewayMock());
        getAddress[AP_WETH_GATEWAY] = getWethGateway;

        getTreasuryContract = makeAddr("TREASURY");
        getAddress[AP_TREASURY] = getTreasuryContract;

        isConfigurator[msg.sender] = true;
        owner = msg.sender;
    }

    function setPriceOracle(address _priceOracle) external {
        getPriceOracle = _priceOracle;
    }

    function setGearToken(address gearToken) external {
        getGearToken = gearToken;
    }

    receive() external payable {}
}
