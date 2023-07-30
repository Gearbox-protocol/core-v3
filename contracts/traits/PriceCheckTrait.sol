// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IncorrectPriceException, StalePriceException} from "../interfaces/IExceptions.sol";

/// @title Price check trait
abstract contract PriceCheckTrait {
    /// @dev Ensures that price is positive and not stale
    function _checkAnswer(int256 price, uint256 updatedAt, uint32 stalenessPeriod) internal view {
        if (price <= 0) revert IncorrectPriceException();
        if (_isStale(updatedAt, stalenessPeriod)) revert StalePriceException();
    }

    /// @dev Checks whether price is stale
    function _isStale(uint256 updatedAt, uint32 stalenessPeriod) internal view returns (bool) {
        return block.timestamp >= updatedAt + stalenessPeriod;
    }
}
