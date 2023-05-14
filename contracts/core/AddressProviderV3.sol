// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {IAddressProviderV3} from "../interfaces/IAddressProviderV3.sol";
import {AddressProvider} from "@gearbox-protocol/core-v2/contracts/core/AddressProvider.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

/// @title AddressRepository
/// @notice Stores addresses of deployed contracts
contract AddressProviderV3 is AddressProvider, IAddressProviderV3 {
    // Contract version
    // uint256 public constant override(AddressProvider, IVersion) version = 3_00;

    constructor() AddressProvider() {
        // @dev Emits first event for contract discovery
        emit AddressSet("ADDRESS_PROVIDER", address(this));
    }

    function getAddress(bytes32 key) external view returns (address) {
        return _getAddress(key);
    }
    // /// @return Address of key, reverts if the key doesn't exist
    // function _getAddress(bytes32 key) internal view returns (address) {
    //     address result = addresses[key];
    //     require(result != address(0), Errors.AS_ADDRESS_NOT_FOUND); // F:[AP-1]
    //     return result; // F:[AP-3, 4, 5, 6, 7, 8, 9, 10, 11]
    // }

    // /// @dev Sets address to map by its key
    // /// @param key Key in string format
    // /// @param value Address
    // function _setAddress(bytes32 key, address value) internal {
    //     addresses[key] = value; // F:[AP-3, 4, 5, 6, 7, 8, 9, 10, 11]
    //     emit AddressSet(key, value); // F:[AP-2]
    // }
}
