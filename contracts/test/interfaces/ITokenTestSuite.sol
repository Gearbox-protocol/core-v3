// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

interface ITokenTestSuite {
    function wethToken() external view returns (address);

    function approve(address token, address holder, address targetContract) external;

    function approve(address token, address holder, address targetContract, uint256 amount) external;

    // function approve(
    //     Tokens t,
    //     address holder,
    //     address targetContract
    // ) external;

    // function approve(
    //     Tokens t,
    //     address holder,
    //     address targetContract,
    //     uint256 amount
    // ) external;

    function topUpWETH() external payable;

    function topUpWETH(address onBehalfOf, uint256 value) external;

    function balanceOf(address token, address holder) external view returns (uint256 balance);

    function mint(address token, address to, uint256 amount) external;

    function burn(address token, address from, uint256 amount) external;

    // function mint(
    //     Tokens t,
    //     address to,
    //     uint256 amount
    // ) external;
}
