// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../../../core/AddressProviderV3.sol";
import {AccountFactoryMock} from "../core/AccountFactoryMock.sol";
import {PriceOracleMock} from "../oracles/PriceOracleMock.sol";
import {WETHGatewayMock} from "../support/WETHGatewayMock.sol";
import {WithdrawalManagerMock} from "../support/WithdrawalManagerMock.sol";
import "../../lib/constants.sol";
import {Test} from "forge-std/Test.sol";

///
/// @title Address Provider that returns ACL and isConfigurator

contract AddressProviderV3ACLMock is Test, AddressProviderV3 {
    address public owner;
    mapping(address => bool) public isConfigurator;

    mapping(address => bool) public isPool;
    mapping(address => bool) public isCreditManager;

    mapping(address => bool) public isPausableAdmin;
    mapping(address => bool) public isUnpausableAdmin;

    constructor() AddressProviderV3(address(this)) {
        PriceOracleMock priceOracleMock = new PriceOracleMock();
        _setAddress(AP_PRICE_ORACLE, address(priceOracleMock), priceOracleMock.version());

        WETHGatewayMock wethGatewayMock = new WETHGatewayMock();
        _setAddress(AP_WETH_GATEWAY, address(wethGatewayMock), wethGatewayMock.version());

        WithdrawalManagerMock withdrawalManagerMock = new WithdrawalManagerMock();
        _setAddress(AP_WITHDRAWAL_MANAGER, address(withdrawalManagerMock), withdrawalManagerMock.version());

        AccountFactoryMock accountFactoryMockV1 = new AccountFactoryMock(1);
        _setAddress(AP_ACCOUNT_FACTORY, address(accountFactoryMockV1), accountFactoryMockV1.version());

        AccountFactoryMock accountFactoryMockV3 = new AccountFactoryMock(3_00);
        _setAddress(AP_ACCOUNT_FACTORY, address(accountFactoryMockV3), accountFactoryMockV3.version());

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

    /// @dev Adds an address to the set of admins that can pause contracts
    /// @param newAdmin Address of a new pausable admin
    function addPausableAdmin(address newAdmin) external {
        isPausableAdmin[newAdmin] = true;
    }

    /// @dev Adds unpausable admin address to the list
    /// @param newAdmin Address of new unpausable admin
    function addUnpausableAdmin(address newAdmin) external {
        isUnpausableAdmin[newAdmin] = true;
    }

    receive() external payable {}
}
