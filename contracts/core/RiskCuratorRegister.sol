// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {ACLTrait} from "../traits/ACLTrait.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract RiskCuratorRegister is ACLTrait {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet internal _riskCurators;

    constructor(address acl) ACLTrait(acl) {}

    function riskCurators() external view returns (address[] memory) {
        return _riskCurators.values();
    }

    function isRiskCurator(address riskCurator) external view returns (bool) {
        return _riskCurators.contains(riskCurator);
    }
}
