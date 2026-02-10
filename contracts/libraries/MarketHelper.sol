// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {IMatchingEngineV3} from "../interfaces/IMatchingEngineV3.sol";

interface IMarketConfigurator {
    function acl() external view returns (address);
    function contractsRegister() external view returns (address);
    function treasury() external view returns (address);
}

/// @title Market helper library
/// @notice Helper functions to retrieve ACL, contracts register and treasury from a matchingEngine or credit manager
/// @dev Accounts for different versions of markets within the new permissionless framework
library MarketHelper {
    /// @notice Retrieves the ACL address from a matchingEngine
    function getACL(IMatchingEngineV3 matchingEngine) internal view returns (address) {
        if (_version(matchingEngine) < 3_10) return _marketConfigurator(matchingEngine).acl();
        return matchingEngine.acl();
    }

    /// @notice Retrieves the ACL address from a credit manager
    function getACL(ICreditManagerV3 creditManager) internal view returns (address) {
        return getACL(_matchingEngine(creditManager));
    }

    /// @notice Retrieves the contracts register address from a matchingEngine
    function getContractsRegister(IMatchingEngineV3 matchingEngine) internal view returns (address) {
        if (_version(matchingEngine) < 3_10) return _marketConfigurator(matchingEngine).contractsRegister();
        return matchingEngine.contractsRegister();
    }

    /// @notice Retrieves the contracts register address from a credit manager
    function getContractsRegister(ICreditManagerV3 creditManager) internal view returns (address) {
        return getContractsRegister(_matchingEngine(creditManager));
    }

    /// @notice Retrieves the treasury address from a matchingEngine
    function getTreasury(IMatchingEngineV3 matchingEngine) internal view returns (address) {
        if (_version(matchingEngine) < 3_10) return _marketConfigurator(matchingEngine).treasury();
        return matchingEngine.treasury();
    }

    /// @notice Retrieves the treasury address from a credit manager
    function getTreasury(ICreditManagerV3 creditManager) internal view returns (address) {
        return getTreasury(_matchingEngine(creditManager));
    }

    /// @dev Retrieves the version of a matchingEngine
    function _version(IMatchingEngineV3 matchingEngine) private view returns (uint256) {
        return matchingEngine.version();
    }

    /// @dev Retrieves the market configurator (owner of both new and old ACLs) of a matchingEngine
    function _marketConfigurator(IMatchingEngineV3 matchingEngine) private view returns (IMarketConfigurator) {
        return IMarketConfigurator(Ownable(matchingEngine.acl()).owner());
    }

    /// @dev Retrieves the matchingEngine credit manager is connected to
    function _matchingEngine(ICreditManagerV3 creditManager) private view returns (IMatchingEngineV3) {
        return IMatchingEngineV3(creditManager.matchingEngine());
    }
}
