// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAliasedLossPolicyV3} from "../interfaces/IAliasedLossPolicyV3.sol";
import {ICreditAccountV3} from "../interfaces/ICreditAccountV3.sol";
import {ICreditManagerV3, CollateralTokenData} from "../interfaces/ICreditManagerV3.sol";
import {IMatchingEngineV3} from "../interfaces/IMatchingEngineV3.sol";
import {IPriceOracleV3, PriceFeedParams} from "../interfaces/IPriceOracleV3.sol";
import {IAddressProvider} from "../interfaces/base/IAddressProvider.sol";
import {IPriceFeedStore, PriceUpdate} from "../interfaces/base/IPriceFeedStore.sol";

import {BitMask} from "../libraries/BitMask.sol";
import {
    AP_PRICE_FEED_STORE,
    NO_VERSION_CONTROL,
    PERCENTAGE_FACTOR,
    RAY,
    UNDERLYING_TOKEN_MASK
} from "../libraries/Constants.sol";
import {MarketHelper} from "../libraries/MarketHelper.sol";

import {ACLTrait} from "../traits/ACLTrait.sol";
import {PriceFeedValidationTrait} from "../traits/PriceFeedValidationTrait.sol";

import {TokenIsNotQuotedException} from "../interfaces/IExceptions.sol";

