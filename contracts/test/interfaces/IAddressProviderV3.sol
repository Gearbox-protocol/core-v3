// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.23;

uint256 constant NO_VERSION_CONTROL = 0;

bytes32 constant AP_ACCOUNT_FACTORY = "ACCOUNT_FACTORY";
bytes32 constant AP_ACL = "ACL";
bytes32 constant AP_BOT_LIST = "BOT_LIST";
bytes32 constant AP_CONTRACTS_REGISTER = "CONTRACTS_REGISTER";
bytes32 constant AP_GEAR_STAKING = "GEAR_STAKING";
bytes32 constant AP_GEAR_TOKEN = "GEAR_TOKEN";
bytes32 constant AP_PRICE_ORACLE = "PRICE_ORACLE";
bytes32 constant AP_TREASURY = "TREASURY";
bytes32 constant AP_WETH_TOKEN = "WETH_TOKEN";

interface IAddressProviderV3 {
    function getAddressOrRevert(bytes32 key, uint256 _version) external view returns (address result);

    function setAddress(bytes32 key, address value, bool saveVersion) external;
}
