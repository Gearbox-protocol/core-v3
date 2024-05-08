// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

interface IAdapterDeployer {
    function deploy(address creditManager, address target, bytes calldata specificParams) external returns (address);
}

contract AdapterFactoryV3 is IVersion {
    using EnumerableSet for EnumerableSet.AddressSet;
    /// @notice Contract version

    uint256 public constant override version = 3_10;

    mapping(address => uint8) public targetTypes;
    mapping(uint8 => mapping(uint256 => address)) public adapterDeployers;

    modifier registeredCuratorsOnly() {
        _;
    }

    function deployAdapter(address creditManager, address target, uint256 _version, bytes calldata specificParams)
        external
        registeredCuratorsOnly
        returns (address)
    {
        address deployer = adapterDeployers[targetTypes[target]][_version];
        return IAdapterDeployer(deployer).deploy(creditManager, target, specificParams);
    }
}
