// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../interfaces/IAddressProviderV3.sol";
import {IACL} from "@gearbox-protocol/core-v2/contracts/interfaces/IACL.sol";
import {AddressNotFoundException, CallerNotConfiguratorException} from "../interfaces/IExceptions.sol";

/// @title AddressRepository
/// @notice Stores addresses of deployed contracts
contract AddressProviderV3 is IAddressProviderV3 {
    /// @notice Mapping from (contract key, version) to the respective contract address
    mapping(bytes32 => mapping(uint256 => address)) public addresses;

    /// @inheritdoc IVersion
    uint256 public constant override(IVersion) version = 3_00;

    modifier configuratorOnly() {
        _revertIfNotConfigurator();
        _;
    }

    function _revertIfNotConfigurator() internal view {
        if (!IACL(getAddressOrRevert(AP_ACL, NO_VERSION_CONTROL)).isConfigurator(msg.sender)) {
            revert CallerNotConfiguratorException();
        }
    }

    constructor(address _acl) {
        /// The first event is emitted for the AP itself, to aid in contract discovery
        emit AddressSet("ADDRESS_PROVIDER", address(this), version);
        _setAddress(AP_ACL, _acl, NO_VERSION_CONTROL);
    }

    /// @notice Returns the address associated with the passed key/version
    function getAddressOrRevert(bytes32 key, uint256 _version) public view virtual override returns (address result) {
        result = addresses[key][_version];
        if (result == address(0)) revert AddressNotFoundException();
    }

    /// @notice Sets the address for the passed key, and optionally records the contract version
    /// @param key Key in string format
    /// @param value Address to save
    /// @param saveVersion Whether to save
    function setAddress(bytes32 key, address value, bool saveVersion) external override configuratorOnly {
        _setAddress(key, value, saveVersion ? IVersion(value).version() : NO_VERSION_CONTROL);
    }

    /// @notice Internal function to set the address mapping value
    function _setAddress(bytes32 key, address value, uint256 _version) internal virtual {
        addresses[key][_version] = value;
        emit AddressSet(key, value, _version); // F:[AP-2]
    }

    /// KEPT FOR BACKWARD COMPATABILITY

    /// @return Address of ACL contract
    function getACL() external view returns (address) {
        return getAddressOrRevert(AP_ACL, NO_VERSION_CONTROL); // F:[AP-3]
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
        return getAddressOrRevert(AP_ACCOUNT_FACTORY, NO_VERSION_CONTROL); // F:[AP-6]
    }

    /// @return Address of DataCompressor
    function getDataCompressor() external view returns (address) {
        return getAddressOrRevert(AP_DATA_COMPRESSOR, 2); // F:[AP-7]
    }

    /// @return Address of Treasury contract
    function getTreasuryContract() external view returns (address) {
        return getAddressOrRevert(AP_TREASURY, NO_VERSION_CONTROL); // F:[AP-8]
    }

    /// @return Address of GEAR token
    function getGearToken() external view returns (address) {
        return getAddressOrRevert(AP_GEAR_TOKEN, NO_VERSION_CONTROL); // F:[AP-9]
    }

    /// @return Address of WETH token
    function getWethToken() external view returns (address) {
        return getAddressOrRevert(AP_WETH_TOKEN, NO_VERSION_CONTROL); // F:[AP-10]
    }

    /// @return Address of WETH token
    function getWETHGateway() external view returns (address) {
        return getAddressOrRevert(AP_WETH_GATEWAY, 1); // F:[AP-11]
    }

    /// @return Address of Router
    function getLeveragedActions() external view returns (address) {
        return getAddressOrRevert(AP_ROUTER, 1); // T:[AP-7]
    }
}
