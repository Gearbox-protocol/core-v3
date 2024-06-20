// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

uint256 constant WAD = 1e18;
uint256 constant RAY = 1e27;
uint16 constant PERCENTAGE_FACTOR = 1e4;
uint256 constant WAD_OVER_PERCENTAGE = WAD / PERCENTAGE_FACTOR;
uint256 constant RAY_OVER_PERCENTAGE = RAY / PERCENTAGE_FACTOR;

uint256 constant SECONDS_PER_YEAR = 365 days;
uint256 constant EPOCH_LENGTH = 7 days;
uint256 constant EPOCHS_TO_WITHDRAW = 4;

uint8 constant MAX_WITHDRAW_FEE = 100;

uint16 constant DEFAULT_FEE_LIQUIDATION = 1_50;
uint16 constant DEFAULT_LIQUIDATION_PREMIUM = 4_00;
uint16 constant DEFAULT_FEE_LIQUIDATION_EXPIRED = 1_00;
uint16 constant DEFAULT_LIQUIDATION_PREMIUM_EXPIRED = 2_00;
uint8 constant DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER = 2;

uint8 constant BOT_PERMISSIONS_SET_FLAG = 1;

uint256 constant UNDERLYING_TOKEN_MASK = 1;

address constant INACTIVE_CREDIT_ACCOUNT_ADDRESS = address(1);
