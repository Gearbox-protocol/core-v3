// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {AddressProvider} from "@gearbox-protocol/core-v2/contracts/core/AddressProvider.sol";
import {IACL} from "@gearbox-protocol/core-v2/contracts/interfaces/IACL.sol";
import "../interfaces/IExceptions.sol";

import {SanityCheckTrait} from "./SanityCheckTrait.sol";

/// @title ACL Trait
/// @notice Utility class for ACL consumers
abstract contract ACLTrait is SanityCheckTrait {
    // ACL contract to check rights
    IACL public immutable _acl;

    /// @dev constructor
    /// @param addressProvider Address of address repository
    constructor(address addressProvider) nonZeroAddress(addressProvider) {
        _acl = IACL(AddressProvider(addressProvider).getACL());
    }

    /// @dev  Reverts if msg.sender is not configurator
    modifier configuratorOnly() {
        if (!_acl.isConfigurator(msg.sender)) {
            revert CallerNotConfiguratorException();
        }
        _;
    }
}
