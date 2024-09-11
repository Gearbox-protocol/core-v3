// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {
    AddressIsNotContractException,
    IncorrectTokenContractException,
    PriceFeedDoesNotExistException,
    PriceFeedIsNotUpdatableException
} from "../interfaces/IExceptions.sol";
import {IPriceOracleV3, PriceFeedParams, PriceUpdate} from "../interfaces/IPriceOracleV3.sol";
import {IUpdatablePriceFeed} from "../interfaces/base/IPriceFeed.sol";

import {ControlledTrait} from "../traits/ControlledTrait.sol";
import {PriceFeedValidationTrait} from "../traits/PriceFeedValidationTrait.sol";
import {SanityCheckTrait} from "../traits/SanityCheckTrait.sol";

/// @title Price oracle V3
/// @notice Acts as router that dispatches calls to corresponding price feeds.
///         - Underlying price feeds can be arbitrary, but they must adhere to Chainlink interface, i.e., implement
///         `latestRoundData` and always return answers with 8 decimals. They may also implement their own price
///         checks, in which case they may incidcate it by returning `skipPriceCheck = true`.
///         - Price oracle also provides "safe" pricing, which uses minimum of main and reserve feed answers. These
///         two feeds are allowed to be the same, which effectively makes it trusted, but to reduce chances of
///         this happening accidentally, reserve price feed must be explicitly set after the main one.
///         The primary purpose of reserve price feeds is to upper-bound main ones during the collateral check after
///         operations that allow users to offload mispriced tokens on Gearbox and withdraw underlying; they should
///         not be used for general collateral evaluation, including decisions on whether accounts are liquidatable.
///         - Finally, this contract serves as register for updatable price feeds and can be used to apply batched
///         on-demand price updates while ensuring that those are not calls to arbitrary contracts.
contract PriceOracleV3 is ControlledTrait, PriceFeedValidationTrait, SanityCheckTrait, IPriceOracleV3 {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Contract type
    bytes32 public constant override contractType = "PRICE_ORACLE";

    /// @dev Mapping from token address to price feed params
    mapping(address => PriceFeedParams) internal _priceFeedsParams;

    /// @dev Set of all tokens that have price feeds
    EnumerableSet.AddressSet internal _tokensSet;

    /// @dev Set of all updatable price feeds
    EnumerableSet.AddressSet internal _updatablePriceFeedsSet;

    /// @notice Constructor
    /// @param _acl ACL contract address
    constructor(address _acl) ControlledTrait(_acl) {}

    /// @notice Returns all tokens that have price feeds
    function getTokens() external view override returns (address[] memory) {
        return _tokensSet.values();
    }

    /// @notice Returns main price feed for `token`
    function priceFeeds(address token) external view override returns (address) {
        return priceFeedParams(token).priceFeed;
    }

    /// @notice Returns reserve price feed for `token`
    function reservePriceFeeds(address token) external view override returns (address) {
        return reservePriceFeedParams(token).priceFeed;
    }

    /// @notice Returns main price feed params for `token`
    function priceFeedParams(address token) public view override returns (PriceFeedParams memory) {
        return _priceFeedsParams[token];
    }

    /// @notice Returns reserve price feed params for `token`
    function reservePriceFeedParams(address token) public view override returns (PriceFeedParams memory) {
        return _priceFeedsParams[_getTokenReserveKey(token)];
    }

    // ---------- //
    // CONVERSION //
    // ---------- //

    /// @notice Returns `token`'s price in USD (with 8 decimals)
    function getPrice(address token) external view override returns (uint256 price) {
        (price,) = _getPrice(token);
    }

    /// @notice Returns `token`'s safe price in USD (with 8 decimals)
    function getSafePrice(address token) external view override returns (uint256 price) {
        (price,) = _getSafePrice(token);
    }

    /// @notice Returns `token`'s price in USD (with 8 decimals) from its reserve price feed
    function getReservePrice(address token) external view override returns (uint256 price) {
        (price,) = _getReservePrice(token);
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
        (uint256 price, uint256 scale) = _getSafePrice(token);
        return amount * price / scale;
    }

    // ------------- //
    // PRICE UPDATES //
    // ------------- //

    /// @notice Returns all updatable price feeds
    function getUpdatablePriceFeeds() external view override returns (address[] memory) {
        return _updatablePriceFeedsSet.values();
    }

    /// @notice Applies on-demand price feed updates, see `PriceUpdate` for details
    /// @custom:tests U:[PO-5]
    function updatePrices(PriceUpdate[] calldata updates) external override {
        unchecked {
            uint256 len = updates.length;
            for (uint256 i; i < len; ++i) {
                if (!_updatablePriceFeedsSet.contains(updates[i].priceFeed)) revert PriceFeedIsNotUpdatableException();
                IUpdatablePriceFeed(updates[i].priceFeed).updatePrice(updates[i].data);
            }
        }
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets `priceFeed` as `token`'s main price feed
    /// @dev If new main price feed coincides with reserve one, unsets the latter
    /// @custom:tests U:[PO-3]
    function setPriceFeed(address token, address priceFeed, uint32 stalenessPeriod)
        external
        override
        nonZeroAddress(token)
        nonZeroAddress(priceFeed)
        controllerOrConfiguratorOnly
    {
        PriceFeedParams memory params = priceFeedParams(token);
        if (params.priceFeed == address(0)) {
            params.tokenDecimals = _validateToken(token);
            _tokensSet.add(token);
        }

        bool skipCheck = _validatePriceFeed(priceFeed, stalenessPeriod);
        _priceFeedsParams[token] = PriceFeedParams({
            priceFeed: priceFeed,
            stalenessPeriod: stalenessPeriod,
            skipCheck: skipCheck,
            tokenDecimals: params.tokenDecimals
        });
        emit SetPriceFeed(token, priceFeed, stalenessPeriod, skipCheck);

        if (priceFeed == reservePriceFeedParams(token).priceFeed) {
            delete _priceFeedsParams[_getTokenReserveKey(token)];
            emit SetReservePriceFeed(token, address(0), 0, false);
        }
    }

    /// @notice Sets `priceFeed` as `token`'s reserve price feed
    /// @dev Main price feed for the token must already be set
    /// @custom:tests U:[PO-4]
    function setReservePriceFeed(address token, address priceFeed, uint32 stalenessPeriod)
        external
        override
        nonZeroAddress(token)
        nonZeroAddress(priceFeed)
        configuratorOnly
    {
        PriceFeedParams memory params = priceFeedParams(token);
        if (params.priceFeed == address(0)) revert PriceFeedDoesNotExistException();

        bool skipCheck = _validatePriceFeed(priceFeed, stalenessPeriod);
        _priceFeedsParams[_getTokenReserveKey(token)] = PriceFeedParams({
            priceFeed: priceFeed,
            stalenessPeriod: stalenessPeriod,
            skipCheck: skipCheck,
            tokenDecimals: params.tokenDecimals
        });
        emit SetReservePriceFeed(token, priceFeed, stalenessPeriod, skipCheck);
    }

    /// @notice Adds `priceFeed` to the set of updatable price feeds
    /// @dev Price feed must be updatable but is not required to satisfy all validity conditions,
    ///      e.g., decimals need not to be equal to 8
    /// @custom:tests U:[PO-5]
    function addUpdatablePriceFeed(address priceFeed) external override nonZeroAddress(priceFeed) configuratorOnly {
        if (!_isUpdatable(priceFeed)) revert PriceFeedIsNotUpdatableException();
        if (_updatablePriceFeedsSet.add(priceFeed)) emit AddUpdatablePriceFeed(priceFeed);
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Returns `token`'s price and scale from its main price feed
    /// @custom:tests U:[PO-1]
    function _getPrice(address token) internal view returns (uint256 price, uint256 scale) {
        PriceFeedParams memory params = priceFeedParams(token);
        if (params.priceFeed == address(0)) revert PriceFeedDoesNotExistException();
        return (_getPrice(params), _getScale(params));
    }

    /// @dev Returns `token`'s safe price and scale computed as minimum between main and reserve feed prices
    /// @custom:tests U:[PO-2]
    function _getSafePrice(address token) internal view returns (uint256 price, uint256 scale) {
        PriceFeedParams memory params = priceFeedParams(token);
        PriceFeedParams memory reserveParams = reservePriceFeedParams(token);
        if (params.priceFeed == address(0)) revert PriceFeedDoesNotExistException();
        if (reserveParams.priceFeed == address(0)) return (0, _getScale(params));
        if (reserveParams.priceFeed == params.priceFeed) return (_getPrice(params), _getScale(params));
        return (Math.min(_getPrice(params), _getPrice(reserveParams)), _getScale(params));
    }

    /// @dev Returns `token`'s price and scale from its reserve price feed
    /// @custom:tests U:[PO-2]
    function _getReservePrice(address token) internal view returns (uint256 price, uint256 scale) {
        PriceFeedParams memory params = reservePriceFeedParams(token);
        if (params.priceFeed == address(0)) revert PriceFeedDoesNotExistException();
        return (_getPrice(params), _getScale(params));
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
            scale = 10 ** params.tokenDecimals;
        }
    }

    /// @dev Returns key that is used to store `token`'s reserve feed in `_priceFeedsParams`
    /// @custom:tests U:[PO-6]
    function _getTokenReserveKey(address token) internal pure returns (address key) {
        // address(uint160(uint256(keccak256(abi.encodePacked("RESERVE", token)))))
        assembly {
            mstore(0x0, or("RESERVE", shl(0x28, token)))
            key := keccak256(0x0, 0x1b)
        }
    }

    /// @dev Validates that `token` is a contract that returns `decimals` within allowed range
    /// @custom:tests U:[PO-7]
    function _validateToken(address token) internal view returns (uint8 decimals) {
        if (!Address.isContract(token)) revert AddressIsNotContractException(token);
        try ERC20(token).decimals() returns (uint8 _decimals) {
            if (_decimals == 0 || _decimals > 18) revert IncorrectTokenContractException();
            decimals = _decimals;
        } catch {
            revert IncorrectTokenContractException();
        }
    }
}
