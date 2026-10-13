// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2026.
pragma solidity ^0.8.17;

/// @title Minimal Aave V4 hub surface used by GearboxPoolSpoke
/// @dev Signatures match `aave-v4` `IHubBase` / `IHub` for the calls this spoke makes.
interface IHubBase {
    struct PremiumDelta {
        int256 sharesDelta;
        int256 offsetRayDelta;
        uint256 restoredPremiumRay;
    }

    function getAssetId(address token) external view returns (uint256);

    function draw(uint256 assetId, uint256 amount, address to) external returns (uint256);

    function restore(uint256 assetId, uint256 drawnAmount, PremiumDelta calldata premiumDelta) external returns (uint256);

    function reportDeficit(uint256 assetId, uint256 drawnAmount, PremiumDelta calldata premiumDelta)
        external
        returns (uint256, uint256);

    function refreshPremium(uint256 assetId, PremiumDelta calldata premiumDelta) external;

    function add(uint256 assetId, uint256 amount) external returns (uint256);

    function remove(uint256 assetId, uint256 amount, address to) external returns (uint256);

    function eliminateDeficit(uint256 assetId, uint256 amount, address spoke) external returns (uint256, uint256);

    function getAssetDrawnIndex(uint256 assetId) external view returns (uint256);

    function getSpokePremiumData(uint256 assetId, address spoke) external view returns (uint256, int256);

    function getSpokeAddedShares(uint256 assetId, address spoke) external view returns (uint256);

    function previewRemoveByShares(uint256 assetId, uint256 shares) external view returns (uint256);
}
