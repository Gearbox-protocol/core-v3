// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

// Repositories & services
bytes32 constant AP_CONTRACTS_REGISTER = "CONTRACTS_REGISTER";
bytes32 constant AP_ACL = "ACL";
bytes32 constant AP_PRICE_ORACLE = "PRICE_ORACLE";
bytes32 constant AP_ACCOUNT_FACTORY = "ACCOUNT_FACTORY";
bytes32 constant AP_DATA_COMPRESSOR = "DATA_COMPRESSOR";
bytes32 constant AP_TREASURY = "TREASURY";
bytes32 constant AP_GEAR_TOKEN = "GEAR_TOKEN";
bytes32 constant AP_WETH_TOKEN = "WETH_TOKEN";
bytes32 constant AP_WETH_GATEWAY = "WETH_GATEWAY";
bytes32 constant AP_WITHDRAWAL_MANAGER = "WITHDRAWAL_MANAGER";
bytes32 constant AP_ROUTER = "ROUTER";

interface IAddressProviderEvents {
    /// @dev Emits when an address is set for a contract role
    event AddressSet(bytes32 indexed service, address indexed newAddress, uint256 indexed version);
}

interface IAddressProviderV3 is IAddressProviderEvents, IVersion {
    function getAddressOrRevert(bytes32 key, uint256 _version) external view returns (address result);

    function setAddress(bytes32 key, address value, bool saveVersion) external;
}
