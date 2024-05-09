// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";

uint256 constant NO_VERSION_CONTROL = 0;

// string constant AP_CONTRACTS_REGISTER = "CONTRACTS_REGISTER";
// string constant AP_ACL = "ACL";
// string constant AP_PRICE_ORACLE = "PRICE_ORACLE";
string constant AP_ACCOUNT_FACTORY = "ACCOUNT_FACTORY";
// string constant AP_DATA_COMPRESSOR = "DATA_COMPRESSOR";
string constant AP_TREASURY = "TREASURY";
string constant AP_GEAR_TOKEN = "GEAR_TOKEN";
string constant AP_WETH_TOKEN = "WETH_TOKEN";
// string constant AP_WETH_GATEWAY = "WETH_GATEWAY";
string constant AP_ROUTER = "ROUTER";
string constant AP_BOT_LIST = "BOT_LIST";
string constant AP_GEAR_STAKING = "GEAR_STAKING";
string constant AP_ZAPPER_REGISTER = "ZAPPER_REGISTER";

interface IAddressProviderV3Events {
    /// @notice Emitted when an address is set for a contract key
    event SetAddress(string key, address indexed value, uint256 version);

    /// @notice Emitted when a new market configurator added
    event AddMarketConfigurator(address indexed marketConfigurator);

    /// @notice Emitted when existing market configurator was removed
    event RemoveMarketConfigurator(address indexed marketConfigurator);
}

/// @title Address provider V3 interface
interface IAddressProviderV3 is IAddressProviderV3Events, IVersion {
    function owner() external view returns (address);

    function addresses(string memory key, uint256 _version) external view returns (address);

    function getAddressOrRevert(string memory key, uint256 _version) external view returns (address result);

    function setAddress(string memory key, address value, bool saveVersion) external;

    function addMarketConfigurator(address _marketConfigurator) external;

    function removeMarketConfigurator(address _marketConfigurator) external;

    function marketConfigurators() external view returns (address[] memory);

    function isMarketConfigurator(address riskCurator) external view returns (bool);

    function registerCreditManager(address creditManager) external;
}
