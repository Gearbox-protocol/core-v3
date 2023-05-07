// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {ACLNonReentrantTrait} from "../../traits/ACLNonReentrantTrait.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

/// @dev Policy that determines checks performed on a parameter
///      Each policy is defined for a contract group
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
    uint40 referencePointTimestampLU;
    /// @dev Min and max absolute percentage changes for new values, relative to reference point
    uint16 minPctChange;
    uint16 maxPctChange;
    /// @dev Min and max absolute changes for new values, relative to reference point
    uint256 minChange;
    uint256 maxChange;
}

/// @dev A contract for managing bounds and conditions for mission-critical protocol params
contract PolicyManager is ACLNonReentrantTrait {
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

    /// @dev Sets the policy, using policy UID as key
    /// @param policyHash A unique identifier for a policy
    ///                   Generally, this should be a hash of (PARAMETER_NAME, GROUP_NAME)
    /// @param initialPolicy The initial policy values
    function setPolicy(bytes32 policyHash, Policy memory initialPolicy) public configuratorOnly {
        initialPolicy.enabled = true;
        _policies[policyHash] = initialPolicy;
    }

    /// @dev Disables the policy which makes all requested checks for the passed policy hash to auto-fail
    /// @param policyHash A unique identifier for a policy
    function disablePolicy(bytes32 policyHash) public configuratorOnly {
        _policies[policyHash].enabled = false;
    }

    /// @dev Retrieves policy from policy UID
    function getPolicy(bytes32 policyHash) external view returns (Policy memory) {
        return _policies[policyHash];
    }

    /// @dev Sets the policy group of the address
    function setGroup(address contractAddress, string memory group) external configuratorOnly {
        _group[contractAddress] = group;
    }

    /// @dev Retrieves the group associated with a contract
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

        if (!policy.enabled) return false;

        uint8 flags = policy.flags;

        if (flags & CHECK_EXACT_VALUE_FLAG > 0) {
            if (newValue != policy.exactValue) return false;
        }

        if (flags & CHECK_MIN_VALUE_FLAG > 0) {
            if (newValue < policy.minValue) return false;
        }

        if (flags & CHECK_MAX_VALUE_FLAG > 0) {
            if (newValue > policy.maxValue) return false;
        }

        uint256 rp;

        if (
            flags
                & (CHECK_MIN_CHANGE_FLAG | CHECK_MAX_CHANGE_FLAG | CHECK_MIN_PCT_CHANGE_FLAG | CHECK_MAX_PCT_CHANGE_FLAG)
                > 0
        ) {
            if (block.timestamp > policy.referencePointTimestampLU + policy.referencePointUpdatePeriod) {
                policy.referencePoint = oldValue;
            }
            rp = policy.referencePoint;
        }

        if (flags & CHECK_MIN_CHANGE_FLAG > 0) {
            uint256 diff = newValue > rp ? newValue - rp : rp - newValue;
            if (diff < policy.minChange) return false;
        }

        if (flags & CHECK_MAX_CHANGE_FLAG > 0) {
            uint256 diff = newValue > rp ? newValue - rp : rp - newValue;
            if (diff > policy.maxChange) return false;
        }

        if (flags & CHECK_MIN_PCT_CHANGE_FLAG > 0) {
            uint256 diff = newValue > rp ? newValue - rp : rp - newValue;
            uint16 pctDiff = uint16(diff * PERCENTAGE_FACTOR / rp);
            if (pctDiff < policy.minPctChange) return false;
        }

        if (flags & CHECK_MAX_PCT_CHANGE_FLAG > 0) {
            uint256 diff = newValue > rp ? newValue - rp : rp - newValue;
            uint16 pctDiff = uint16(diff * PERCENTAGE_FACTOR / rp);
            if (pctDiff > policy.maxPctChange) return false;
        }

        return true;
    }
}
