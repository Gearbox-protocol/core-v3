// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {ZeroAddressException} from "../interfaces/IExceptions.sol";

/// @title ACL Trait
/// @notice Utility class for ACL consumers
abstract contract SanityCheckTrait {
    modifier nonZeroAddress(address addr) {
        _nonZeroCheck(addr);
        _;
    }

    function _nonZeroCheck(address addr) private pure {
        if (addr == address(0)) revert ZeroAddressException(); // F:[P4-2]
    }
}
