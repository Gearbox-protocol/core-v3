// SPDX-License-Identifier: UNLICENSED
// Gearbox. Generalized leverage protocol that allows to take leverage and then use it across other DeFi protocols and platforms in a composable way.
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {CollateralToken, IPoolV3DeployConfig, CollateralTokenHuman} from "../interfaces/ICreditConfig.sol";

contract ConfigManager {
    error ConfigNotFound();
    error ConfigAlreadyExists();

    mapping(bytes32 => IPoolV3DeployConfig) _configs;

    function addDeployConfig(IPoolV3DeployConfig config) internal {
        bytes32 key = keccak256(abi.encodePacked(config.symbol()));
        if (isDeployConfigExists(config.symbol())) revert ConfigAlreadyExists();
        _configs[key] = config;
    }

    function getDeployConfig(string memory symbol) internal view returns (IPoolV3DeployConfig) {
        bytes32 key = keccak256(abi.encodePacked(symbol));

        if (!isDeployConfigExists(symbol)) revert ConfigNotFound();

        return _configs[key];
    }

    function isDeployConfigExists(string memory symbol) internal view returns (bool) {
        bytes32 key = keccak256(abi.encodePacked(symbol));
        IPoolV3DeployConfig config = _configs[key];
        if (address(config) == address(0)) return false;
        return key == keccak256(abi.encodePacked(_configs[key].symbol()));
    }
}
