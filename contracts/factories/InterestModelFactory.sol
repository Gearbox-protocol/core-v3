// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

contract InterestModelFactory is IVersion {
    using EnumerableSet for EnumerableSet.AddressSet;

    error ModelDeployersOnlyException();

    event AddNewModel(address);

    uint256 public constant override version = 3_10;

    EnumerableSet.AddressSet internal _modelDeployers;

    EnumerableSet.AddressSet internal _models;

    modifier modelDeployersOnly() {
        if (!_modelDeployers.contains(msg.sender)) {
            revert ModelDeployersOnlyException();
        }
        _;
    }

    function addModel(address newModel) external modelDeployersOnly {
        if (!_models.contains(newModel)) {
            _models.add(newModel);
            emit AddNewModel(newModel);
        }
    }

    function isRegisteredInterestModel(address model) external view returns (bool) {
        return _models.contains(model);
    }
}
