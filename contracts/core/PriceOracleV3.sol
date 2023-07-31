// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import {
    ZeroAddressException,
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
///         Price oracle also allows to set a reserve price feed for a token, that can be activated
///         in case the main one becomes stale or starts returning wrong values.
contract PriceOracleV3 is ACLNonReentrantTrait, PriceFeedValidationTrait, IPriceOracleV3 {
    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @dev Mapping from token address to price feed parameters
    mapping(address => PriceFeedParams) internal _priceFeedsParams;

    /// @notice Constructor
    /// @param addressProvider Address provider contract address
    constructor(address addressProvider) ACLNonReentrantTrait(addressProvider) {}

    /// @notice Returns `token`'s price in USD (with 8 decimals)
    function getPrice(address token) external view override returns (uint256 price) {
        (address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals) = priceFeedParams(token);
        (price,) = _getPrice(priceFeed, stalenessPeriod, skipCheck, decimals);
    }

    /// @notice Returns `token`'s price in USD (with 8 decimals) with explicitly specified price feed
    function getPriceRaw(address token, bool reserve) external view returns (uint256 price) {
        (address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals,) =
            _getPriceFeedParams(reserve ? _getTokenReserveKey(token) : token);
        if (priceFeed == address(0)) revert PriceFeedDoesNotExistException();
        (price,) = _getPrice(priceFeed, stalenessPeriod, skipCheck, decimals);
    }

    /// @notice Converts `amount` of `token` into USD amount (with 8 decimals)
    function convertToUSD(uint256 amount, address token) public view override returns (uint256) {
        (address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals) = priceFeedParams(token);
        (uint256 price, uint256 scale) = _getPrice(priceFeed, stalenessPeriod, skipCheck, decimals);
        return amount * price / scale;
    }

    /// @notice Converts `amount` of USD (with 8 decimals) into `token` amount
    function convertFromUSD(uint256 amount, address token) public view override returns (uint256) {
        (address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals) = priceFeedParams(token);
        (uint256 price, uint256 scale) = _getPrice(priceFeed, stalenessPeriod, skipCheck, decimals);
        return amount * scale / price;
    }

    /// @notice Converts `amount` of `tokenFrom` into `tokenTo` amount
    function convert(uint256 amount, address tokenFrom, address tokenTo) external view override returns (uint256) {
        return convertFromUSD(convertToUSD(amount, tokenFrom), tokenTo);
    }

    /// @notice Returns the price feed for `token` or reverts if price feed is not set
    function priceFeeds(address token) external view override returns (address priceFeed) {
        (priceFeed,,,) = priceFeedParams(token);
    }

    /// @notice Returns the price feed for `token` with explicitly specified price feed
    function priceFeedsRaw(address token, bool reserve) external view override returns (address priceFeed) {
        (priceFeed,,,,) = _getPriceFeedParams(reserve ? _getTokenReserveKey(token) : token);
    }

    /// @notice Returns price feed parameters for `token` or reverts if price feed is not set
    function priceFeedParams(address token)
        public
        view
        override
        returns (address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals)
    {
        bool useReserve;
        (priceFeed, stalenessPeriod, skipCheck, decimals, useReserve) = _getPriceFeedParams(token);
        if (decimals == 0) revert PriceFeedDoesNotExistException();
        if (useReserve) {
            (priceFeed, stalenessPeriod, skipCheck, decimals,) = _getPriceFeedParams(_getTokenReserveKey(token));
        }
    }

    /// @dev Returns price feed answer and scale, optionally performs sanity and staleness checks
    function _getPrice(address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals)
        internal
        view
        returns (uint256 price, uint256 scale)
    {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(priceFeed).latestRoundData();
        if (!skipCheck) _checkAnswer(answer, updatedAt, stalenessPeriod);

        // answer should not be negative (price feeds with `skipCheck = true` must ensure that!)
        price = uint256(answer);

        // 1 <= decimals <= 18, so the operation is safe
        unchecked {
            scale = 10 ** decimals;
        }
    }

    /// @dev Efficiently loads `token`'s price feed parameters from storage
    function _getPriceFeedParams(address token)
        internal
        view
        returns (address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals, bool useReserve)
    {
        PriceFeedParams storage params = _priceFeedsParams[token];
        assembly {
            let data := sload(params.slot)
            priceFeed := data
            stalenessPeriod := and(shr(160, data), 0xFFFFFFFF)
            skipCheck := and(shr(192, data), 0xFF)
            decimals := and(shr(200, data), 0xFF)
            useReserve := and(shr(208, data), 0xFF)
        }
    }

    /// @dev Returns key that is used to store `token`'s reserve feed in `_priceFeedParams`
    function _getTokenReserveKey(address token) internal pure returns (address key) {
        // address(uint160(uint256(keccak256(abi.encodePacked("RESERVE", token)))))
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, or("RESERVE", shl(0x28, token)))
            key := keccak256(ptr, 0x1b)
        }
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets price feed for a given token
    function setPriceFeed(address token, address priceFeed, uint32 stalenessPeriod)
        external
        override
        nonZeroAddress(token) // U:[PO-2]
        nonZeroAddress(priceFeed) // U:[PO-2]
        configuratorOnly
    {
        _setPriceFeed(token, priceFeed, stalenessPeriod);
    }

    /// @dev `setPriceFeed` implementation
    function _setPriceFeed(address token, address priceFeed, uint32 stalenessPeriod) internal {
        uint8 decimals = _priceFeedsParams[token].decimals;
        decimals = decimals == 0 ? _validateToken(token) : decimals;

        bool skipCheck = _validatePriceFeed(priceFeed, stalenessPeriod);
        _priceFeedsParams[token] = PriceFeedParams({
            priceFeed: priceFeed,
            stalenessPeriod: stalenessPeriod,
            skipCheck: skipCheck,
            decimals: decimals,
            useReserve: false
        });

        emit SetPriceFeed(token, priceFeed, stalenessPeriod, skipCheck);
    }

    /// @notice Sets reserve price feed for a given token
    /// @dev Main price feed for the token must already be set
    function setReservePriceFeed(address token, address priceFeed, uint32 stalenessPeriod)
        external
        override
        nonZeroAddress(token)
        nonZeroAddress(priceFeed)
        configuratorOnly
    {
        uint8 decimals = _priceFeedsParams[token].decimals;
        if (decimals == 0) revert PriceFeedDoesNotExistException();

        bool skipCheck = _validatePriceFeed(priceFeed, stalenessPeriod);
        _priceFeedsParams[_getTokenReserveKey(token)] = PriceFeedParams({
            priceFeed: priceFeed,
            stalenessPeriod: stalenessPeriod,
            skipCheck: skipCheck,
            decimals: decimals,
            useReserve: false
        });
        emit SetReservePriceFeed(token, priceFeed, stalenessPeriod, skipCheck);
    }

    /// @notice Sets `token`'s reserve price feed status to `active`
    /// @dev Reserve price feed for the token must already be set
    function setReservePriceFeedStatus(address token, bool active) external override controllerOnly {
        if (_priceFeedsParams[_getTokenReserveKey(token)].priceFeed == address(0)) {
            revert PriceFeedDoesNotExistException();
        }

        if (_priceFeedsParams[token].useReserve != active) {
            _priceFeedsParams[token].useReserve = active;
            emit SetReservePriceFeedStatus(token, active);
        }
    }

    /// @dev Validates that `token` is a contract that returns `decimals` within allowed range
    function _validateToken(address token) internal view returns (uint8 decimals) {
        if (token == address(0)) revert ZeroAddressException();
        if (!Address.isContract(token)) revert AddressIsNotContractException(token);
        try ERC20(token).decimals() returns (uint8 _decimals) {
            if (_decimals == 0 || _decimals > 18) revert IncorrectTokenContractException();
            decimals = _decimals;
        } catch {
            revert IncorrectTokenContractException();
        }
    }
}
