// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IAddressProviderV3} from "../interfaces/IAddressProviderV3.sol";
import {CallerNotConfiguratorException} from "../interfaces/IExceptions.sol";

import {SanityCheckTrait} from "./SanityCheckTrait.sol";

/// @title ACL trait
/// @notice Utility class for ACL (access-control list) consumers
abstract contract APOwnerTrait is SanityCheckTrait {
    /// @notice ACL contract address
    address public immutable addressProvider;

    /// @notice Constructor
    /// @param _addressProvider AddressProvider contract address
    constructor(address _addressProvider) nonZeroAddress(_addressProvider) {
        addressProvider = _addressProvider;
    }

    /// @dev Ensures that function caller has configurator role
    modifier apOwnerOnly() {
        _ensureCallerIsConfigurator();
        _;
    }

    /// @dev Reverts if the caller is not the configurator
    /// @dev Used to cut contract size on modifiers
    function _ensureCallerIsConfigurator() internal view {
        if (IAddressProviderV3(addressProvider).owner() != msg.sender) {
            revert CallerNotConfiguratorException();
        }
    }
}
