// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IPriceOracleBase} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracleBase.sol";

struct PriceFeedConfig {
    address token;
    address priceFeed;
}

struct PriceFeedParams {
    address priceFeed;
    bool skipCheck;
    uint8 decimals;
}

interface IPriceOracleV3Events {
    /// @notice Emitted when new price feed is set for token
    event SetPriceFeed(address indexed token, address indexed priceFeed);
}

/// @title Price oracle V3 interface
interface IPriceOracleV3 is IPriceOracleBase, IPriceOracleV3Events {
    function priceFeedParams(address token) external view returns (PriceFeedParams memory);

    function getPriceFeedOrRevert(address token) external view returns (address priceFeed);

    function getPriceFeedParamsOrRevert(address token)
        external
        view
        returns (address priceFeed, bool skipCheck, uint8 decimals);

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function setPriceFeeds(PriceFeedConfig[] memory feeds) external;
}
