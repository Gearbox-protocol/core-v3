// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

uint256 constant NO_VERSION_CONTROL = 0;

string constant AP_ACCOUNT_FACTORY = "ACCOUNT_FACTORY";
string constant AP_ACL = "ACL";
string constant AP_BOT_LIST = "BOT_LIST";
string constant AP_CONTRACTS_REGISTER = "CONTRACTS_REGISTER";
string constant AP_GEAR_STAKING = "GEAR_STAKING";
string constant AP_GEAR_TOKEN = "GEAR_TOKEN";
string constant AP_PRICE_ORACLE = "PRICE_ORACLE";
string constant AP_TREASURY = "TREASURY";
string constant AP_WETH_TOKEN = "WETH_TOKEN";

interface IAddressProviderV3 {
    function getAddressOrRevert(string calldata key, uint256 _version) external view returns (address result);

    function setAddress(string calldata key, address value, bool saveVersion) external;
}
