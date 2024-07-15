// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IVersion} from "../../../interfaces/base/IVersion.sol";

import "../../interfaces/IAddressProviderV3.sol";

import {AccountFactoryMock} from "../core/AccountFactoryMock.sol";
import {PriceOracleMock} from "../oracles/PriceOracleMock.sol";
import {BotListMock} from "../core/BotListMock.sol";
import {WETHMock} from "../token/WETHMock.sol";

contract AddressProviderV3ACLMock is Test, IAddressProviderV3, Ownable {
    mapping(bytes32 => mapping(uint256 => address)) addresses;

    mapping(address => bool) public isPool;
    mapping(address => bool) public isCreditManager;

    mapping(address => bool) public isPausableAdmin;
    mapping(address => bool) public isUnpausableAdmin;

    constructor() {
        _setAddress(AP_ACL, address(this), NO_VERSION_CONTROL);
        _setAddress(AP_CONTRACTS_REGISTER, address(this), 0);

        PriceOracleMock priceOracleMock = new PriceOracleMock();
        _setAddress(AP_PRICE_ORACLE, address(priceOracleMock), priceOracleMock.version());

        AccountFactoryMock accountFactoryMock = new AccountFactoryMock(3_10);
        _setAddress(AP_ACCOUNT_FACTORY, address(accountFactoryMock), 3_10);

        BotListMock botListMock = new BotListMock();
        _setAddress(AP_BOT_LIST, address(botListMock), 3_10);

        _setAddress(AP_TREASURY, address(123456), 0);

        _setAddress(AP_WETH_TOKEN, address(new WETHMock()), 0);
    }

    function isConfigurator(address addr) external view returns (bool) {
        return addr == owner();
    }

    function getACL() external view returns (address) {
        return address(this);
    }

    function getContractsRegister() external view returns (address) {
        return address(this);
    }

    function getAddressOrRevert(bytes32 key, uint256 _version) public view virtual override returns (address result) {
        result = addresses[key][_version];
        require(
            result != address(0),
            string.concat(
                "Address not found, key: ", string(abi.encodePacked(key)), ", version: ", vm.toString(_version)
            )
        );
    }

    function setAddress(bytes32 key, address value, bool saveVersion) external override {
        _setAddress(key, value, saveVersion ? IVersion(value).version() : NO_VERSION_CONTROL);
    }

    function _setAddress(bytes32 key, address value, uint256 _version) internal virtual {
        addresses[key][_version] = value;
    }

    function addPool(address pool) external {
        isPool[pool] = true;
    }

    function addCreditManager(address creditManager) external {
        isCreditManager[creditManager] = true;
    }

    function addPausableAdmin(address newAdmin) external {
        isPausableAdmin[newAdmin] = true;
    }

    function addUnpausableAdmin(address newAdmin) external {
        isUnpausableAdmin[newAdmin] = true;
    }
}
