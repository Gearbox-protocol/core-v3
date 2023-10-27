// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

/// @notice Policy that determines checks performed on a parameter
///         Each policy is defined for a contract group, which is a string
///         identifier for a set of contracts
/// @param enabled Determines whether the policy is enabled. A disabled policy will auto-fail the policy check.
/// @param admin The admin that can change the parameter under the given policy
/// @param delay The delay before the transaction can be triggered under a given policy
/// @param flags Bitmask of flags that determine which policy checks to apply on parameter change:
///        * 0 - check exact value
///        * 1 - check min value
///        * 2 - check max value
///        * 3 - check min change
///        * 4 - check max change
///        * 5 - check min pct change
///        * 6 - check max pct change
/// @param exactValue Exact value to check the incoming parameter value against, if applies
/// @param minValue Min value to check the incoming parameter value against, if applies
/// @param maxValue Max value to check the incoming parameter value against, if applies
/// @param referencePoint A reference value of a parameter to check change magnitudes against;
///        When the reference update period has elapsed since the last reference point update,
///        the reference point is updated to the 'current' value on the next parameter change
///        NB: Should not be changed manually in most cases
/// @param referencePointUpdatePeriod The minimal time period after which the RP can be updated
/// @param referencePointTimestampLU  Last timestamp at which the reference point was updated
///        NB: Should not be changed manually in most cases
/// @param minPctChangeDown Min percentage decrease for new values, relative to reference point
/// @param minPctChangeUp Min percentage increase for new values, relative to reference point
/// @param maxPctChangeDown Max percentage decrease for new values, relative to reference point
/// @param maxPctChangeUp Max percentage increase for new values, relative to reference point
/// @param minChange Min absolute changes for new values, relative to reference point
/// @param maxChange Max absolute changes for new values, relative to reference point
struct Policy {
    bool enabled;
    address admin;
    uint40 delay;
    uint8 flags;
    uint256 exactValue;
    uint256 minValue;
    uint256 maxValue;
    uint256 referencePoint;
    uint40 referencePointUpdatePeriod;
    uint40 referencePointTimestampLU;
    uint16 minPctChangeDown;
    uint16 minPctChangeUp;
    uint16 maxPctChangeDown;
    uint16 maxPctChangeUp;
    uint256 minChange;
    uint256 maxChange;
}

/// @title Policy manager V3
/// @dev A contract for managing bounds and conditions for mission-critical protocol params
abstract contract PolicyManagerV3 is ACLNonReentrantTrait {
    uint256 internal constant CHECK_EXACT_VALUE_FLAG = 1;
    uint256 internal constant CHECK_MIN_VALUE_FLAG = 1 << 1;
    uint256 internal constant CHECK_MAX_VALUE_FLAG = 1 << 2;
    uint256 internal constant CHECK_MIN_CHANGE_FLAG = 1 << 3;
    uint256 internal constant CHECK_MAX_CHANGE_FLAG = 1 << 4;
    uint256 internal constant CHECK_MIN_PCT_CHANGE_FLAG = 1 << 5;
    uint256 internal constant CHECK_MAX_PCT_CHANGE_FLAG = 1 << 6;

    /// @dev Mapping from parameter hashes to metaparameters
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

        if (!policy.enabled) return false; // U:[PM-2]

        if (policy.admin != msg.sender) return false;

        uint8 flags = policy.flags;

        if (flags & CHECK_EXACT_VALUE_FLAG != 0) {
            if (newValue != policy.exactValue) return false; // U:[PM-3]
        }

        if (flags & CHECK_MIN_VALUE_FLAG != 0) {
            if (newValue < policy.minValue) return false; // U:[PM-4]
        }

        if (flags & CHECK_MAX_VALUE_FLAG != 0) {
            if (newValue > policy.maxValue) return false; // U:[PM-5]
        }

        uint256 referencePoint;

        // The policy uses a reference point to gauge relative parameter changes. A reference point
        // is a value that is set to current value on updating a parameter. All future values for a period
        // will be rubber-banded to the reference point, until the refresh period elapses and it is updated again.

        if (
            flags
                & (CHECK_MIN_CHANGE_FLAG | CHECK_MAX_CHANGE_FLAG | CHECK_MIN_PCT_CHANGE_FLAG | CHECK_MAX_PCT_CHANGE_FLAG)
                != 0
        ) {
            if (block.timestamp > policy.referencePointTimestampLU + policy.referencePointUpdatePeriod) {
                referencePoint = oldValue;
                policy.referencePoint = referencePoint; // U:[PM-6]
                policy.referencePointTimestampLU = uint40(block.timestamp); // U:[PM-6]
            } else {
                referencePoint = policy.referencePoint;
            }

            (uint256 diff, bool isIncrease) = calcDiff(newValue, referencePoint);

            if (flags & CHECK_MIN_CHANGE_FLAG != 0) {
                if (diff < policy.minChange) return false; // U:[PM-7]
            }

            if (flags & CHECK_MAX_CHANGE_FLAG != 0) {
                if (diff > policy.maxChange) return false; // U:[PM-8]
            }

            if (flags & (CHECK_MIN_PCT_CHANGE_FLAG | CHECK_MAX_PCT_CHANGE_FLAG) != 0) {
                uint256 pctDiff = diff * PERCENTAGE_FACTOR / referencePoint;
                if (
                    flags & CHECK_MIN_PCT_CHANGE_FLAG != 0
                        && pctDiff < (isIncrease ? policy.minPctChangeUp : policy.minPctChangeDown)
                ) return false; // U:[PM-9]
                if (
                    flags & CHECK_MAX_PCT_CHANGE_FLAG != 0
                        && pctDiff > (isIncrease ? policy.maxPctChangeUp : policy.maxPctChangeDown)
                ) return false; // U:[PM-10]
            }
        }

        return true;
    }

    /// @dev Returns the absolute difference between two numbers and the flag whether the first one is greater
    function calcDiff(uint256 a, uint256 b) internal pure returns (uint256, bool) {
        return a > b ? (a - b, true) : (b - a, false);
    }
}
