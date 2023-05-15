// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../interfaces/IAddressProviderV3.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";

import {
    ZeroAddressException,
    RegisteredCreditManagerOnlyException,
    RegisteredPoolOnlyException
} from "../interfaces/IExceptions.sol";

import {SanityCheckTrait} from "./SanityCheckTrait.sol";

/// @title ContractsRegister Trait
/// @notice Trait enables checks for registered pools & creditManagers
abstract contract ContractsRegisterTrait is SanityCheckTrait {
    // ACL contract to check rights
    ContractsRegister immutable _cr;

    /// @dev Checks that credit manager is registered
    modifier registeredCreditManagerOnly(address addr) {
        _checkRegisteredCreditManagerOnly(addr);
        _;
    }

    /// @dev Checks that credit manager is registered
    modifier registeredPoolOnly(address addr) {
        _checkRegisteredPoolOnly(addr);
        _;
    }

    constructor(address addressProvider) nonZeroAddress(addressProvider) {
        _cr = ContractsRegister(IAddressProviderV3(addressProvider).getAddressOrRevert(AP_CONTRACTS_REGISTER, 1));
    }

    function isRegisteredPool(address _pool) internal view returns (bool) {
        return _cr.isPool(_pool);
    }

    function isRegisteredCreditManager(address _creditManager) internal view returns (bool) {
        return _cr.isCreditManager(_creditManager);
    }

    function _checkRegisteredCreditManagerOnly(address addr) internal view {
        if (!isRegisteredCreditManager(addr)) revert RegisteredCreditManagerOnlyException();
    }

    function _checkRegisteredPoolOnly(address addr) internal view {
        if (!isRegisteredPool(addr)) revert RegisteredPoolOnlyException();
    }
}
