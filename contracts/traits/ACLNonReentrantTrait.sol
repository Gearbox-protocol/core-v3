// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

import {IACL} from "@gearbox-protocol/core-v2/contracts/interfaces/IACL.sol";
import {
    CallerNotControllerException,
    CallerNotPausableAdminException,
    CallerNotUnpausableAdminException
} from "../interfaces/IExceptions.sol";

import {ACLTrait} from "./ACLTrait.sol";
import {ReentrancyGuardTrait} from "./ReentrancyGuardTrait.sol";

/// @title ACL non-reentrant trait
/// @notice Extended version of `ACLTrait` that implements pausable functionality,
///         reentrancy protection and external controller role
abstract contract ACLNonReentrantTrait is ACLTrait, Pausable, ReentrancyGuardTrait {
    /// @notice Emitted when new external controller is set
    event NewController(address indexed newController);

    /// @notice Whether contract has an external controller set
    bool public externalController;

    /// @notice External controller address
    address public controller;

    /// @dev Ensures that function caller is external controller (if it is set) or configurator
    modifier controllerOnly() {
        if (msg.sender != controller && !_isConfigurator({account: msg.sender})) {
            revert CallerNotControllerException();
        }
        _;
    }

    /// @dev Ensures that function caller has pausable admin role
    modifier pausableAdminsOnly() {
        if (!_isPausableAdmin({account: msg.sender})) {
            revert CallerNotPausableAdminException();
        }
        _;
    }

    /// @dev Ensures that function caller has unpausable admin role
    modifier unpausableAdminsOnly() {
        if (!_isUnpausableAdmin({account: msg.sender})) {
            revert CallerNotUnpausableAdminException();
        }
        _;
    }

    /// @notice Constructor
    /// @param addressProvider Address provider contract address
    constructor(address addressProvider) ACLTrait(addressProvider) {
        controller = IACL(acl).owner();
    }

    /// @notice Pauses contract, can only be called by an account with pausable admin role
    function pause() external virtual pausableAdminsOnly {
        _pause();
    }

    /// @notice Unpauses contract, can only be called by an account with unpausable admin role
    function unpause() external virtual unpausableAdminsOnly {
        _unpause();
    }

    /// @notice Sets new external controller, can only be called by configurator
    function setController(address newController) external configuratorOnly {
        externalController = !_isConfigurator(newController);
        controller = newController;
        emit NewController(newController);
    }

    /// @dev Checks whether given account has pausable admin role
    function _isPausableAdmin(address account) internal view returns (bool) {
        return IACL(acl).isPausableAdmin(account);
    }

    /// @dev Checks whether given account has unpausable admin role
    function _isUnpausableAdmin(address account) internal view returns (bool) {
        return IACL(acl).isUnpausableAdmin(account);
    }
}
