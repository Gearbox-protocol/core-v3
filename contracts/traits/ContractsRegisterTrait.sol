// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IContractsRegister} from "../interfaces/IContractsRegister.sol";
import {RegisteredCreditManagerOnlyException, RegisteredPoolOnlyException} from "../interfaces/IExceptions.sol";

import {SanityCheckTrait} from "./SanityCheckTrait.sol";

/// @title Contracts register trait
/// @notice Trait that simplifies validation of pools and credit managers
abstract contract ContractsRegisterTrait is SanityCheckTrait {
    /// @notice Contracts register contract address
    address public immutable contractsRegister;

    /// @dev Ensures that given address is a registered credit manager
    modifier registeredPoolOnly(address addr) {
        _ensureRegisteredPool(addr);
        _;
    }

    /// @dev Ensures that given address is a registered pool
    modifier registeredCreditManagerOnly(address addr) {
        _ensureRegisteredCreditManager(addr);
        _;
    }

    /// @notice Constructor
    /// @param _contractsRegister Address provider contract address
    constructor(address _contractsRegister) nonZeroAddress(_contractsRegister) {
        contractsRegister = _contractsRegister;
    }

    /// @dev Ensures that given address is a registered pool
    function _ensureRegisteredPool(address addr) internal view {
        if (!_isRegisteredPool(addr)) revert RegisteredPoolOnlyException();
    }

    /// @dev Ensures that given address is a registered credit manager
    function _ensureRegisteredCreditManager(address addr) internal view {
        if (!_isRegisteredCreditManager(addr)) revert RegisteredCreditManagerOnlyException();
    }

    /// @dev Whether given address is a registered pool
    function _isRegisteredPool(address addr) internal view returns (bool) {
        return IContractsRegister(contractsRegister).isPool(addr);
    }

    /// @dev Whether given address is a registered credit manager
    function _isRegisteredCreditManager(address addr) internal view returns (bool) {
        return IContractsRegister(contractsRegister).isCreditManager(addr);
    }
}