/// @title Aliased loss policy V3
/// @notice Loss policy that allows to double-check the decision on whether to liquidate a credit account with bad debt
///         using TWV recomputed with alias price feeds. This can be useful in scenarios where token's market price
///         drops for a short period of time while its fundamental value remains the same.
///         It also allows to restrict such liquidations to only be performed by accounts with `LOSS_LIQUIDATOR` role
///         which can then return premium to recover part of the losses.
contract AliasedLossPolicyV3 is ACLTrait, PriceFeedValidationTrait, IAliasedLossPolicyV3 {
    using BitMask for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using MarketHelper for IMatchingEngineV3;

    /// @dev Internal enum with possible price feed types
    enum PriceFeedType {
        Normal,
        Aliased
    }

    /// @dev Internal struct that contains shared info needed for collateral calculation
    struct SharedInfo {
        address creditManager;
        address priceOracle;
    }

    /// @dev Internal struct that contains token info needed for collateral calculation
    struct TokenInfo {
        address token;
        uint16 lt;
        uint256 balance;
        PriceFeedParams aliasParams;
    }

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Contract type
    bytes32 public constant override contractType = "LOSS_POLICY::ALIASED";

    /// @notice Price feed store
    address public immutable override priceFeedStore;

    /// @notice Access mode for loss liquidations
    AccessMode public override accessMode = AccessMode.Permissionless;

    /// @notice Whether policy checks are enabled
    bool public override checksEnabled = true;

    /// @dev Set of tokens that have alias price feeds
    EnumerableSet.AddressSet internal _tokensWithAliasSet;

    /// @dev Mapping from token to its alias price feed parameters
    mapping(address => PriceFeedParams) internal _aliasPriceFeedParams;

    /// @notice Constructor
    /// @param matchingEngine_ Matching engine address
    /// @param addressProvider_ Address provider contract address
    /// @custom:tests U:[ALP-1]
    constructor(address matchingEngine_, address addressProvider_)
        ACLTrait(IMatchingEngineV3(matchingEngine_).getACL())
    {
        priceFeedStore = IAddressProvider(addressProvider_).getAddressOrRevert(AP_PRICE_FEED_STORE, NO_VERSION_CONTROL);
    }

    // ------- //
    // GETTERS //
    // ------- //

    /// @notice Serializes the loss policy state
    /// @custom:tests U:[ALP-1], U:[ALP-2], U:[ALP-3]
    function serialize() external view override returns (bytes memory) {
        address[] memory tokens = _tokensWithAliasSet.values();
        uint256 numTokens = tokens.length;
        PriceFeedParams[] memory priceFeedParams = new PriceFeedParams[](numTokens);
        for (uint256 i; i < numTokens; ++i) {
            priceFeedParams[i] = _aliasPriceFeedParams[tokens[i]];
        }
        return abi.encode(accessMode, checksEnabled, tokens, priceFeedParams);
    }

    /// @notice Returns whether `creditAccount` can be liquidated with loss by `caller`
    /// @custom:tests U:[ALP-4], U:[ALP-5]
    function isLiquidatableWithLoss(address creditAccount, address caller, Params calldata params)
        external
        override
        returns (bool)
    {
        AccessMode accessMode_ = accessMode;
        if (accessMode_ == AccessMode.Forbidden) return false;
        if (accessMode_ == AccessMode.Permissioned && !_hasRole("LOSS_LIQUIDATOR", caller)) return false;
        if (!checksEnabled) return true;

        _updatePrices(params.extraData);

        return _adjustForAliases(creditAccount, params.twvUSD) < params.totalDebtUSD;
    }

    /// @notice Returns the list of tokens that have alias price feeds
    function getTokensWithAlias() external view override returns (address[] memory) {
        return _tokensWithAliasSet.values();
    }

    /// @notice Returns `token`'s alias price feed parameters
    function getAliasPriceFeedParams(address token) external view override returns (PriceFeedParams memory) {
        return _aliasPriceFeedParams[token];
    }

    /// @notice Returns the list of alias price feeds that need to return a valid price to liquidate `creditAccount`
    function getRequiredAliasPriceFeeds(address creditAccount)
        external
        view
        override
        returns (address[] memory priceFeeds)
    {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        CollateralTokenData[] memory collateralTokens =
            ICreditManagerV3(creditManager).collateralTokensOf(creditAccount);
        priceFeeds = new address[](collateralTokens.length);
        uint256 numAliases;
        for (uint256 i = 0; i < collateralTokens.length; ++i) {
            address token = collateralTokens[i].token;
            address aliasPriceFeed = _aliasPriceFeedParams[token].priceFeed;
            if (aliasPriceFeed != address(0)) priceFeeds[numAliases++] = aliasPriceFeed;
        }
        assembly {
            mstore(priceFeeds, numAliases)
        }
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets access mode for liquidations
    /// @dev Reverts if caller is not configurator
    /// @custom:tests U:[ALP-2]
    function setAccessMode(AccessMode mode) external override configuratorOnly {
        if (accessMode == mode) return;
        accessMode = mode;
        emit SetAccessMode(mode);
    }

    /// @notice Enables or disables policy checks
    /// @dev Reverts if caller is not configurator
    /// @custom:tests U:[ALP-2]
    function setChecksEnabled(bool enabled) external override configuratorOnly {
        if (checksEnabled == enabled) return;
        checksEnabled = enabled;
        emit SetChecksEnabled(enabled);
    }

    /// @notice Sets `token`'s alias price feed to `priceFeed`, unsets it if `priceFeed` is zero
    /// @dev Reverts if caller is not configurator
    /// @dev Reverts if `token` is not quoted (including underlying)
    /// @dev Reverts if `priceFeed` is not known to the price feed store
    /// @custom:tests U:[ALP-3]
    function setAliasPriceFeed(address token, address priceFeed) external override configuratorOnly {
        if (_aliasPriceFeedParams[token].priceFeed == priceFeed) return;

        if (priceFeed == address(0)) {
            if (_tokensWithAliasSet.remove(token)) {
                delete _aliasPriceFeedParams[token];
                emit UnsetAliasPriceFeed(token);
            }
            return;
        }

        uint32 stalenessPeriod = IPriceFeedStore(priceFeedStore).getStalenessPeriod(priceFeed);
        bool skipCheck = _validatePriceFeed(priceFeed, stalenessPeriod);
        _aliasPriceFeedParams[token] = PriceFeedParams({
            priceFeed: priceFeed,
            stalenessPeriod: stalenessPeriod,
            skipCheck: skipCheck,
            tokenDecimals: ERC20(token).decimals()
        });

        _tokensWithAliasSet.add(token);
        emit SetAliasPriceFeed(token, priceFeed, stalenessPeriod, skipCheck);
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev If provided non-empty `data`, updates prices in the price feed store
    /// @custom:tests U:[ALP-5]
    function _updatePrices(bytes calldata data) internal {
        if (data.length == 0) return;
        PriceUpdate[] memory priceUpdates = abi.decode(data, (PriceUpdate[]));
        IPriceFeedStore(priceFeedStore).updatePrices(priceUpdates);
    }

    /// @dev Adjusts credit account's TWV for difference between normal and alias price feeds
    /// @custom:tests U:[ALP-7]
    function _adjustForAliases(address creditAccount, uint256 twvUSD) internal view returns (uint256 twvUSDAliased) {
        SharedInfo memory sharedInfo = _getSharedInfo(creditAccount);
        twvUSDAliased = twvUSD;

        CollateralTokenData[] memory collateralTokens =
            ICreditManagerV3(sharedInfo.creditManager).collateralTokensOf(creditAccount);

        for (uint256 i = 0; i < collateralTokens.length; ++i) {
            TokenInfo memory tokenInfo = _getTokenInfo(creditAccount, collateralTokens[i].token, collateralTokens[i].lt);
            if (tokenInfo.balance == 0) continue;

            twvUSDAliased += _getWeightedValueUSD(tokenInfo, sharedInfo, PriceFeedType.Aliased);
            twvUSDAliased -= _getWeightedValueUSD(tokenInfo, sharedInfo, PriceFeedType.Normal);
        }
    }

    /// @dev Returns the shared info needed for `creditAccount` collateral value calculation
    /// @custom:tests U:[ALP-8]
    function _getSharedInfo(address creditAccount) internal view returns (SharedInfo memory sharedInfo) {
        sharedInfo.creditManager = ICreditAccountV3(creditAccount).creditManager();
        sharedInfo.priceOracle = ICreditManagerV3(sharedInfo.creditManager).priceOracleOf(creditAccount);
    }

    /// @dev Returns the token info needed for `creditAccount` collateral value calculation
    /// @custom:tests U:[ALP-9]
    function _getTokenInfo(address creditAccount, address token, uint16 lt)
        internal
        view
        returns (TokenInfo memory info)
    {
        (info.token, info.lt) = (token, lt);
        if (info.lt == 0) return info;

        info.aliasParams = _aliasPriceFeedParams[info.token];
        if (info.aliasParams.priceFeed == address(0)) return info;

        info.balance = ERC20(info.token).balanceOf(creditAccount);
        if (info.balance == 0) return info;
    }

    /// @dev Returns the weighted value in USD (computed via either normal or alias price feed) for a single token
    /// @custom:tests U:[ALP-10]
    function _getWeightedValueUSD(TokenInfo memory tokenInfo, SharedInfo memory sharedInfo, PriceFeedType priceFeedType)
        internal
        view
        returns (uint256)
    {
        uint256 valueUSD = priceFeedType == PriceFeedType.Aliased
            ? _convertToUSDAlias(tokenInfo.aliasParams, tokenInfo.balance)
            : IPriceOracleV3(sharedInfo.priceOracle).convertToUSD(tokenInfo.balance, tokenInfo.token);

        return valueUSD * tokenInfo.lt / PERCENTAGE_FACTOR;
    }

    /// @dev Converts token amount to USD using its alias price feed
    /// @custom:tests U:[ALP-11]
    function _convertToUSDAlias(PriceFeedParams memory aliasParams, uint256 amount) internal view returns (uint256) {
        int256 answer = _getValidatedPrice(aliasParams.priceFeed, aliasParams.stalenessPeriod, aliasParams.skipCheck);
        return uint256(answer) * amount / (10 ** aliasParams.tokenDecimals);
    }
}
