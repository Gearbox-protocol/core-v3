// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {
    AddressIsNotContractException, CallerNotControllerOrConfiguratorException
} from "../interfaces/IExceptions.sol";

import {ACLTrait} from "./ACLTrait.sol";

/// @title  Controlled trait
/// @notice Extended version of the ACL trait that introduces external controller role
abstract contract ControlledTrait is ACLTrait {
    /// @notice Emitted when new external controller is set
    event NewController(address indexed newController);

    /// @notice External controller address
    address public controller;

    /// @dev Ensures that function caller is external controller or configurator
    modifier controllerOrConfiguratorOnly() {
        _ensureCallerIsControllerOrConfigurator();
        _;
    }

    /// @notice Constructor
    /// @param acl ACL contract address
    constructor(address acl) ACLTrait(acl) {}

    /// @notice Sets new external controller contract, can only be called by configurator
    function setController(address newController) external configuratorOnly {
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
