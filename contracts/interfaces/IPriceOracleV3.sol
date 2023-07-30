// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IPriceOracleBase} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracleBase.sol";

struct PriceFeedConfig {
    address token;
    address priceFeed;
    uint32 stalenessPeriod;
}

struct PriceFeedParams {
    address priceFeed;
    uint32 stalenessPeriod;
    bool skipCheck;
}

struct TokenParams {
    PriceFeedParams mainFeedParams;
    uint8 decimals;
    bool useReserve;
}

interface IPriceOracleV3Events {
    /// @notice Emitted when new price feed is set for token
    event SetPriceFeed(address indexed token, address indexed priceFeed);

    /// @notice Emitted when new reserve price feed is set for token
    event SetReservePriceFeed(address indexed token, address indexed priceFeed);

    /// @notice Emitted when new reserve price feed status is set for a token
    event SetReservePriceFeedStatus(address indexed token, bool active);
}

/// @title Price oracle V3 interface
interface IPriceOracleV3 is IPriceOracleBase, IPriceOracleV3Events {
    function DEFAULT_STALENESS_PERIOD() external view returns (uint32);

    function priceFeedParams(address token)
        external
        view
        returns (address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals);

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function setPriceFeeds(PriceFeedConfig[] calldata feeds) external;

    function setReservePriceFeeds(PriceFeedConfig[] calldata feeds) external;

    function setReservePriceFeedStatus(address token, bool active) external;

    function forceReservePriceFeedStatus(address token, bool active) external;
}
