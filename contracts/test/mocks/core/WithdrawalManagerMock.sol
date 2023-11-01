// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;
pragma abicoder v1;

contract WithdrawalManagerMock {
    uint256 public constant version = 3_00;

    function addImmediateWithdrawal(address token, address to, uint256 amount) external {}

    function claimImmediateWithdrawal(address token, address to) external {}
}
