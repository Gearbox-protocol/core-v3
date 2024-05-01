// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

struct Policy {
    bool enabled;
    address admin;
    uint40 delay;
    bool checkInterval;
    bool checkSet;
    uint256 intervalMinValue;
    uint256 intervalMaxValue;
    uint256[] setValues;
}

/// @title Policy manager V3
/// @dev A contract for managing bounds and conditions for mission-critical protocol params
abstract contract PolicyManagerV3 is ACLNonReentrantTrait {
    /// @dev Mapping from group-derived key to policy
    mapping(bytes32 => Policy) internal _policies;

    /// @dev Mapping from a contract address to its group
    mapping(address => string) internal _group;

    /// @notice Emitted when new policy is set
    event SetPolicy(bytes32 indexed policyHash, bool enabled);

    /// @notice Emitted when new policy group of the address is set
    event SetGroup(address indexed contractAddress, string indexed group);

    constructor(address _addressProvider) ACLNonReentrantTrait(_addressProvider) {}

    /// @notice Sets the params for a new or existing policy, using policy UID as key
    /// @param policyHash A unique identifier for a policy, generally, should be a hash of (GROUP_NAME, PARAMETER_NAME)
    /// @param policyParams Policy parameters
    function setPolicy(bytes32 policyHash, Policy memory policyParams)
        external
        configuratorOnly // U:[PM-1]
    {
        policyParams.enabled = true; // U:[PM-1]
        _policies[policyHash] = policyParams; // U:[PM-1]
        emit SetPolicy({policyHash: policyHash, enabled: true}); // U:[PM-1]
    }

    /// @notice Disables the policy which makes all requested checks for the passed policy hash to auto-fail
    /// @param policyHash A unique identifier for a policy
    function disablePolicy(bytes32 policyHash)
        public
        configuratorOnly // U:[PM-2]
    {
        _policies[policyHash].enabled = false; // U:[PM-2]
        emit SetPolicy({policyHash: policyHash, enabled: false}); // U:[PM-2]
    }

    /// @notice Retrieves policy from policy UID
    function getPolicy(bytes32 policyHash) external view returns (Policy memory) {
        return _policies[policyHash]; // U:[PM-1]
    }

    /// @notice Sets the policy group of the address
    function setGroup(address contractAddress, string calldata group) external configuratorOnly {
        _group[contractAddress] = group; // U:[PM-1]
        emit SetGroup(contractAddress, group); // U:[PM-1]
    }

    /// @notice Retrieves the group associated with a contract
    function getGroup(address contractAddress) external view returns (string memory) {
        return _group[contractAddress]; // U:[PM-1]
    }

    /// @dev Returns policy transaction delay, with policy retrieved based on contract and parameter name
    function _getPolicyDelay(address contractAddress, string memory paramName) internal view returns (uint256) {
        bytes32 policyHash = keccak256(abi.encode(_group[contractAddress], paramName));
        return _policies[policyHash].delay;
    }

    /// @dev Returns policy transaction delay, with policy retrieved based on policy UID
    function _getPolicyDelay(bytes32 policyHash) internal view returns (uint256) {
        return _policies[policyHash].delay;
    }

    /// @dev Performs parameter checks, with policy retrieved based on contract and parameter name
    function _checkPolicy(address contractAddress, string memory paramName, uint256 newValue) internal returns (bool) {
        bytes32 policyHash = keccak256(abi.encode(_group[contractAddress], paramName));
        return _checkPolicy(policyHash, newValue);
    }

    /// @dev Performs parameter checks, with policy retrieved based on policy UID
    function _checkPolicy(bytes32 policyHash, uint256 newValue) internal returns (bool) {
        Policy storage policy = _policies[policyHash];

        if (!policy.enabled) return false; // U:[PM-2]

        if (policy.admin != msg.sender) return false; // U: [PM-5]

        if (policy.checkInterval) {
            if (newValue < policy.intervalMinValue || newValue > policy.intervalMaxValue) return false; // U: [PM-3]
        }

        if (policy.checkSet) {
            if (!_isIn(policy.setValues, newValue)) return false; // U: [PM-4]
        }

        return true;
    }

    /// @dev Returns whether the value is an element of `arr`
    function _isIn(uint256[] memory arr, uint256 value) internal pure returns (bool) {
        uint256 len = arr.length;

        for (uint256 i = 0; i < len;) {
            if (value == arr[i]) return true;

            unchecked {
                ++i;
            }
        }

        return false;
    }
}
