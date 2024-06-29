// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

import {IACL} from "../interfaces/IACL.sol";
import {
    AddressIsNotContractException,
    CallerNotConfiguratorException,
    CallerNotControllerOrConfiguratorException,
    CallerNotPausableAdminException,
    CallerNotUnpausableAdminException
} from "../interfaces/IExceptions.sol";
import {IACLTrait} from "../interfaces/base/IACLTrait.sol";

import {ReentrancyGuardTrait} from "./ReentrancyGuardTrait.sol";
import {SanityCheckTrait} from "./SanityCheckTrait.sol";

/// @title ACL trait
/// @notice Utility class for ACL (access-control list) consumers that implements pausable functionality,
///         reentrancy protection and external controller role
abstract contract ACLTrait is IACLTrait, Pausable, ReentrancyGuardTrait, SanityCheckTrait {
    /// @notice ACL contract address
    address public immutable override acl;

    /// @notice External controller address
    address public override controller;

    /// @dev Ensures that function caller is configurator
    modifier configuratorOnly() {
        _ensureCallerIsConfigurator();
        _;
    }

    /// @dev Ensures that function caller is external controller or configurator
    modifier controllerOrConfiguratorOnly() {
        _ensureCallerIsControllerOrConfigurator();
        _;
    }

    /// @dev Ensures that function caller has pausable admin role
    modifier pausableAdminsOnly() {
        _ensureCallerIsPausableAdmin();
        _;
    }

    /// @dev Ensures that function caller has unpausable admin role
    modifier unpausableAdminsOnly() {
        _ensureCallerIsUnpausableAdmin();
        _;
    }

    /// @notice Constructor
    /// @param acl_ ACL contract address
    constructor(address acl_) nonZeroAddress(acl_) {
        acl = acl_;
    }

    /// @notice Pauses contract, can only be called by an account with pausable admin role
    /// @dev Reverts if contract is already paused
    function pause() external virtual pausableAdminsOnly {
        _pause();
    }

    /// @notice Unpauses contract, can only be called by an account with unpausable admin role
    /// @dev Reverts if contract is already unpaused
    function unpause() external virtual unpausableAdminsOnly {
        _unpause();
    }

    /// @notice Sets new external controller, can only be called by configurator
    function setController(address newController) external override configuratorOnly {
        if (controller == newController) return;
        if (newController.code.length == 0) revert AddressIsNotContractException(newController);
        controller = newController;
        emit NewController(newController);
    }

    /// @dev Reverts if the caller is not the configurator
    /// @dev Used to cut contract size on modifiers
    function _ensureCallerIsConfigurator() internal view {
        if (!_isConfigurator(msg.sender)) revert CallerNotConfiguratorException();
    }

    /// @dev Reverts if the caller is not controller or configurator
    /// @dev Used to cut contract size on modifiers
    function _ensureCallerIsControllerOrConfigurator() internal view {
        if (msg.sender != controller && !_isConfigurator(msg.sender)) {
            revert CallerNotControllerOrConfiguratorException();
        }
    }

    /// @dev Reverts if the caller is not pausable admin
    /// @dev Used to cut contract size on modifiers
    function _ensureCallerIsPausableAdmin() internal view {
        if (!IACL(acl).isPausableAdmin(msg.sender)) revert CallerNotPausableAdminException();
    }

    /// @dev Reverts if the caller is not unpausable admin
    /// @dev Used to cut contract size on modifiers
    function _ensureCallerIsUnpausableAdmin() internal view {
        if (!IACL(acl).isUnpausableAdmin(msg.sender)) revert CallerNotUnpausableAdminException();
    }

    /// @dev Checks whether given account has configurator role
    function _isConfigurator(address account) internal view returns (bool) {
        return IACL(acl).isConfigurator(account);
    }
}
