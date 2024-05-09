// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import "../interfaces/IAddressProviderV3.sol";
import {AddressNotFoundException, CallerNotConfiguratorException} from "../interfaces/IExceptions.sol";

import {IBotListV3} from "../interfaces/IBotListV3.sol";
import {IAccountFactoryV3} from "../interfaces/IAccountFactoryV3.sol";

/// @title Address provider V3
/// @notice Stores addresses of important contracts
contract AddressProviderV3 is Ownable2Step, IAddressProviderV3 {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    error MarketConfiguratorsOnlyException();
    error CantRemoveMarketConfiguratorWithExistingPoolsException();

    /// @notice Market configurator factory
    address public marketConfiguratorFactory;

    /// @notice Keeps market confifgurators
    EnumerableSet.AddressSet internal _marketConfigurators;

    /// @notice Mapping from (contract key, version) to contract addresses
    mapping(string => mapping(uint256 => address)) public override addresses;

    mapping(string => uint256) public latestVersions;

    modifier marketConfiguratorFactoryOnly() {
        if (msg.sender != marketConfiguratorFactory) revert("Market config");
        _;
    }

    constructor() {
        // The first event is emitted for the address provider itself to aid in contract discovery
        emit SetAddress("ADDRESS_PROVIDER", address(this), version);
    }

    /// @notice Returns the address of a contract with a given key and version
    function getAddressOrRevert(string memory key, uint256 _version)
        public
        view
        virtual
        override
        returns (address result)
    {
        result = addresses[key][_version];
        if (result == address(0)) revert AddressNotFoundException();
    }

    /// @notice Returns the address of a contract with a given key and version
    function getLaterstAddressOrRevert(string memory key) public view virtual returns (address result) {
        return getAddressOrRevert(key, latestVersions[key]);
    }

    /// @notice Sets the address for the passed contract key
    /// @param key Contract key
    /// @param value Contract address
    /// @param saveVersion Whether to save contract's version
    function setAddress(string memory key, address value, bool saveVersion) external override onlyOwner {
        _setAddress(key, value, saveVersion ? IVersion(value).version() : NO_VERSION_CONTROL);
    }

    /// @dev Implementation of `setAddress`
    function _setAddress(string memory key, address value, uint256 _version) internal virtual {
        addresses[key][_version] = value;
        emit SetAddress(key, value, _version);
    }

    modifier marketConfiguratorsOnly() {
        if (!_marketConfigurators.contains(msg.sender)) revert MarketConfiguratorsOnlyException();
        _;
    }

    function addMarketConfigurator(address _marketConfigurator) external override marketConfiguratorFactoryOnly {
        if (!_marketConfigurators.contains(_marketConfigurator)) {
            _marketConfigurators.add(_marketConfigurator);
            emit AddMarketConfigurator(_marketConfigurator);
        }
    }

    function removeMarketConfigurator(address _marketConfigurator) external override marketConfiguratorFactoryOnly {
        if (_marketConfigurators.contains(_marketConfigurator)) {
            _marketConfigurators.add(_marketConfigurator);
            emit RemoveMarketConfigurator(_marketConfigurator);
        }
    }

    function marketConfigurators() external view override returns (address[] memory) {
        return _marketConfigurators.values();
    }

    function isMarketConfigurator(address riskCurator) external view override returns (bool) {
        return _marketConfigurators.contains(riskCurator);
    }

    function registerCreditManager(address creditManager) external override marketConfiguratorsOnly {
        // TODO: make method names more consistent?
        IBotListV3(getLaterstAddressOrRevert(AP_BOT_LIST)).approvedCreditManager(creditManager);
        IAccountFactoryV3(getLaterstAddressOrRevert(AP_ACCOUNT_FACTORY)).addCreditManager(creditManager);
    }
}
