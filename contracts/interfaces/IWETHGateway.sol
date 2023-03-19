// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

interface IWETHGateway {
    /// @dev POOL V3:
    function deposit(address pool, address receiver) external payable returns (uint256 shares);

    function depositReferral(address pool, address receiver, uint16 referralCode)
        external
        payable
        returns (uint256 shares);

    function mint(address pool, uint256 shares, address receiver) external payable returns (uint256 assets);

    function withdraw(address pool, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    function redeem(address pool, uint256 shares, address receiver, address owner)
        external
        payable
        returns (uint256 assets);

    function depositFor(address to, uint256 amount) external;

    function withdrawTo(address owner) external;

    function balanceOf(address holder) external view returns (uint256);
}
