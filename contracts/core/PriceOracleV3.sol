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
    IncorrectPriceFeedException,
    IncorrectTokenContractException,
    PriceFeedDoesNotExistException
} from "../interfaces/IExceptions.sol";
import {IPriceOracleV3, PriceFeedConfig, PriceFeedParams, TokenParams} from "../interfaces/IPriceOracleV3.sol";
import {IPriceFeedType} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeedType.sol";

import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {PriceCheckTrait} from "../traits/PriceCheckTrait.sol";

/// @title Price oracle V3
/// @notice Acts as router that dispatches calls to corresponding price feeds.
///         Underlying price feeds can be arbitrary, but they must adhere to Chainlink interface,
///         e.g., implement `latestRoundData` and always return answers with 8 decimals.
///         They may also implement their own price checks, in which case they may incidcate it
///         to the price oracle by returning `skipPriceCheck = true`.
///         Price oracle also allows to set a reserve price feed for a token, that can be activated
///         in case the main one becomes stale or starts returning wrong values.
contract PriceOracleV3 is ACLNonReentrantTrait, PriceCheckTrait, IPriceOracleV3 {
    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice Default staleness period
    uint32 public constant override DEFAULT_STALENESS_PERIOD = 2 hours;

    /// @dev Mapping from token address to token parameters (including main price feed parameters)
    mapping(address => TokenParams) internal _tokenParams;

    /// @dev Mapping from token address to reserve price feed parameters
    mapping(address => PriceFeedParams) internal _reserveFeedParams;

    /// @notice Constructor
    /// @param addressProvider Address provider contract address
    /// @param feeds Array of (token, priceFeed, stalenessPeriod) tuples
    constructor(address addressProvider, PriceFeedConfig[] memory feeds) ACLNonReentrantTrait(addressProvider) {
        _setPriceFeeds(feeds);
    }

    /// @notice Returns `token`'s price in USD (with 8 decimals)
    function getPrice(address token) external view override returns (uint256 price) {
        (price,) = _getPrice(token);
    }

    /// @notice Converts `amount` of `token` into USD amount (with 8 decimals)
    function convertToUSD(uint256 amount, address token) public view override returns (uint256) {
        (uint256 price, uint256 decimals) = _getPrice(token);
        return amount * price / 10 ** decimals;
    }

    /// @notice Converts `amount` of USD (with 8 decimals) into `token` amount
    function convertFromUSD(uint256 amount, address token) public view override returns (uint256) {
        (uint256 price, uint256 decimals) = _getPrice(token);
        return amount * 10 ** decimals / price;
    }

    /// @notice Converts `amount` of `tokenFrom` into `tokenTo` amount
    function convert(uint256 amount, address tokenFrom, address tokenTo) external view override returns (uint256) {
        return convertFromUSD(convertToUSD(amount, tokenFrom), tokenTo);
    }

    /// @notice Returns the price feed for `token` or reverts if price feed is not set
    function priceFeeds(address token) external view override returns (address priceFeed) {
        (PriceFeedParams storage params,) = _getPriceFeedParams(token);
        return params.priceFeed;
    }

    /// @notice Returns price feed parameters for `token` or reverts if price feed is not set
    function priceFeedParams(address token)
        external
        view
        override
        returns (address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals)
    {
        (PriceFeedParams memory params, uint8 _decimals) = _getPriceFeedParams(token);
        return (params.priceFeed, params.stalenessPeriod, params.skipCheck, _decimals);
    }

    /// @dev Returns `token`'s price according to the price feed (either main or reserve) and decimals
    /// @dev Optionally performs price sanity and staleness checks
    function _getPrice(address token) internal view returns (uint256, uint256) {
        (PriceFeedParams storage params, uint8 decimals) = _getPriceFeedParams(token);
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(params.priceFeed).latestRoundData();
        if (!params.skipCheck) _checkAnswer(answer, updatedAt, params.stalenessPeriod);
        // answer should not be negative (price feeds with `skipCheck = true` must ensure that!)
        return (uint256(answer), decimals);
    }

    /// @dev Returns `token`'s price feed parameters (either main or reserve) and decimals
    function _getPriceFeedParams(address token)
        internal
        view
        returns (PriceFeedParams storage params, uint8 decimals)
    {
        TokenParams storage tokenParams = _tokenParams[token];
        decimals = tokenParams.decimals;
        if (decimals == 0) revert PriceFeedDoesNotExistException();
        params = tokenParams.useReserve ? _reserveFeedParams[token] : tokenParams.mainFeedParams;
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets price feed for a given token with default staleness period
    function addPriceFeed(address token, address priceFeed) external override configuratorOnly {
        _setPriceFeed(token, priceFeed, DEFAULT_STALENESS_PERIOD);
    }

    /// @notice Sets price feeds for multiple tokens in batch
    /// @param feeds Array of (token, priceFeed, stalenessPeriod) tuples
    function setPriceFeeds(PriceFeedConfig[] calldata feeds) external override configuratorOnly {
        _setPriceFeeds(feeds);
    }

    /// @notice Sets reserve price feeds for multiple tokens in batch
    /// @param feeds Array of (token, priceFeed, stalenessPeriod) tuples
    /// @dev Main price feeds for all tokens must already be set
    function setReservePriceFeeds(PriceFeedConfig[] calldata feeds) external override configuratorOnly {
        uint256 len = feeds.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                _setReservePriceFeed(feeds[i].token, feeds[i].priceFeed, feeds[i].stalenessPeriod);
            }
        }
    }

    /// @dev `setPriceFeeds` implementation
    function _setPriceFeeds(PriceFeedConfig[] memory feeds) internal {
        uint256 len = feeds.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                _setPriceFeed(feeds[i].token, feeds[i].priceFeed, feeds[i].stalenessPeriod);
            }
        }
    }

    /// @dev `setPriceFeed` implementation
    function _setPriceFeed(address token, address priceFeed, uint32 stalenessPeriod) internal {
        TokenParams storage params = _tokenParams[token];
        if (params.decimals == 0) params.decimals = _validateToken(token);

        _tokenParams[token].mainFeedParams = PriceFeedParams({
            priceFeed: priceFeed,
            skipCheck: _validatePriceFeed(priceFeed, stalenessPeriod),
            stalenessPeriod: stalenessPeriod
        });

        emit SetPriceFeed(token, priceFeed);
    }

    /// @dev `setReservePriceFeed` implementation
    function _setReservePriceFeed(address token, address priceFeed, uint32 stalenessPeriod) internal {
        if (_tokenParams[token].decimals == 0) revert PriceFeedDoesNotExistException();

        _reserveFeedParams[token] = PriceFeedParams({
            priceFeed: priceFeed,
            skipCheck: _validatePriceFeed(priceFeed, stalenessPeriod),
            stalenessPeriod: stalenessPeriod
        });

        emit SetReservePriceFeed(token, priceFeed);
    }

    /// @dev Validates that token is a contract that returns `decimals` within allowed range
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

    function _validatePriceFeed(address priceFeed, uint32 stalenessPeriod) internal view returns (bool skipCheck) {
        if (priceFeed == address(0)) revert ZeroAddressException();
        if (!Address.isContract(priceFeed)) revert AddressIsNotContractException(priceFeed);

        try AggregatorV3Interface(priceFeed).decimals() returns (uint8 _decimals) {
            if (_decimals != 8) revert IncorrectPriceFeedException();
        } catch {
            revert IncorrectPriceFeedException();
        }

        try IPriceFeedType(priceFeed).skipPriceCheck() returns (bool _skipCheck) {
            skipCheck = _skipCheck;
        } catch {}

        try AggregatorV3Interface(priceFeed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (!skipCheck) _checkAnswer(answer, updatedAt, stalenessPeriod);
        } catch {
            revert IncorrectPriceFeedException();
        }
    }
}
