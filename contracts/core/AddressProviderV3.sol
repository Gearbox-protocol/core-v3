// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import "../interfaces/IAddressProviderV3.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";
import {IACL} from "@gearbox-protocol/core-v2/contracts/interfaces/IACL.sol";

import {AddressNotFoundException, CallerNotConfiguratorException} from "../interfaces/IExceptions.sol";
import "forge-std/console.sol";

/// @title AddressRepository
/// @notice Stores addresses of deployed contracts
contract AddressProviderV3 is IAddressProviderV3 {
    // Mapping from contract keys to respective addresses
    mapping(bytes32 => mapping(uint256 => address)) public addresses;

    // Contract version
    uint256 public constant override(IVersion) version = 3_00;

    modifier configuratorOnly() {
        if (!IACL(getAddressOrRevert(AP_ACL, 0)).isConfigurator(msg.sender)) {
            revert CallerNotConfiguratorException();
        }
        _;
    }

    constructor(address _acl) {
        // @dev Emits first event for contract discovery
        emit AddressSet("ADDRESS_PROVIDER", address(this), version);
        _setAddress(AP_ACL, _acl, 0);
    }

    function getAddressOrRevert(bytes32 key, uint256 _version) public view override returns (address result) {
        result = addresses[key][_version];
        if (result == address(0)) revert AddressNotFoundException();
    }

    /// @dev Sets address to map by its key
    /// @param key Key in string format
    /// @param value Address
    function setAddress(bytes32 key, address value, bool saveVersion) external override configuratorOnly {
        _setAddress(key, value, saveVersion ? IVersion(value).version() : 0);
    }

    function _setAddress(bytes32 key, address value, uint256 _version) internal {
        addresses[key][_version] = value;
        emit AddressSet(key, value, _version); // F:[AP-2]
    }

    /// KEPT FOR BACKWARD COMPATABILITY

    /// @return Address of ACL contract
    function getACL() external view returns (address) {
        return getAddressOrRevert(AP_ACL, 0); // F:[AP-3]
    }

    /// @return Address of ContractsRegister
    function getContractsRegister() external view returns (address) {
        return getAddressOrRevert(AP_CONTRACTS_REGISTER, 1); // F:[AP-4]
    }

    /// @return Address of PriceOracle
    function getPriceOracle() external view returns (address) {
        return getAddressOrRevert(AP_PRICE_ORACLE, 2); // F:[AP-5]
    }

    /// @return Address of AccountFactory
    function getAccountFactory() external view returns (address) {
        return getAddressOrRevert(AP_ACCOUNT_FACTORY, 1); // F:[AP-6]
    }

    /// @return Address of DataCompressor
    function getDataCompressor() external view returns (address) {
        return getAddressOrRevert(AP_DATA_COMPRESSOR, 2); // F:[AP-7]
    }

    /// @return Address of Treasury contract
    function getTreasuryContract() external view returns (address) {
        return getAddressOrRevert(AP_TREASURY, 0); // F:[AP-8]
    }

    /// @return Address of GEAR token
    function getGearToken() external view returns (address) {
        return getAddressOrRevert(AP_GEAR_TOKEN, 0); // F:[AP-9]
    }

    /// @return Address of WETH token
    function getWethToken() external view returns (address) {
        return getAddressOrRevert(AP_WETH_TOKEN, 0); // F:[AP-10]
    }

    /// @return Address of WETH token
    function getWETHGateway() external view returns (address) {
        return getAddressOrRevert(AP_WETH_GATEWAY, 1); // F:[AP-11]
    }

    /// @return Address of PathFinder
    function getLeveragedActions() external view returns (address) {
        return getAddressOrRevert(AP_ROUTER, 1); // T:[AP-7]
    }
}
