// SPDX-License-Identifier: UNLICENSED
// Gearbox. Generalized leverage protocol that allows to take leverage and then use it across other DeFi protocols and platforms in a composable way.
// (c) Gearbox Foundation, 2023
pragma solidity ^0.8.17;

import {IPoolV3DeployConfig, CollateralTokenHuman} from "../interfaces/ICreditConfig.sol";

contract ConfigManager {
    error ConfigNotFound(string id);
    error ConfigAlreadyExists(string id);

    mapping(bytes32 => IPoolV3DeployConfig) _configs;

    function addDeployConfig(IPoolV3DeployConfig config) internal {
        bytes32 key = keccak256(abi.encodePacked(config.id()));
        if (isDeployConfigExists(config.id())) revert ConfigAlreadyExists(config.id());
        _configs[key] = config;
    }

    function getDeployConfig(string memory id) internal view returns (IPoolV3DeployConfig) {
        bytes32 key = keccak256(abi.encodePacked(id));

        if (!isDeployConfigExists(id)) revert ConfigNotFound(id);

        return _configs[key];
    }

    function isDeployConfigExists(string memory id) internal view returns (bool) {
        bytes32 key = keccak256(abi.encodePacked(id));
        IPoolV3DeployConfig config = _configs[key];
        if (address(config) == address(0)) return false;
        return key == keccak256(abi.encodePacked(_configs[key].id()));
    }
}
