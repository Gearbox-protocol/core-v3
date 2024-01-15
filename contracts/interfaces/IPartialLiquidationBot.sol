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

/// @notice Struct with params for a partial liquidation
/// @param creditManager Credit Manager where the liquidated CA currently resides
/// @param creditAccount Credit Account to liquidate
/// @param assetOut Asset that the liquidator wishes to receive
/// @param amountOut Amount of the asset the liquidator wants to receive
/// @param maxAmountInUnderlying The maximal amount of underlying that the liquidator will be charged
/// @param repay Whether to repay debt after swapping into underlying
/// @param priceUpdates Data for price feeds to update before liquidation
struct LiquidationParams {
    address creditManager;
    address creditAccount;
    address assetOut;
    uint256 amountOut;
    uint256 maxAmountInUnderlying;
    bool repay;
    PriceUpdate[] priceUpdates;
}

interface IPartialLiquidationBot {
    function liquidatePartialSingleAsset(LiquidationParams memory params) external;

    function getLiquidationWithRepayMaxAmount(
        address creditManager,
        address creditAccount,
        address assetOut,
        PriceUpdate[] memory priceUpdates
    ) external returns (uint256 maxAmountAssetOut, uint256 amountAssetIn);
}
