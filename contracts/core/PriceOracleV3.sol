// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    AddressIsNotContractException,
    IncorrectTokenContractException,
    PriceFeedDoesNotExistException
} from "../interfaces/IExceptions.sol";
import {IPriceOracleV3, PriceFeedParams} from "../interfaces/IPriceOracleV3.sol";

import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {PriceFeedValidationTrait} from "../traits/PriceFeedValidationTrait.sol";

/// @title Price oracle V3
/// @notice Acts as router that dispatches calls to corresponding price feeds.
///         Underlying price feeds can be arbitrary, but they must adhere to Chainlink interface,
///         e.g., implement `latestRoundData` and always return answers with 8 decimals.
///         They may also implement their own price checks, in which case they may incidcate it
///         to the price oracle by returning `skipPriceCheck = true`.
/// @notice Price oracle also allows to set a reserve price feed for a token, that can be activated
///         in case the main one becomes stale or starts returning wrong values.
///         One should not expect the reserve price feed to always differ from the main one, although
///         most often that would be the case.
/// @notice Price oracle additionaly provides "safe" conversion functions, which use minimum of main
///         and reserve feed prices (the latter is assumed to be zero if reserve feed is not set).
///         There are also trusted price feeds, for which safe prices are simply main feed prices.
contract PriceOracleV3 is ACLNonReentrantTrait, PriceFeedValidationTrait, IPriceOracleV3 {
    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @dev Mapping from token address to price feed parameters
    mapping(address => PriceFeedParams) internal _priceFeedsParams;

    /// @notice Constructor
    /// @param addressProvider Address provider contract address
    constructor(address addressProvider) ACLNonReentrantTrait(addressProvider) {}

    /// @notice Returns `token`'s price in USD (with 8 decimals) from the currently active price feed
    function getPrice(address token) external view override returns (uint256 price) {
        (price,) = _getPrice(token);
    }

    /// @notice Returns `token`'s safe price in USD (with 8 decimals)
    function getPriceSafe(address token) external view override returns (uint256 price) {
        (price,) = _getPriceSafe(token);
    }

    /// @notice Returns `token`'s price in USD (with 8 decimals) from the specified price feed
    function getPriceRaw(address token, bool reserve) external view returns (uint256 price) {
        (price,) = _getPriceRaw(token, reserve);
    }

    /// @notice Converts `amount` of `token` into USD amount (with 8 decimals)
    function convertToUSD(uint256 amount, address token) external view override returns (uint256) {
        (uint256 price, uint256 scale) = _getPrice(token);
        return amount * price / scale; // U:[PO-9]
    }

    /// @notice Converts `amount` of USD (with 8 decimals) into `token` amount
    function convertFromUSD(uint256 amount, address token) external view override returns (uint256) {
        (uint256 price, uint256 scale) = _getPrice(token);
        return amount * scale / price; // U:[PO-9]
    }

    /// @notice Converts `amount` of `tokenFrom` into `tokenTo` amount
    function convert(uint256 amount, address tokenFrom, address tokenTo) external view override returns (uint256) {
        (uint256 priceFrom, uint256 scaleFrom) = _getPrice(tokenFrom);
        (uint256 priceTo, uint256 scaleTo) = _getPrice(tokenTo);
        return amount * priceFrom * scaleTo / (priceTo * scaleFrom); // U:[PO-10]
    }

    /// @notice Converts `amount` of `token` into USD amount (with 8 decimals) using safe price
    function safeConvertToUSD(uint256 amount, address token) external view override returns (uint256) {
        (uint256 price, uint256 scale) = _getPriceSafe(token);
        return amount * price / scale; // U:[PO-11]
    }

    /// @notice Returns the price feed for `token` or reverts if price feed is not set
    function priceFeeds(address token) external view override returns (address priceFeed) {
        (priceFeed,,,,) = priceFeedParams(token); // U:[PO-8]
    }

    /// @notice Returns the specified price feed for `token`
    function priceFeedsRaw(address token, bool reserve) external view override returns (address priceFeed) {
        (priceFeed,,,,,) = _getPriceFeedParams(reserve ? _getTokenReserveKey(token) : token);
    }

    /// @notice Returns currently active price feed parameters for `token` or reverts if price feed is not set
    function priceFeedParams(address token)
        public
        view
        override
        returns (address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals, bool trusted)
    {
        bool useReserve;
        (priceFeed, stalenessPeriod, skipCheck, decimals, useReserve, trusted) = _getPriceFeedParams(token);
        if (useReserve) {
            (priceFeed, stalenessPeriod, skipCheck, decimals,, trusted) =
                _getPriceFeedParams(_getTokenReserveKey(token));
        }
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Returns `token`'s price and scale from the currently active price feed
    function _getPrice(address token) internal view returns (uint256 price, uint256 scale) {
        (address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals,) = priceFeedParams(token);
        return _getPrice(priceFeed, stalenessPeriod, skipCheck, decimals);
    }

    /// @dev Returns `token`'s price and scale from the explicitly specified price feed
    function _getPriceRaw(address token, bool reserve) internal view returns (uint256 price, uint256 scale) {
        (address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals,,) =
            _getPriceFeedParams(reserve ? _getTokenReserveKey(token) : token);
        return _getPrice(priceFeed, stalenessPeriod, skipCheck, decimals);
    }

    /// @dev Returns `token`'s safe price and scale
    function _getPriceSafe(address token) internal view returns (uint256 price, uint256 scale) {
        (address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals,, bool trusted) =
            _getPriceFeedParams(token);
        (price, scale) = _getPrice(priceFeed, stalenessPeriod, skipCheck, decimals); // U:[PO-11]

        if (!trusted) {
            if (_priceFeedsParams[_getTokenReserveKey(token)].priceFeed == address(0)) return (0, scale); // U:[PO-11]
            (uint256 reservePrice,) = _getPriceRaw(token, true);
            price = Math.min(price, reservePrice); // U:[PO-11]
        }
    }

    /// @dev Returns price feed answer and scale, optionally performs sanity and staleness checks
    function _getPrice(address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals)
        internal
        view
        returns (uint256 price, uint256 scale)
    {
        int256 answer = _getValidatedPrice(priceFeed, stalenessPeriod, skipCheck); // U:[PO-1]

        // answer should not be negative (price feeds with `skipCheck = true` must ensure that!)
        price = uint256(answer); // U:[PO-1]

        // 1 <= decimals <= 18, so the operation is safe
        unchecked {
            scale = 10 ** decimals; // U:[PO-1]
        }
    }

    /// @dev Efficiently loads `token`'s price feed parameters from storage
    function _getPriceFeedParams(address token)
        internal
        view
        returns (
            address priceFeed,
            uint32 stalenessPeriod,
            bool skipCheck,
            uint8 decimals,
            bool useReserve,
            bool trusted
        )
    {
        PriceFeedParams storage params = _priceFeedsParams[token];
        assembly {
            let data := sload(params.slot)
            priceFeed := data
            stalenessPeriod := shr(160, data)
            skipCheck := and(shr(192, data), 0x01)
            decimals := shr(200, data)
            useReserve := and(shr(208, data), 0x01)
            trusted := and(shr(216, data), 0x01)
        } // U:[PO-2]

        if (priceFeed == address(0)) revert PriceFeedDoesNotExistException(); // U:[PO-2]
    }

    /// @dev Returns key that is used to store `token`'s reserve feed in `_priceFeedParams`
    function _getTokenReserveKey(address token) internal pure returns (address key) {
        // address(uint160(uint256(keccak256(abi.encodePacked("RESERVE", token)))))
        assembly {
            mstore(0x0, or("RESERVE", shl(0x28, token)))
            key := keccak256(0x0, 0x1b)
        } // U:[PO-3]
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets price feed for a given token
    function setPriceFeed(address token, address priceFeed, uint32 stalenessPeriod, bool trusted)
        external
        override
        nonZeroAddress(token) // U:[PO-6]
        nonZeroAddress(priceFeed) // U:[PO-6]
        configuratorOnly // U:[PO-6]
    {
        uint8 decimals = _priceFeedsParams[token].decimals;
        decimals = decimals == 0 ? _validateToken(token) : decimals; // U:[PO-6]

        bool skipCheck = _validatePriceFeed(priceFeed, stalenessPeriod); // U:[PO-6]
        _priceFeedsParams[token] = PriceFeedParams({
            priceFeed: priceFeed,
            stalenessPeriod: stalenessPeriod,
            skipCheck: skipCheck,
            decimals: decimals,
            useReserve: false,
            trusted: trusted
        }); // U:[PO-6]
        emit SetPriceFeed(token, priceFeed, stalenessPeriod, skipCheck, trusted); // U:[PO-6]
    }

    /// @notice Sets reserve price feed for a given token
    /// @dev Main price feed for the token must already be set
    function setReservePriceFeed(address token, address priceFeed, uint32 stalenessPeriod)
        external
        override
        nonZeroAddress(token) // U:[PO-7]
        nonZeroAddress(priceFeed) // U:[PO-7]
        configuratorOnly // U:[PO-7]
    {
        uint8 decimals = _priceFeedsParams[token].decimals;
        if (decimals == 0) revert PriceFeedDoesNotExistException(); // U:[PO-7]

        bool skipCheck = _validatePriceFeed(priceFeed, stalenessPeriod); // U:[PO-7]
        _priceFeedsParams[_getTokenReserveKey(token)] = PriceFeedParams({
            priceFeed: priceFeed,
            stalenessPeriod: stalenessPeriod,
            skipCheck: skipCheck,
            decimals: decimals,
            useReserve: false,
            trusted: false
        }); // U:[PO-7]
        emit SetReservePriceFeed(token, priceFeed, stalenessPeriod, skipCheck); // U:[PO-7]
    }

    /// @notice Sets `token`'s reserve price feed status to `active`
    /// @dev Reserve price feed for the token must already be set
    function setReservePriceFeedStatus(address token, bool active)
        external
        override
        controllerOnly // U:[PO-8]
    {
        if (_priceFeedsParams[_getTokenReserveKey(token)].priceFeed == address(0)) {
            revert PriceFeedDoesNotExistException(); // U:[PO-8]
        }

        if (_priceFeedsParams[token].useReserve != active) {
            _priceFeedsParams[token].useReserve = active; // U:[PO-8]
            emit SetReservePriceFeedStatus(token, active); // U:[PO-8]
        }
    }

    /// @dev Validates that `token` is a contract that returns `decimals` within allowed range
    function _validateToken(address token) internal view returns (uint8 decimals) {
        if (!Address.isContract(token)) revert AddressIsNotContractException(token); // U:[PO-4]
        try ERC20(token).decimals() returns (uint8 _decimals) {
            if (_decimals == 0 || _decimals > 18) revert IncorrectTokenContractException(); // U:[PO-4]
            decimals = _decimals; // U:[PO-4]
        } catch {
            revert IncorrectTokenContractException(); // U:[PO-4]
        }
    }
}
