// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

/// @title Optional call library
/// @notice Implements a function that calls a contract that may not have an expected selector.
///         Handles the case where the contract has a fallback function that may or may not change state.
library OptionalCall {
    function staticCallOptionalSafe(address target, bytes memory data, uint256 gasAllowance)
        internal
        view
        returns (bool, bytes memory)
    {
        (bool success, bytes memory returnData) = target.staticcall{gas: gasAllowance}(data);
        return returnData.length > 0 ? (success, returnData) : (false, returnData);
    }
}
