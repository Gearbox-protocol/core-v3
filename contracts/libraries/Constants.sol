// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

bytes32 constant AP_GEAR_TOKEN = "GEAR_TOKEN";
bytes32 constant AP_INSTANCE_MANAGER_PROXY = "INSTANCE_MANAGER_PROXY";
bytes32 constant AP_CROSS_CHAIN_GOVERNANCE_PROXY = "CROSS_CHAIN_GOVERNANCE_PROXY";
bytes32 constant AP_PRICE_FEED_STORE = "PRICE_FEED_STORE";
uint256 constant NO_VERSION_CONTROL = 0;

uint256 constant WAD = 1e18;
uint256 constant RAY = 1e27;
uint16 constant PERCENTAGE_FACTOR = 1e4;

uint256 constant SECONDS_PER_YEAR = 365 days;
uint256 constant EPOCH_LENGTH = 7 days;
uint256 constant FIRST_EPOCH_TIMESTAMP = 1702900800;
uint256 constant EPOCHS_TO_WITHDRAW = 4;

uint8 constant MAX_SANE_ENABLED_TOKENS = 20;
uint256 constant MAX_SANE_EPOCH_LENGTH = 28 days;

uint8 constant MAX_WITHDRAW_FEE = 100;

uint8 constant DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER = 2;

uint8 constant BOT_PERMISSIONS_SET_FLAG = 1;

uint256 constant UNDERLYING_TOKEN_MASK = 1;

address constant INACTIVE_CREDIT_ACCOUNT_ADDRESS = address(1);
