// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IACLTrait} from "./base/IACLTrait.sol";
import {IVersion} from "./base/IVersion.sol";

/// @notice Price feed params
/// @param priceFeed Price feed address
/// @param stalenessPeriod Period (in seconds) after which price feed's answer should be considered stale
/// @param skipCheck Whether price feed implements its own safety and staleness checks
/// @param tokenDecimals Token decimals
struct PriceFeedParams {
    address priceFeed;
    uint32 stalenessPeriod;
    bool skipCheck;
    uint8 tokenDecimals;
}

interface IPriceOracleV3Events {
    /// @notice Emitted when new price feed is set for token
    event SetPriceFeed(address indexed token, address indexed priceFeed, uint32 stalenessPeriod, bool skipCheck);

    /// @notice Emitted when new reserve price feed is set for token
    event SetReservePriceFeed(address indexed token, address indexed priceFeed, uint32 stalenessPeriod, bool skipCheck);
}

/// @title Price oracle V3 interface
interface IPriceOracleV3 is IVersion, IACLTrait, IPriceOracleV3Events {
    function getTokens() external view returns (address[] memory);

    function priceFeeds(address token) external view returns (address priceFeed);

    function reservePriceFeeds(address token) external view returns (address);

    function priceFeedParams(address token) external view returns (PriceFeedParams memory);

    function reservePriceFeedParams(address token) external view returns (PriceFeedParams memory);

    // ---------- //
    // CONVERSION //
    // ---------- //

    function getPrice(address token) external view returns (uint256);

    function getSafePrice(address token) external view returns (uint256);

    function getReservePrice(address token) external view returns (uint256);

    function convertToUSD(uint256 amount, address token) external view returns (uint256);

    function convertFromUSD(uint256 amount, address token) external view returns (uint256);

    function convert(uint256 amount, address tokenFrom, address tokenTo) external view returns (uint256);

    function safeConvertToUSD(uint256 amount, address token) external view returns (uint256);

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function setPriceFeed(address token, address priceFeed, uint32 stalenessPeriod) external;

    function setReservePriceFeed(address token, address priceFeed, uint32 stalenessPeriod) external;
}
