// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {ACLNonReentrantTrait} from "../../traits/ACLNonReentrantTrait.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

/// @dev Metaparameters are values that govern changes to a mission-critical system parameter
struct MetaParameters {
    /// @dev Determines whether the metaparameters were initialized
    bool initialized;
    /// @dev Bitmask of flags that determine which metaparameters to apply on parameter change:
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

/// @dev A contract for managing bounds and conditions (called metaparameters) for mission-critical protocol params
contract MetaParamManager is ACLNonReentrantTrait {
    uint256 public constant CHECK_EXACT_VALUE_FLAG = 1;
    uint256 public constant CHECK_MIN_VALUE_FLAG = 1 << 1;
    uint256 public constant CHECK_MAX_VALUE_FLAG = 1 << 2;
    uint256 public constant CHECK_MIN_CHANGE_FLAG = 1 << 3;
    uint256 public constant CHECK_MAX_CHANGE_FLAG = 1 << 4;
    uint256 public constant CHECK_MIN_PCT_CHANGE_FLAG = 1 << 5;
    uint256 public constant CHECK_MAX_PCT_CHANGE_FLAG = 1 << 6;

    /// @dev Mapping from parameter hashes to metaparameters
    mapping(bytes32 => MetaParameters) internal _metas;

    constructor(address _addressProvider) ACLNonReentrantTrait(_addressProvider) {}

    /// @dev Sets the metaparameters, using the hashed parameter name as key
    function setParameterMetas(string memory paramName, MetaParameters memory initialMetas) external configuratorOnly {
        _setParameterMetas(keccak256(abi.encode(paramName)), initialMetas);
    }

    /// @dev Sets the metaparameters, using any hash as key
    function setParameterMetas(bytes32 paramHash, MetaParameters memory initialMetas) public configuratorOnly {
        _setParameterMetas(paramHash, initialMetas);
    }

    /// @dev IMPLEMENTATION: setParameterMetas
    function _setParameterMetas(bytes32 paramHash, MetaParameters memory initialMetas) internal configuratorOnly {
        initialMetas.initialized = true;
        _metas[paramHash] = initialMetas;
    }

    /// @dev Retrieves metaparameters from parameter name
    function getParameterMetas(string memory paramName) external view returns (MetaParameters memory) {
        return _metas[keccak256(abi.encode(paramName))];
    }

    /// @dev Retrieves metaparameters from arbitrary parameter hash
    function getParameterMetas(bytes32 paramHash) external view returns (MetaParameters memory) {
        return _metas[paramHash];
    }

    /// @dev Performs parameter checks, with metaparameters retrieved from parameter name
    function _checkParameter(string memory paramName, uint256 oldValue, uint256 newValue) internal returns (bool) {
        return _checkParameter(keccak256(abi.encode(paramName)), oldValue, newValue);
    }

    /// @dev Performs parameter checks, with metaparameters retrieved from arbitrary hash
    function _checkParameter(bytes32 paramHash, uint256 oldValue, uint256 newValue) internal returns (bool) {
        MetaParameters storage metas = _metas[paramHash];

        if (!metas.initialized) return false;

        uint8 flags = metas.flags;

        if (flags & CHECK_EXACT_VALUE_FLAG > 0) {
            if (newValue != metas.exactValue) return false;
        }

        if (flags & CHECK_MIN_VALUE_FLAG > 0) {
            if (newValue < metas.minValue) return false;
        }

        if (flags & CHECK_MAX_VALUE_FLAG > 0) {
            if (newValue > metas.maxValue) return false;
        }

        uint256 rp;

        if (
            flags
                & (CHECK_MIN_CHANGE_FLAG | CHECK_MAX_CHANGE_FLAG | CHECK_MIN_PCT_CHANGE_FLAG | CHECK_MAX_PCT_CHANGE_FLAG)
                > 0
        ) {
            if (block.timestamp > metas.referencePointTimestampLU + metas.referencePointUpdatePeriod) {
                metas.referencePoint = oldValue;
            }
            rp = metas.referencePoint;
        }

        if (flags & CHECK_MIN_CHANGE_FLAG > 0) {
            uint256 diff = newValue > rp ? newValue - rp : rp - newValue;
            if (diff < metas.minChange) return false;
        }

        if (flags & CHECK_MAX_CHANGE_FLAG > 0) {
            uint256 diff = newValue > rp ? newValue - rp : rp - newValue;
            if (diff > metas.maxChange) return false;
        }

        if (flags & CHECK_MIN_PCT_CHANGE_FLAG > 0) {
            uint256 diff = newValue > rp ? newValue - rp : rp - newValue;
            uint16 pctDiff = uint16(diff * PERCENTAGE_FACTOR / rp);
            if (pctDiff < metas.minPctChange) return false;
        }

        if (flags & CHECK_MAX_PCT_CHANGE_FLAG > 0) {
            uint256 diff = newValue > rp ? newValue - rp : rp - newValue;
            uint16 pctDiff = uint16(diff * PERCENTAGE_FACTOR / rp);
            if (pctDiff > metas.maxPctChange) return false;
        }

        return true;
    }
}
