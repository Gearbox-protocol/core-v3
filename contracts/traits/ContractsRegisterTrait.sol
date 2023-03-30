// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {AddressProvider} from "@gearbox-protocol/core-v2/contracts/core/AddressProvider.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";

import {
    ZeroAddressException,
    RegisteredCreditManagerOnlyException,
    RegisteredPoolOnlyException
} from "../interfaces/IExceptions.sol";

/// @title ContractsRegister Trait
/// @notice Trait enables checks for registered pools & creditManagers
abstract contract ContractsRegisterTrait {
    // ACL contract to check rights
    ContractsRegister immutable _cr;

    constructor(address addressProvider) {
        if (addressProvider == address(0)) revert ZeroAddressException(); // F:[P4-2]
        _cr = ContractsRegister(AddressProvider(addressProvider).getContractsRegister());
    }

    function isRegisteredPool(address _pool) internal view returns (bool) {
        return _cr.isPool(_pool);
    }

    function isRegisteredCreditManager(address _pool) internal view returns (bool) {
        return _cr.isCreditManager(_pool);
    }

    /// @dev Checks that credit manager is registered
    modifier registeredCreditManagerOnly(address addr) {
        if (!isRegisteredCreditManager(addr)) revert RegisteredCreditManagerOnlyException(); // T:[WG-3]

        _;
    }

    /// @dev Checks that credit manager is registered
    modifier registeredPoolOnly(address addr) {
        if (!isRegisteredPool(addr)) revert RegisteredPoolOnlyException();

        _;
    }
}
