// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IContractsRegister} from "../interfaces/IContractsRegister.sol";
import {
    AddressIsNotContractException,
    RegisteredCreditManagerOnlyException,
    RegisteredPoolOnlyException,
    ZeroAddressException
} from "../interfaces/IExceptions.sol";

/// @title Contracts register trait
/// @notice Trait that simplifies validation of pools and credit managers
abstract contract ContractsRegisterTrait {
    /// @notice Contracts register contract address
    address public immutable contractsRegister;

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
    /// @param _contractsRegister Contracts register address
    constructor(address _contractsRegister) {
        if (_contractsRegister == address(0)) revert ZeroAddressException();
        if (_contractsRegister.code.length == 0) revert AddressIsNotContractException(_contractsRegister);
        contractsRegister = _contractsRegister;
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
