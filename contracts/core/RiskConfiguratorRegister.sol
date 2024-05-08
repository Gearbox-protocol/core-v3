// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {ACLTrait} from "../traits/ACLTrait.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {RiskConfigurator} from "./RiskConfigurator.sol";

contract RiskConfiguratorRegister is ACLTrait {
    using EnumerableSet for EnumerableSet.AddressSet;

    error CantRemoveRiskConfiguratorWithExistingPools();

    event AddRiskCurator(address indexed newRiskConfigurator, string name, address _vetoAdmin);

    EnumerableSet.AddressSet internal _riskCurators;

    constructor(address acl) ACLTrait(acl) {}

    function addRiskConfigurator(address newRiskConfigurator, string calldata name, address _vetoAdmin)
        external
        configuratorOnly
    {
        address rc = address(new RiskConfigurator(newRiskConfigurator, name, _vetoAdmin));
        _riskCurators.add(rc);
        emit AddRiskCurator(newRiskConfigurator, name, _vetoAdmin);
    }

    function removeRiskConfigurator(address rc) external configuratorOnly {
        if (RiskConfigurator(rc).pools().length != 0) revert CantRemoveRiskConfiguratorWithExistingPools();
        _riskCurators.remove(rc);
        (rc);
    }

    function riskCurators() external view returns (address[] memory) {
        return _riskCurators.values();
    }

    function isRiskCurator(address riskCurator) external view returns (bool) {
        return _riskCurators.contains(riskCurator);
    }
}
