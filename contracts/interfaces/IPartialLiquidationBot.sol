// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

/// @notice Struct with data on a price feed update
/// @param token Token to update the price feed for
/// @param reserve Whether to update the reserve price feed
/// @param data Data payload for update
struct PriceUpdate {
    address token;
    bool reserve;
    bytes data;
}

/// @dev Struct with params for a partial liquidation. This is used unternally by the partial liquidation bot
struct LiquidationParams {
    address creditManager;
    address creditAccount;
    address creditFacade;
    address priceOracle;
    address underlying;
    address assetOut;
    uint256 amountIn;
    uint256 amountOut;
    uint256 totalDebt;
    address to;
    bool exactIn;
    bool repay;
}

interface IPartialLiquidationBot {
    function partialLiquidateExactIn(
        address creditManager,
        address creditAccount,
        address assetOut,
        uint256 amountIn,
        address to,
        bool repay,
        PriceUpdate[] memory priceUpdates
    ) external returns (uint256, uint256);

    function partialLiquidateExactOut(
        address creditManager,
        address creditAccount,
        address assetOut,
        uint256 amountOut,
        address to,
        bool repay,
        PriceUpdate[] memory priceUpdates
    ) external returns (uint256, uint256);
}
