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
import {IPriceOracleV3, PriceFeedConfig, PriceFeedParams} from "../interfaces/IPriceOracleV3.sol";
import {IPriceFeedType} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeedType.sol";

import {ACLTrait} from "../traits/ACLTrait.sol";
import {PriceCheckTrait} from "../traits/PriceCheckTrait.sol";

/// @title Price oracle V3
/// @notice Acts as router that dispatches calls to corresponding price feeds.
///         Underlying price feeds can be arbitrary, but they must adhere to Chainlink interface,
///         e.g., implement `latestRoundData` and always return answers with 8 decimals.
///         They may also implement their own price checks, in which case they may incidcate it
///         to the price oracle by returning `skipPriceCheck = true`.
contract PriceOracleV3 is ACLTrait, PriceCheckTrait, IPriceOracleV3 {
    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @dev Mapping token address to corresponding price feed parameters
    mapping(address => PriceFeedParams) internal _priceFeedParams;

    /// @notice Constructor
    /// @param addressProvider Address provider contract address
    /// @param feeds Array of (token, priceFeed) pairs
    constructor(address addressProvider, PriceFeedConfig[] memory feeds) ACLTrait(addressProvider) {
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

    /// @notice Returns the price feed for `token`
    function priceFeeds(address token) external view override returns (address priceFeed) {
        return _priceFeedParams[token].priceFeed;
    }

    /// @notice Returns price feed params for `token`
    function priceFeedParams(address token) external view override returns (PriceFeedParams memory) {
        return _priceFeedParams[token];
    }

    /// @notice Returns the price feed for `token` or reverts if it is not set
    function getPriceFeedOrRevert(address token) external view override returns (address priceFeed) {
        priceFeed = _priceFeedParams[token].priceFeed;
        if (priceFeed == address(0)) revert PriceFeedDoesNotExistException();
    }

    /// @notice Returns price feed params for `token` or reverts if price feed is not set
    function getPriceFeedParamsOrRevert(address token)
        public
        view
        override
        returns (address priceFeed, bool skipCheck, uint8 decimals)
    {
        // since params take up one storage slot, it's cheaper to copy it to
        // the memory once instead of doing an SLOAD per each struct field
        PriceFeedParams memory params = _priceFeedParams[token];
        if (params.priceFeed == address(0)) revert PriceFeedDoesNotExistException();
        return (params.priceFeed, params.skipCheck, params.decimals);
    }

    /// @dev `getPrice` implementation
    function _getPrice(address token) internal view returns (uint256, uint256) {
        (address priceFeed, bool skipCheck, uint8 decimals) = getPriceFeedParamsOrRevert(token);
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(priceFeed).latestRoundData();
        if (!skipCheck) _checkAnswer(answer, updatedAt);
        // answer should not be negative (price feeds with `skipCheck = true` must ensure that!)
        return (uint256(answer), decimals);
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets price feed for a given token
    function addPriceFeed(address token, address priceFeed) external override configuratorOnly {
        _setPriceFeed(token, priceFeed);
    }

    /// @notice Sets price feeds for multiple tokens in batch
    /// @param feeds Array of (token, priceFeed) pairs
    function setPriceFeeds(PriceFeedConfig[] memory feeds) external override configuratorOnly {
        _setPriceFeeds(feeds);
    }

    /// @dev `setPriceFeeds` implementation
    function _setPriceFeeds(PriceFeedConfig[] memory feeds) internal {
        uint256 len = feeds.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                _setPriceFeed(feeds[i].token, feeds[i].priceFeed);
            }
        }
    }

    /// @dev `setPriceFeed` implementation
    function _setPriceFeed(address token, address priceFeed) internal {
        if (token == address(0) || priceFeed == address(0)) {
            revert ZeroAddressException();
        }

        if (!Address.isContract(token)) revert AddressIsNotContractException(token);
        if (!Address.isContract(priceFeed)) revert AddressIsNotContractException(priceFeed);

        try AggregatorV3Interface(priceFeed).decimals() returns (uint8 _decimals) {
            if (_decimals != 8) revert IncorrectPriceFeedException();
        } catch {
            revert IncorrectPriceFeedException();
        }

        bool skipCheck;
        try IPriceFeedType(priceFeed).skipPriceCheck() returns (bool _skipCheck) {
            skipCheck = _skipCheck;
        } catch {}

        uint8 decimals;
        try ERC20(token).decimals() returns (uint8 _decimals) {
            if (_decimals > 18) revert IncorrectTokenContractException();
            decimals = _decimals;
        } catch {
            revert IncorrectTokenContractException();
        }

        try AggregatorV3Interface(priceFeed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (!skipCheck) _checkAnswer(answer, updatedAt);
        } catch {
            revert IncorrectPriceFeedException();
        }

        _priceFeedParams[token] = PriceFeedParams(priceFeed, skipCheck, decimals);
        emit SetPriceFeed(token, priceFeed);
    }
}
