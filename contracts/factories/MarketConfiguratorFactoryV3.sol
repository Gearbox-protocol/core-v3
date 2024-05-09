// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {MarketConfigurator} from "./MarketConfigurator.sol";

import {APOwnerTrait} from "../traits/APOwnerTrait.sol";
import {IAddressProviderV3} from "../interfaces/IAddressProviderV3.sol";
import {IVersion} from "../interfaces/IVersion.sol";

interface IAdapterDeployer {
    function deploy(address creditManager, address target, bytes calldata specificParams) external returns (address);
}

contract MarketConfiguratorFactoryV3 is APOwnerTrait, IVersion {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Contract version
    error CantRemoveMarketConfiguratorWithExistingPoolsException();

    mapping(address => uint8) public targetTypes;
    mapping(uint8 => mapping(uint256 => address)) public adapterDeployers;

    function addMarketConfigurator(address riskCurator, address _treasury, string calldata name, address _vetoAdmin)
        external
        apOwnerOnly
    {
        address _marketConfigurator =
            address(new MarketConfigurator(addressProvider, riskCurator, _treasury, name, _vetoAdmin));

        IAddressProviderV3(addressProvider).addMarketConfigurator(_marketConfigurator);
    }

    function removeMarketConfigurator(address _marketConfigurator) external apOwnerOnly {
        if (MarketConfigurator(_marketConfigurator).pools().length != 0) {
            revert CantRemoveMarketConfiguratorWithExistingPoolsException();
        }
        IAddressProviderV3(addressProvider).removeMarketConfigurator(_marketConfigurator);
    }
}
