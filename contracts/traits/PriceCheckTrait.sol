// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IncorrectPriceException, StalePriceException} from "../interfaces/IExceptions.sol";

/// @title Price check trait
abstract contract PriceCheckTrait {
    /// @dev Period since the last update after which the price is considered stale
    uint256 internal constant STALENESS_PERIOD = 8 hours;

    /// @dev Ensures that price is positive and not stale
    function _checkAnswer(int256 price, uint256 updatedAt) internal view {
        if (price <= 0) revert IncorrectPriceException();
        if (block.timestamp > updatedAt + STALENESS_PERIOD) {
            revert StalePriceException();
        }
    }
}
