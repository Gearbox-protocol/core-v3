// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {
    AddressIsNotContractException, CallerNotControllerOrConfiguratorException
} from "../interfaces/IExceptions.sol";
import {IControlledTrait} from "../interfaces/base/IControlledTrait.sol";

import {ACLTrait} from "./ACLTrait.sol";

/// @title  Controlled trait
/// @notice Extended version of the ACL trait that introduces external controller role
abstract contract ControlledTrait is ACLTrait, IControlledTrait {
    /// @notice External controller address
    address public override controller;

    /// @dev Ensures that function caller is external controller or configurator
    modifier controllerOrConfiguratorOnly() {
        _ensureCallerIsControllerOrConfigurator();
        _;
    }

    /// @notice Constructor
    /// @param  acl_ ACL contract address
    /// @dev    Reverts if `acl_` is zero address or is not a contract
    constructor(address acl_) ACLTrait(acl_) {}

    /// @notice Sets new external controller, can only be called by configurator
    /// @dev    Reverts if `newController` is not a contract
    function setController(address newController) external override configuratorOnly {
        if (controller == newController) return;
        if (newController.code.length == 0) revert AddressIsNotContractException(newController);
        controller = newController;
        emit NewController(newController);
    }

    /// @dev Reverts if the caller is not controller or configurator
    /// @dev Used to cut contract size on modifiers
    function _ensureCallerIsControllerOrConfigurator() internal view {
        if (msg.sender != controller && !_isConfigurator(msg.sender)) {
            revert CallerNotControllerOrConfiguratorException();
        }
    }
}
