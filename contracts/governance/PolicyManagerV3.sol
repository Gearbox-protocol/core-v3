// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

/// @dev Policy that determines checks performed on a parameter
///      Each policy is defined for a contract group, which is a string
///      identifier for a set of contracts
struct Policy {
    /// @dev Determines whether the policy is enabled
    ///      A disabled policy will auto-fail the policy check
    bool enabled;
    /// @dev Bitmask of flags that determine which policy checks to apply on parameter change:
    ///      0 - check exact value
    ///      1 - check min value
    ///      2 - check max value
    ///      3 - check min change
    ///      4 - check max change
    ///      5 - check min pct change
    ///      6 - check max pct change
    uint8 flags;
    /// @dev Exact value to check the incoming parameter value against, if applies
    uint256 exactValue;
    /// @dev Min value to check the incoming parameter value against, if applies
    uint256 minValue;
    /// @dev Max value to check the incoming parameter value against, if applies
    uint256 maxValue;
    /// @dev A reference value of a parameter to check change magnitudes against;
    ///      When the reference update period has elapsed since the last reference point update,
    ///      the reference point is updated to the 'current' value on the next parameter change
    ///      NB: Should not be changed manually in most cases
    uint256 referencePoint;
    /// @dev The minimal time period after which the RP can be updated
    uint40 referencePointUpdatePeriod;
    /// @dev Last timestamp at which the reference point was updated
    ///      NB: Should not be changed manually in most cases
    uint40 referencePointTimestampLU;
    /// @dev Min and max absolute percentage changes for new values, relative to reference point
    uint16 minPctChange;
    uint16 maxPctChange;
    /// @dev Min and max absolute changes for new values, relative to reference point
    uint256 minChange;
    uint256 maxChange;
}

/// @dev A contract for managing bounds and conditions for mission-critical protocol params
contract PolicyManagerV3 is ACLNonReentrantTrait {
    uint256 public constant CHECK_EXACT_VALUE_FLAG = 1;
    uint256 public constant CHECK_MIN_VALUE_FLAG = 1 << 1;
    uint256 public constant CHECK_MAX_VALUE_FLAG = 1 << 2;
    uint256 public constant CHECK_MIN_CHANGE_FLAG = 1 << 3;
    uint256 public constant CHECK_MAX_CHANGE_FLAG = 1 << 4;
    uint256 public constant CHECK_MIN_PCT_CHANGE_FLAG = 1 << 5;
    uint256 public constant CHECK_MAX_PCT_CHANGE_FLAG = 1 << 6;

    /// @dev Mapping from parameter hashes to metaparameters
    mapping(bytes32 => Policy) internal _policies;

    /// @dev Mapping from a contract address to its group
    mapping(address => string) internal _group;

    constructor(address _addressProvider) ACLNonReentrantTrait(_addressProvider) {}

    /// @notice Sets the policy, using policy UID as key
    /// @param policyHash A unique identifier for a policy
    ///                   Generally, this should be a hash of (PARAMETER_NAME, GROUP_NAME)
    /// @param initialPolicy The initial policy values
    function setPolicy(bytes32 policyHash, Policy memory initialPolicy)
        external
        configuratorOnly // F: [PM-01]
    {
        initialPolicy.enabled = true; // F: [PM-01]
        _policies[policyHash] = initialPolicy; // F: [PM-01]
    }

    /// @notice Disables the policy which makes all requested checks for the passed policy hash to auto-fail
    /// @param policyHash A unique identifier for a policy
    function disablePolicy(bytes32 policyHash)
        public
        configuratorOnly // F: [PM-02]
    {
        _policies[policyHash].enabled = false; // F: [PM-02]
    }

    /// @notice Retrieves policy from policy UID
    function getPolicy(bytes32 policyHash) external view returns (Policy memory) {
        return _policies[policyHash]; // F: [PM-01]
    }

    /// @notice Sets the policy group of the address
    function setGroup(address contractAddress, string memory group) external configuratorOnly {
        _group[contractAddress] = group;
    }

    /// @notice Retrieves the group associated with a contract
    function getGroup(address contractAddress) external view returns (string memory) {
        return _group[contractAddress];
    }

    /// @dev Performs parameter checks, with policy retrieved based on contract and parameter name
    function _checkPolicy(address contractAddress, string memory paramName, uint256 oldValue, uint256 newValue)
        internal
        returns (bool)
    {
        bytes32 policyHash = keccak256(abi.encode(_group[contractAddress], paramName));
        return _checkPolicy(policyHash, oldValue, newValue);
    }

    /// @dev Performs parameter checks, with policy retrieved based on policy UID
    function _checkPolicy(bytes32 policyHash, uint256 oldValue, uint256 newValue) internal returns (bool) {
        Policy storage policy = _policies[policyHash];

        if (!policy.enabled) return false; // F: [PM-02]

        uint8 flags = policy.flags;

        if (flags & CHECK_EXACT_VALUE_FLAG != 0) {
            if (newValue != policy.exactValue) return false; // F: [PM-03]
        }

        if (flags & CHECK_MIN_VALUE_FLAG != 0) {
            if (newValue < policy.minValue) return false; // F: [PM-04]
        }

        if (flags & CHECK_MAX_VALUE_FLAG != 0) {
            if (newValue > policy.maxValue) return false; // F: [PM-05]
        }

        uint256 referencePoint;

        /// The policy uses a reference point to gauge relative parameter changes. A reference point
        /// is a value that is set to current value on updating a parameter. All future values for a period
        /// will be rubber-banded to the reference point, until the refresh period elapses and it is updated again.

        if (
            flags
                & (CHECK_MIN_CHANGE_FLAG | CHECK_MAX_CHANGE_FLAG | CHECK_MIN_PCT_CHANGE_FLAG | CHECK_MAX_PCT_CHANGE_FLAG)
                != 0
        ) {
            if (block.timestamp > policy.referencePointTimestampLU + policy.referencePointUpdatePeriod) {
                policy.referencePoint = oldValue; // F: [PM-06]
                policy.referencePointTimestampLU = uint40(block.timestamp); // F: [PM-06]
            }

            referencePoint = policy.referencePoint;
            uint256 diff = absDiff(newValue, referencePoint);

            if (flags & CHECK_MIN_CHANGE_FLAG != 0) {
                if (diff < policy.minChange) return false; // F: [PM-07]
            }

            if (flags & CHECK_MAX_CHANGE_FLAG != 0) {
                if (diff > policy.maxChange) return false; // F: [PM-08]
            }

            if (flags & CHECK_MIN_PCT_CHANGE_FLAG != 0) {
                uint256 pctDiff = diff * PERCENTAGE_FACTOR / referencePoint;
                if (pctDiff < policy.minPctChange) return false; // F: [PM-09]
            }

            if (flags & CHECK_MAX_PCT_CHANGE_FLAG != 0) {
                uint256 pctDiff = diff * PERCENTAGE_FACTOR / referencePoint;
                if (pctDiff > policy.maxPctChange) return false; // F: [PM-10]
            }
        }

        return true;
    }

    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
