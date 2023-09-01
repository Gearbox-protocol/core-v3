// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {
    AddressIsNotContractException,
    IncorrectParameterException,
    IncorrectPriceException,
    IncorrectPriceFeedException,
    PriceFeedDoesNotExistException,
    StalePriceException
} from "../interfaces/IExceptions.sol";
import {IPriceFeed, IUpdatablePriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";

/// @title Price feed validation trait
abstract contract PriceFeedValidationTrait {
    using Address for address;

    /// @dev Ensures that price is positive and not stale
    function _checkAnswer(int256 price, uint256 updatedAt, uint32 stalenessPeriod) internal view {
        if (price <= 0) revert IncorrectPriceException();
        if (block.timestamp >= updatedAt + stalenessPeriod) revert StalePriceException();
    }

    /// @dev Valites that `priceFeed` is a contract that adheres to Chainlink interface and passes sanity checks
    /// @dev Some price feeds return stale prices unless updated right before querying their answer, which causes
    ///      issues during deployment and configuration, so for such price feeds staleness check is skipped, and
    ///      special care must be taken to ensure all parameters are in tune.
    function _validatePriceFeed(address priceFeed, uint32 stalenessPeriod) internal view returns (bool skipCheck) {
        if (!priceFeed.isContract()) revert AddressIsNotContractException(priceFeed); // U:[PO-5]

        try IPriceFeed(priceFeed).decimals() returns (uint8 _decimals) {
            if (_decimals != 8) revert IncorrectPriceFeedException(); // U:[PO-5]
        } catch {
            revert IncorrectPriceFeedException(); // U:[PO-5]
        }

        try IPriceFeed(priceFeed).skipPriceCheck() returns (bool _skipCheck) {
            skipCheck = _skipCheck; // U:[PO-5]
        } catch {}

        try IPriceFeed(priceFeed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80)
        {
            if (skipCheck) {
                if (stalenessPeriod != 0) revert IncorrectParameterException(); // U:[PO-5]
            } else {
                if (stalenessPeriod == 0) revert IncorrectParameterException(); // U:[PO-5]

                bool updatable;
                try IUpdatablePriceFeed(priceFeed).updatable() returns (bool _updatable) {
                    updatable = _updatable;
                } catch {}
                if (!updatable) _checkAnswer(answer, updatedAt, stalenessPeriod); // U:[PO-5]
            }
        } catch {
            revert IncorrectPriceFeedException(); // U:[PO-5]
        }
    }

    /// @dev Returns answer from a price feed with optional sanity and staleness checks
    function _getValidatedPrice(address priceFeed, uint32 stalenessPeriod, bool skipCheck)
        internal
        view
        returns (int256 answer)
    {
        uint256 updatedAt;
        (, answer,, updatedAt,) = IPriceFeed(priceFeed).latestRoundData(); // U:[PO-1]
        if (!skipCheck) _checkAnswer(answer, updatedAt, stalenessPeriod); // U:[PO-1]
    }
}
