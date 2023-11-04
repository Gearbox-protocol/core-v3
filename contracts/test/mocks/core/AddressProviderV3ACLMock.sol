// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../../../core/AddressProviderV3.sol";
import {AccountFactoryMock} from "../core/AccountFactoryMock.sol";
import {PriceOracleMock} from "../oracles/PriceOracleMock.sol";
import {BotListMock} from "../core/BotListMock.sol";
import {WETHMock} from "../token/WETHMock.sol";

import {Test} from "forge-std/Test.sol";

import "forge-std/console.sol";

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

        AccountFactoryMock accountFactoryMock = new AccountFactoryMock(3_00);
        _setAddress(AP_ACCOUNT_FACTORY, address(accountFactoryMock), NO_VERSION_CONTROL);

        BotListMock botListMock = new BotListMock();
        _setAddress(AP_BOT_LIST, address(botListMock), 3_00);

        _setAddress(AP_CONTRACTS_REGISTER, address(this), 0);

        _setAddress(AP_TREASURY, makeAddr("TREASURY"), 0);

        _setAddress(AP_WETH_TOKEN, address(new WETHMock()), 0);

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

    function getAddressOrRevert(bytes32 key, uint256 _version) public view override returns (address result) {
        result = addresses[key][_version];
        if (result == address(0)) {
            string memory keyString = bytes32ToString(key);
            console.log("AddressProviderV3: Cant find ", keyString, ", version:", _version);
        }

        return super.getAddressOrRevert(key, _version);
    }

    function bytes32ToString(bytes32 _bytes32) internal pure returns (string memory) {
        uint8 i = 0;
        while (i < 32 && _bytes32[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (i = 0; i < 32 && _bytes32[i] != 0; i++) {
            bytesArray[i] = _bytes32[i];
        }
        return string(bytesArray);
    }
}
