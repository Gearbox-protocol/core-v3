// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
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
///         and reserve feed prices under normal conditions or 0 if reserve feed is active or not set.
///         This logic is skipped if active price feed is trusted, in which case its answer is used.
contract PriceOracleV3 is ACLNonReentrantTrait, PriceFeedValidationTrait, IPriceOracleV3 {
    /// @notice Contract version
    uint256 public constant override version = 3_10;

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
    function getPriceRaw(address token, bool reserve) external view override returns (uint256 price) {
        (price,) = _getPriceRaw(token, reserve);
    }

    /// @notice Converts `amount` of `token` into USD amount (with 8 decimals)
    function convertToUSD(uint256 amount, address token) external view override returns (uint256) {
        (uint256 price, uint256 scale) = _getPrice(token);
        return amount * price / scale;
    }

    /// @notice Converts `amount` of USD (with 8 decimals) into `token` amount
    function convertFromUSD(uint256 amount, address token) external view override returns (uint256) {
        (uint256 price, uint256 scale) = _getPrice(token);
        return amount * scale / price;
    }

    /// @notice Converts `amount` of `tokenFrom` into `tokenTo` amount
    function convert(uint256 amount, address tokenFrom, address tokenTo) external view override returns (uint256) {
        (uint256 priceFrom, uint256 scaleFrom) = _getPrice(tokenFrom);
        (uint256 priceTo, uint256 scaleTo) = _getPrice(tokenTo);
        return amount * priceFrom * scaleTo / (priceTo * scaleFrom);
    }

    /// @notice Converts `amount` of `token` into USD amount (with 8 decimals) using safe price
    function safeConvertToUSD(uint256 amount, address token) external view override returns (uint256) {
        (uint256 price, uint256 scale) = _getPriceSafe(token);
        return amount * price / scale;
    }

    /// @notice Returns the currently active price feed for `token`
    function priceFeeds(address token) external view override returns (address priceFeed) {
        priceFeed = priceFeedParams(token).priceFeed;
    }

    /// @notice Returns the specified price feed for `token`
    function priceFeedsRaw(address token, bool reserve) external view override returns (address priceFeed) {
        priceFeed = priceFeedParamsRaw(token, reserve).priceFeed;
    }

    /// @notice Returns the currently active price feed parameters for `token`
    function priceFeedParams(address token) public view override returns (PriceFeedParams memory params) {
        params = _priceFeedsParams[token];
        if (params.priceFeed != address(0) && !params.active) params = _priceFeedsParams[_getTokenReserveKey(token)];
    }

    /// @notice Returns the specified price feed parameters for `token`
    function priceFeedParamsRaw(address token, bool reserve)
        public
        view
        override
        returns (PriceFeedParams memory params)
    {
        params = _priceFeedsParams[reserve ? _getTokenReserveKey(token) : token];
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets price feed for a given token
    function setPriceFeed(address token, address priceFeed, uint32 stalenessPeriod, bool trusted)
        external
        override
        nonZeroAddress(token) // U:[PO-3]
        nonZeroAddress(priceFeed) // U:[PO-3]
        configuratorOnly // U:[PO-3]
    {
        PriceFeedParams memory params = priceFeedParamsRaw(token, false);
        if (params.priceFeed == address(0)) {
            params.decimals = _validateToken(token); // U:[PO-3]
            params.active = true; // U:[PO-3]
        }

        bool skipCheck = _validatePriceFeed(priceFeed, stalenessPeriod); // U:[PO-3]
        _priceFeedsParams[token] = PriceFeedParams({
            priceFeed: priceFeed,
            stalenessPeriod: stalenessPeriod,
            skipCheck: skipCheck,
            decimals: params.decimals,
            active: params.active,
            trusted: trusted
        }); // U:[PO-3]
        emit SetPriceFeed(token, priceFeed, stalenessPeriod, skipCheck, trusted); // U:[PO-3]
    }

    /// @notice Sets reserve price feed for a given token
    /// @dev Main price feed for the token must already be set
    function setReservePriceFeed(address token, address priceFeed, uint32 stalenessPeriod, bool trusted)
        external
        override
        nonZeroAddress(token) // U:[PO-4]
        nonZeroAddress(priceFeed) // U:[PO-4]
        configuratorOnly // U:[PO-4]
    {
        PriceFeedParams memory params = priceFeedParamsRaw(token, false);
        if (params.priceFeed == address(0)) revert PriceFeedDoesNotExistException(); // U:[PO-4]

        bool skipCheck = _validatePriceFeed(priceFeed, stalenessPeriod); // U:[PO-4]
        _priceFeedsParams[_getTokenReserveKey(token)] = PriceFeedParams({
            priceFeed: priceFeed,
            stalenessPeriod: stalenessPeriod,
            skipCheck: skipCheck,
            decimals: params.decimals,
            active: !params.active,
            trusted: trusted
        }); // U:[PO-4]
        emit SetReservePriceFeed(token, priceFeed, stalenessPeriod, skipCheck, trusted); // U:[PO-4]
    }

    /// @notice Sets `token`'s reserve price feed status to `active`
    /// @dev Reserve price feed for the token must already be set
    function setReservePriceFeedStatus(address token, bool active)
        external
        override
        controllerOnly // U:[PO-5]
    {
        PriceFeedParams memory params = priceFeedParamsRaw(token, true);
        if (params.priceFeed == address(0)) revert PriceFeedDoesNotExistException(); // U:[PO-5]

        if (params.active != active) {
            _priceFeedsParams[token].active = !active; // U:[PO-5]
            _priceFeedsParams[_getTokenReserveKey(token)].active = active; // U:[PO-5]
            emit SetReservePriceFeedStatus(token, active); // U:[PO-5]
        }
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Returns `token`'s price and scale from the currently active price feed
    function _getPrice(address token) internal view returns (uint256 price, uint256 scale) {
        PriceFeedParams memory params = priceFeedParams(token);
        if (params.priceFeed == address(0)) revert PriceFeedDoesNotExistException(); // U:[PO-1]
        return (_getPrice(params), _getScale(params)); // U:[PO-1]
    }

    /// @dev Returns `token`'s price and scale from the specified price feed
    function _getPriceRaw(address token, bool reserve) internal view returns (uint256 price, uint256 scale) {
        PriceFeedParams memory params = priceFeedParamsRaw(token, reserve);
        if (params.priceFeed == address(0)) revert PriceFeedDoesNotExistException();
        return (_getPrice(params), _getScale(params));
    }

    /// @dev Returns `token`'s safe price and scale
    function _getPriceSafe(address token) internal view returns (uint256 price, uint256 scale) {
        PriceFeedParams memory params = priceFeedParamsRaw(token, false);
        if (params.priceFeed == address(0)) revert PriceFeedDoesNotExistException(); // U:[PO-2]
        if (params.active && params.trusted) return (_getPrice(params), _getScale(params)); // U:[PO-2]

        PriceFeedParams memory reserveParams = priceFeedParamsRaw(token, true);
        if (reserveParams.active && reserveParams.trusted) return (_getPrice(reserveParams), _getScale(params)); // U:[PO-2]

        if (reserveParams.active || reserveParams.priceFeed == address(0)) return (0, _getScale(params)); // U:[PO-2]
        return (Math.min(_getPrice(params), _getPrice(reserveParams)), _getScale(params)); // U:[PO-2]
    }

    /// @dev Returns token's price, optionally performs sanity and staleness checks
    function _getPrice(PriceFeedParams memory params) internal view returns (uint256 price) {
        int256 answer = _getValidatedPrice(params.priceFeed, params.stalenessPeriod, params.skipCheck);
        // answer should not be negative (price feeds with `skipCheck = true` must ensure that!)
        price = uint256(answer);
    }

    /// @dev Returns token's scale
    function _getScale(PriceFeedParams memory params) internal pure returns (uint256 scale) {
        unchecked {
            scale = 10 ** params.decimals;
        }
    }

    /// @dev Returns key that is used to store `token`'s reserve feed in `_priceFeedParams`
    function _getTokenReserveKey(address token) internal pure returns (address key) {
        // address(uint160(uint256(keccak256(abi.encodePacked("RESERVE", token)))))
        assembly {
            mstore(0x0, or("RESERVE", shl(0x28, token)))
            key := keccak256(0x0, 0x1b)
        } // U:[PO-6]
    }

    /// @dev Validates that `token` is a contract that returns `decimals` within allowed range
    function _validateToken(address token) internal view returns (uint8 decimals) {
        if (!Address.isContract(token)) revert AddressIsNotContractException(token); // U:[PO-7]
        try ERC20(token).decimals() returns (uint8 _decimals) {
            if (_decimals == 0 || _decimals > 18) revert IncorrectTokenContractException(); // U:[PO-7]
            decimals = _decimals; // U:[PO-7]
        } catch {
            revert IncorrectTokenContractException(); // U:[PO-7]
        }
    }
}
