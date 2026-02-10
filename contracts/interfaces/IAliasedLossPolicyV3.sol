// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IACLTrait} from "./base/IACLTrait.sol";
import {ILossPolicy} from "./base/ILossPolicy.sol";
import {PriceFeedParams} from "./IPriceOracleV3.sol";

interface IAliasedLossPolicyV3Events {
    event SetAliasPriceFeed(address indexed token, address indexed priceFeed, uint32 stalenessPeriod, bool skipCheck);
    event UnsetAliasPriceFeed(address indexed token);
}

/// @title Aliased loss policy v3 interface
interface IAliasedLossPolicyV3 is IAliasedLossPolicyV3Events, ILossPolicy, IACLTrait {
    // ------- //
    // GETTERS //
    // ------- //

    function priceFeedStore() external view returns (address);
    function getTokensWithAlias() external view returns (address[] memory);
    function getAliasPriceFeedParams(address token) external view returns (PriceFeedParams memory);
    function getRequiredAliasPriceFeeds(address creditAccount) external view returns (address[] memory);

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function setAliasPriceFeed(address token, address priceFeed) external;
}
