// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {IPoolV3} from "../interfaces/IPoolV3.sol";

interface IMarketConfigurator {
    function acl() external view returns (address);
    function contractsRegister() external view returns (address);
    function treasury() external view returns (address);
}

/// @title Market helper library
/// @notice Helper functions to retrieve ACL, contracts register and treasury from a pool or credit manager
/// @dev Accounts for different versions of markets within the new permissionless framework
library MarketHelper {
    /// @notice Retrieves the ACL address from a pool
    function getACL(IPoolV3 pool) internal view returns (address) {
        if (_version(pool) < 3_10) return _marketConfigurator(pool).acl();
        return pool.acl();
    }

    /// @notice Retrieves the ACL address from a credit manager
    function getACL(ICreditManagerV3 creditManager) internal view returns (address) {
        return getACL(_pool(creditManager));
    }

    /// @notice Retrieves the contracts register address from a pool
    function getContractsRegister(IPoolV3 pool) internal view returns (address) {
        if (_version(pool) < 3_10) return _marketConfigurator(pool).contractsRegister();
        return pool.contractsRegister();
    }

    /// @notice Retrieves the contracts register address from a credit manager
    function getContractsRegister(ICreditManagerV3 creditManager) internal view returns (address) {
        return getContractsRegister(_pool(creditManager));
    }

    /// @notice Retrieves the treasury address from a pool
    function getTreasury(IPoolV3 pool) internal view returns (address) {
        if (_version(pool) < 3_10) return _marketConfigurator(pool).treasury();
        return pool.treasury();
    }

    /// @notice Retrieves the treasury address from a credit manager
    function getTreasury(ICreditManagerV3 creditManager) internal view returns (address) {
        return getTreasury(_pool(creditManager));
    }

    /// @dev Retrieves the version of a pool
    function _version(IPoolV3 pool) private view returns (uint256) {
        return pool.version();
    }

    /// @dev Retrieves the market configurator (owner of both new and old ACLs) of a pool
    function _marketConfigurator(IPoolV3 pool) private view returns (IMarketConfigurator) {
        return IMarketConfigurator(Ownable(pool.acl()).owner());
    }

    /// @dev Retrieves the pool credit manager is connected to
    function _pool(ICreditManagerV3 creditManager) private view returns (IPoolV3) {
        return IPoolV3(creditManager.pool());
    }
}
