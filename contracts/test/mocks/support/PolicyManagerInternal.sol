// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {PolicyManager} from "../../../support/risk-controller/PolicyManager.sol";

contract PolicyManagerInternal is PolicyManager {
    constructor(address _addressProvider) PolicyManager(_addressProvider) {}

    function checkPolicy(address contractAddress, string memory paramName, uint256 oldValue, uint256 newValue)
        external
        returns (bool)
    {
        return _checkPolicy(contractAddress, paramName, oldValue, newValue);
    }

    function checkPolicy(bytes32 policyHash, uint256 oldValue, uint256 newValue) external returns (bool) {
        return _checkPolicy(policyHash, oldValue, newValue);
    }
}
