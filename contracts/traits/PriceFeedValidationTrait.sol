// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {OptionalCall} from "../libraries/OptionalCall.sol";

import {
    AddressIsNotContractException,
    IncorrectParameterException,
    IncorrectPriceException,
    IncorrectPriceFeedException,
    PriceFeedDoesNotExistException,
    StalePriceException
} from "../interfaces/IExceptions.sol";
import {IPriceFeed, IUpdatablePriceFeed} from "../interfaces/base/IPriceFeed.sol";

/// @title Price feed validation trait
abstract contract PriceFeedValidationTrait {
    using Address for address;

    /// @dev Ensures that price is positive and not stale
    /// @custom:tests U:[PO-9]
    function _checkAnswer(int256 price, uint256 updatedAt, uint32 stalenessPeriod) internal view {
        if (price <= 0) revert IncorrectPriceException();
        if (block.timestamp >= updatedAt + stalenessPeriod) revert StalePriceException();
    }

    /// @dev Valites that `priceFeed` is a contract that adheres to Chainlink interface and passes sanity checks
    /// @custom:tests U:[PO-8]
    function _validatePriceFeed(address priceFeed, uint32 stalenessPeriod) internal view returns (bool skipCheck) {
        if (!priceFeed.isContract()) revert AddressIsNotContractException(priceFeed);

        try IPriceFeed(priceFeed).decimals() returns (uint8 _decimals) {
            if (_decimals != 8) revert IncorrectPriceFeedException();
        } catch {
            revert IncorrectPriceFeedException();
        }

        /// NOTE: Some external price feeds without skipPriceCheck may have a fallback function that changes state, which can cause a THROW
        ///      that burns all gas, or does not change state and instead returns empty data. To handle these cases,
        ///      we use a special call construction with a strict gas limit.
        (bool success, bytes memory returnData) = OptionalCall.staticCallOptionalSafe({
            target: priceFeed,
            data: abi.encodeWithSelector(IPriceFeed.skipPriceCheck.selector),
            gasAllowance: 10_000
        });
        if (success) {
            skipCheck = abi.decode(returnData, (bool));
        }

        try IPriceFeed(priceFeed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80)
        {
            if (skipCheck) {
                if (stalenessPeriod != 0) revert IncorrectParameterException();
            } else {
                if (stalenessPeriod == 0) revert IncorrectParameterException();
                _checkAnswer(answer, updatedAt, stalenessPeriod);
            }
        } catch {
            revert IncorrectPriceFeedException();
        }
    }

    /// @dev Returns answer from a price feed with optional sanity and staleness checks
    /// @custom:tests U:[PO-9]
    function _getValidatedPrice(address priceFeed, uint32 stalenessPeriod, bool skipCheck)
        internal
        view
        returns (int256 answer)
    {
        uint256 updatedAt;
        (, answer,, updatedAt,) = IPriceFeed(priceFeed).latestRoundData();
        if (!skipCheck) _checkAnswer(answer, updatedAt, stalenessPeriod);
    }

    /// @dev Checks whether price feed is updatable
    function _isUpdatable(address priceFeed) internal view returns (bool updatable) {
        try IUpdatablePriceFeed(priceFeed).updatable() returns (bool value) {
            updatable = value;
        } catch {}
    }
}
