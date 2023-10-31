// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IPriceOracleBase} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracleBase.sol";

struct PriceFeedParams {
    address priceFeed;
    uint32 stalenessPeriod;
    bool skipCheck;
    uint8 decimals;
    bool useReserve;
    // these parameters used in double check
    bool trustedPriceFeed;
}

interface IPriceOracleV3Events {
    /// @notice Emitted when new price feed is set for token
    event SetPriceFeed(address indexed token, address indexed priceFeed, uint32 stalenessPeriod, bool skipCheck);

    /// @notice Emitted when new reserve price feed is set for token
    event SetReservePriceFeed(address indexed token, address indexed priceFeed, uint32 stalenessPeriod, bool skipCheck);

    /// @notice Emitted when new reserve price feed status is set for a token
    event SetReservePriceFeedStatus(address indexed token, bool active);
}

/// @title Price oracle V3 interface
interface IPriceOracleV3 is IPriceOracleBase, IPriceOracleV3Events {
    function getPriceRaw(address token, bool reserve) external view returns (uint256);

    function priceFeedsRaw(address token, bool reserve) external view returns (address);

    function priceFeedParams(address token)
        external
        view
        returns (address priceFeed, uint32 stalenessPeriod, bool skipCheck, uint8 decimals, bool trustedPriceFeed);

    // Reserve check\

    function convertToUSDReserveCheck(uint256 amount, address token) external view returns (uint256);

    /// @notice Converts `amount` of USD (with 8 decimals) into `token` amount as minimum of main and reserve price feeds
    function convertFromUSDReserveCheck(uint256 amount, address token) external view returns (uint256);

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function setPriceFeed(address token, address priceFeed, uint32 stalenessPeriod, bool trustedPriceFeed) external;

    function setReservePriceFeed(address token, address priceFeed, uint32 stalenessPeriod) external;

    function setReservePriceFeedStatus(address token, bool active) external;
}
