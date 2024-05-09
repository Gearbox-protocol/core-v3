// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

abstract contract ContractRegisterOwnerTrait is ContractsRegisterTrait {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet internal _pools;
    EnumerableSet.AddressSet internal _creditManagers;

    constructor(address) ContractsRegisterTrait(address(this)) {}

    /// @dev Whether given address is a registered pool
    function _isRegisteredPool(address addr) internal view override returns (bool) {
        return _pools.contains(addr);
    }

    /// @dev Whether given address is a registered credit manager
    function _isRegisteredCreditManager(address addr) internal view override returns (bool) {
        return _creditManagers.contains(addr);
    }

    function _addPool(address pool) internal {
        _pools.add(pool);
    }

    function _removePool(address pool) internal {
        _pools.remove(pool);
    }

    function _addCreditManager(address creditManager) internal {
        _creditManagers.add(creditManager);
    }

    function _removeCreditManager(address creditManager) internal {
        _creditManagers.remove(creditManager);
    }

    /// @dev Returns the array of registered pools
    function pools() external view returns (address[] memory) {
        return _pools.values();
    }

    /// @dev Returns true if the passed address is a pool
    function isPool(address pool) external view returns (bool) {
        return _pools.contains(pool);
    }

    /// @dev Returns the array of registered Credit Managers
    function creditManagers() external view returns (address[] memory) {
        return _creditManagers.values();
    }

    /// @dev Returns true if the passed address is a Credit Manager
    function isCreditManager(address creditManager) external view returns (bool) {
        return _creditManagers.contains(creditManager);
    }
}
