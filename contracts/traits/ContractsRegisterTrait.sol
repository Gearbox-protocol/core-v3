// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {
    AddressIsNotContractException,
    RegisteredCreditManagerOnlyException,
    RegisteredPoolOnlyException
} from "../interfaces/IExceptions.sol";
import {IContractsRegister} from "../interfaces/base/IContractsRegister.sol";
import {IContractsRegisterTrait} from "../interfaces/base/IContractsRegisterTrait.sol";

/// @title  Contracts register trait
/// @notice Trait that simplifies validation of pools and credit managers
abstract contract ContractsRegisterTrait is IContractsRegisterTrait {
    /// @notice Contracts register contract address
    address public immutable override contractsRegister;

    /// @dev Ensures that given address is a registered pool
    modifier registeredPoolOnly(address addr) {
        _ensureRegisteredPool(addr);
        _;
    }

    /// @dev Ensures that given address is a registered credit manager
    modifier registeredCreditManagerOnly(address addr) {
        _ensureRegisteredCreditManager(addr);
        _;
    }

    /// @notice Constructor
    /// @param  contractsRegister_ Contracts register contract address
    constructor(address contractsRegister_) {
        if (contractsRegister_.code.length == 0) revert AddressIsNotContractException(contractsRegister_);
        contractsRegister = contractsRegister_;
    }

    /// @dev Ensures that given address is a registered pool
    function _ensureRegisteredPool(address addr) internal view {
        if (!IContractsRegister(contractsRegister).isPool(addr)) revert RegisteredPoolOnlyException();
    }

    /// @dev Ensures that given address is a registered credit manager
    function _ensureRegisteredCreditManager(address addr) internal view {
        if (!IContractsRegister(contractsRegister).isCreditManager(addr)) revert RegisteredCreditManagerOnlyException();
    }
}
