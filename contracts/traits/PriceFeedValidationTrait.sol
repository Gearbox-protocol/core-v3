// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import {
    AddressIsNotContractException,
    IncorrectParameterException,
    IncorrectPriceException,
    IncorrectPriceFeedException,
    PriceFeedDoesNotExistException,
    StalePriceException
} from "../interfaces/IExceptions.sol";
import {IPriceFeedType} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeedType.sol";

/// @title Price feed validation trait
abstract contract PriceFeedValidationTrait {
    using Address for address;
    /// @dev Ensures that price is positive and not stale

    function _checkAnswer(int256 price, uint256 updatedAt, uint32 stalenessPeriod) internal view {
        if (price <= 0) revert IncorrectPriceException();
        if (_isStale(updatedAt, stalenessPeriod)) revert StalePriceException();
    }

    /// @dev Checks whether price is stale
    function _isStale(uint256 updatedAt, uint32 stalenessPeriod) internal view returns (bool) {
        return block.timestamp >= updatedAt + stalenessPeriod;
    }

    /// @dev Valites that `priceFeed` is a contract that adheres to Chainlink interface and passes sanity checks
    function _validatePriceFeed(address priceFeed, uint32 stalenessPeriod) internal view returns (bool skipCheck) {
        if (!priceFeed.isContract()) revert AddressIsNotContractException(priceFeed); // U:[PO-5]

        try AggregatorV3Interface(priceFeed).decimals() returns (uint8 _decimals) {
            if (_decimals != 8) revert IncorrectPriceFeedException(); // U:[PO-5]
        } catch {
            revert IncorrectPriceFeedException(); // U:[PO-5]
        }

        try IPriceFeedType(priceFeed).skipPriceCheck() returns (bool _skipCheck) {
            skipCheck = _skipCheck; // U:[PO-5]
        } catch {}

        try AggregatorV3Interface(priceFeed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (skipCheck) {
                if (stalenessPeriod > 0) revert IncorrectParameterException(); // U:[PO-5]
            } else {
                // this would ensure that `stalenessPeriod > 0` unless somehow `updatedAt > block.timestamp`
                _checkAnswer(answer, updatedAt, stalenessPeriod); // U:[PO-5]
            }
        } catch {
            revert IncorrectPriceFeedException(); // U:[PO-5]
        }
    }
}
