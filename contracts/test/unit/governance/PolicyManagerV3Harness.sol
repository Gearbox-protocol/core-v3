// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {PolicyManagerV3, Policy} from "../../../governance/PolicyManagerV3.sol";

contract PolicyManagerV3Harness is PolicyManagerV3 {
    constructor(address _addressProvider) PolicyManagerV3(_addressProvider) {}

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
