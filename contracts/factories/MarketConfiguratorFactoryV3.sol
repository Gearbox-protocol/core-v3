// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {MarketConfigurator} from "./MarketConfigurator.sol";

import {IAddressProviderV3} from "../interfaces/IAddressProviderV3.sol";
import {IVersion} from "../interfaces/IVersion.sol";

interface IAdapterDeployer {
    function deploy(address creditManager, address target, bytes calldata specificParams) external returns (address);
}

contract MarketConfiguratorFactoryV3 is IVersion {
    using EnumerableSet for EnumerableSet.AddressSet;

    address public addressProvider;

    /// @notice Contract version

    error CantRemoveMarketConfiguratorWithExistingPoolsException();

    uint256 public constant override version = 3_10;

    mapping(address => uint8) public targetTypes;
    mapping(uint8 => mapping(uint256 => address)) public adapterDeployers;

    modifier onlyOwner() {
        if (IAddressProviderV3(addressProvider).owner() != msg.sender) revert;
        _;
    }

    function addMarketConfigurator(address riskCurator, address _treasury, string calldata name, address _vetoAdmin)
        external
        onlyOwner
    {
        address _marketConfigurator = address(new MarketConfigurator(riskCurator, _treasury, name, _vetoAdmin));
        IAddressProviderV3(addressProvider).addMarketConfigurator(_marketConfigurator);
    }

    function removeMarketConfigurator(address rc) external onlyOwner {
        if (MarketConfigurator(rc).pools().length != 0) {
            revert CantRemoveMarketConfiguratorWithExistingPoolsException();
        }
    }
}
