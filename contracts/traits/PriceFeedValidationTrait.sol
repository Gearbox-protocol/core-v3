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

    /// @dev Ensures that price feed's answer is positive and not stale.
    ///      If `skipCheck` is true, only checks that price is non-negative to allow zero price feed to be used.
    /// @custom:tests U:[PO-9]
    function _checkAnswer(int256 price, uint256 updatedAt, uint32 stalenessPeriod, bool skipCheck) internal view {
        if (price < 0 || !skipCheck && price == 0) revert IncorrectPriceException();
        if (!skipCheck && block.timestamp >= updatedAt + stalenessPeriod) revert StalePriceException();
    }

    /// @dev Validates that `priceFeed` is a contract that adheres to Chainlink interface
    /// @dev Reverts if `priceFeed` does not have exactly 8 decimals
    /// @dev Reverts if `stalenessPeriod` is inconsistent with `priceFeed`'s `skipPriceCheck()` flag
    ///      (which is considered to be false if `priceFeed` does not have this function)
    /// @custom:tests U:[PO-8], U:[PO-10]
    function _validatePriceFeedMetadata(address priceFeed, uint32 stalenessPeriod)
        internal
        view
        returns (bool skipCheck)
    {
        if (!priceFeed.isContract()) revert AddressIsNotContractException(priceFeed);

        try IPriceFeed(priceFeed).decimals() returns (uint8 _decimals) {
            if (_decimals != 8) revert IncorrectPriceFeedException();
        } catch {
            revert IncorrectPriceFeedException();
        }

        // NOTE: Some external price feeds without `skipPriceCheck` may have a fallback function that changes state,
        // which can cause a `THROW` that burns all gas, or does not change state and instead returns empty data.
        // To handle these cases, we use a special call construction with a strict gas limit.
        (bool success, bytes memory returnData) = OptionalCall.staticCallOptionalSafe({
            target: priceFeed,
            data: abi.encodeWithSelector(IPriceFeed.skipPriceCheck.selector),
            gasAllowance: 10_000
        });
        if (success) skipCheck = abi.decode(returnData, (bool));
        if (skipCheck && stalenessPeriod != 0 || !skipCheck && stalenessPeriod == 0) {
            revert IncorrectParameterException();
        }
    }

    /// @dev Validates that `priceFeed` is a contract that adheres to Chainlink interface and returns valid answer
    /// @custom:tests U:[PO-8], U:[PO-10]
    function _validatePriceFeed(address priceFeed, uint32 stalenessPeriod) internal view returns (bool skipCheck) {
        skipCheck = _validatePriceFeedMetadata(priceFeed, stalenessPeriod);

        try IPriceFeed(priceFeed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80)
        {
            _checkAnswer(answer, updatedAt, stalenessPeriod, skipCheck);
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
        _checkAnswer(answer, updatedAt, stalenessPeriod, skipCheck);
    }
}
