// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IACL} from "../interfaces/base/IACL.sol";
import {IACLTrait} from "../interfaces/base/IACLTrait.sol";
import {
    AddressIsNotContractException,
    CallerNotConfiguratorException,
    CallerNotPausableAdminException,
    CallerNotUnpausableAdminException,
    ZeroAddressException
} from "../interfaces/IExceptions.sol";

/// @title ACL trait
/// @notice Utility class for ACL (access-control list) consumers
abstract contract ACLTrait is IACLTrait {
    /// @notice ACL contract address
    address public immutable override acl;

    /// @dev Ensures that function caller has configurator role
    modifier configuratorOnly() {
        _ensureCallerIsConfigurator();
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
    /// @param _acl ACL contract address
    constructor(address _acl) {
        if (_acl == address(0)) revert ZeroAddressException();
        if (_acl.code.length == 0) revert AddressIsNotContractException(_acl);
        acl = _acl;
    }

    /// @dev Reverts if the caller is not the configurator
    /// @dev Used to cut contract size on modifiers
    function _ensureCallerIsConfigurator() internal view {
        if (!_isConfigurator(msg.sender)) revert CallerNotConfiguratorException();
    }

    /// @dev Checks whether given account has configurator role
    function _isConfigurator(address account) internal view returns (bool) {
        return IACL(acl).isConfigurator(account);
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
}
