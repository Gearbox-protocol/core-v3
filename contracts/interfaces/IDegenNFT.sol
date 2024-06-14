// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

interface IDegenNFT {
    function burn(address from, uint256 amount) external;

    function mint(address to, uint256 amount) external;

    function minter() external view returns (address);
}
