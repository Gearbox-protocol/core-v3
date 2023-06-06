// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

interface IERC4626Events {
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
}
