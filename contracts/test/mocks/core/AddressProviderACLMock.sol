// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import "../../lib/constants.sol";

/**
 * @title Address Provider that returns ACL and isConfigurator
 * @notice this contract is used to test LPPriceFeeds
 */
contract AddressProviderACLMock {
    address public getACL;
    mapping(address => bool) public isConfigurator;

    address public getPriceOracle;
    mapping(address => address) public priceFeeds;

    mapping(address => bool) public isPool;
    mapping(address => bool) public isCreditManager;

    address public getTreasuryContract;

    address public getContractsRegister;

    address public owner;

    address public getGearToken;

    constructor() {
        getACL = address(this);
        getPriceOracle = address(this);
        getContractsRegister = address(this);
        getTreasuryContract = FRIEND2;
        isConfigurator[msg.sender] = true;
        owner = msg.sender;
    }

    function setPriceFeed(address token, address feed) external {
        priceFeeds[token] = feed;
    }

    function setGearToken(address gearToken) external {
        getGearToken = gearToken;
    }

    function addPool(address pool) external {
        isPool[pool] = true;
    }

    function addCreditManager(address creditManager) external {
        isCreditManager[creditManager] = true;
    }

    receive() external payable {}
}
