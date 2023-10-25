// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Balance} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";
import {RevocationPair} from "./ICreditManagerV3.sol";

// ----------- //
// PERMISSIONS //
// ----------- //

uint192 constant ADD_COLLATERAL_PERMISSION = 1;
uint192 constant INCREASE_DEBT_PERMISSION = 1 << 1;
uint192 constant DECREASE_DEBT_PERMISSION = 1 << 2;
uint192 constant ENABLE_TOKEN_PERMISSION = 1 << 3;
uint192 constant DISABLE_TOKEN_PERMISSION = 1 << 4;
uint192 constant WITHDRAW_PERMISSION = 1 << 5;
uint192 constant UPDATE_QUOTA_PERMISSION = 1 << 6;
uint192 constant REVOKE_ALLOWANCES_PERMISSION = 1 << 7;

uint192 constant EXTERNAL_CALLS_PERMISSION = 1 << 16;

uint256 constant ALL_CREDIT_FACADE_CALLS_PERMISSION = ADD_COLLATERAL_PERMISSION | INCREASE_DEBT_PERMISSION
    | DECREASE_DEBT_PERMISSION | ENABLE_TOKEN_PERMISSION | DISABLE_TOKEN_PERMISSION | WITHDRAW_PERMISSION
    | UPDATE_QUOTA_PERMISSION | REVOKE_ALLOWANCES_PERMISSION;

uint256 constant ALL_PERMISSIONS = ALL_CREDIT_FACADE_CALLS_PERMISSION | EXTERNAL_CALLS_PERMISSION;

// ----- //
// FLAGS //
// ----- //

/// @dev Indicates that there are enabled forbidden tokens on the account before multicall
uint256 constant FORBIDDEN_TOKENS_BEFORE_CALLS = 1 << 192;

/// @dev Indicates that there must be no enabled forbidden tokens on the account after multicall,
///      set to true when `increaseDebt` or `scheduleWithdrawal` is called
uint256 constant REVERT_ON_FORBIDDEN_TOKENS_AFTER_CALLS = 1 << 193;

/// @dev Indicates that external calls from credit account to adapters were made during multicall,
///      set to true on the first call to the adapter
uint256 constant EXTERNAL_CONTRACT_WAS_CALLED = 1 << 194;

/// @dev Indicates that `payBot` can be called during multicall to fund the bot, set to true when
///      multicall is initiated in `botMulticall` and reset after the first `payBot` call
uint256 constant PAY_BOT_CAN_BE_CALLED = 1 << 195;

/// @title Credit facade V3 multicall interface
/// @dev Unless specified otherwise, all these methods are only available in `openCreditAccount`,
///      `closeCreditAccount`, `multicall`, and, with account owner's permission, `botMulticall`
interface ICreditFacadeV3Multicall {
    /// @notice Updates the price for a token with on-demand updatable price feed
    /// @param token Token to push the price update for
    /// @param data Data to call `updatePrice` with
    /// @dev Calls of this type must be placed before all other calls in the multicall not to revert
    /// @dev This method is available in all kinds of multicalls
    function onDemandPriceUpdate(address token, bytes calldata data) external;

    /// @notice Ensures that token balances increase at least by specified deltas after the following calls
    /// @param balanceDeltas Array of (token, minBalanceDelta) pairs
    /// @dev The method can only be called once during the multicall, typically before all balance-changing calls
    /// @dev This method is available in all kinds of multicalls
    function revertIfReceivedLessThan(Balance[] calldata balanceDeltas) external;

    /// @notice Adds collateral to account
    /// @param token Token to add
    /// @param amount Amount to add
    /// @dev Requires token approval from caller to the credit manager
    /// @dev This method can also be called during liquidation
    function addCollateral(address token, uint256 amount) external;

    /// @notice Adds collateral to account using signed EIP-2612 permit message
    /// @param token Token to add
    /// @param amount Amount to add
    /// @param deadline Permit deadline
    /// @dev `v`, `r`, `s` must be a valid signature of the permit message from caller to the credit manager
    /// @dev This method can also be called during liquidation
    function addCollateralWithPermit(address token, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;

    /// @notice Increases account's debt
    /// @param amount Underlying amount to borrow
    /// @dev Increasing debt is prohibited when closing an account
    /// @dev Increasing debt is prohibited if it was previously updated in the same block
    /// @dev The resulting debt amount must be within allowed range
    /// @dev Increasing debt is prohibited if there are forbidden tokens enabled as collateral on the account
    /// @dev After debt increase, total amount borrowed by the credit manager in the current block must not exceed
    ///      the limit defined in the facade
    function increaseDebt(uint256 amount) external;

    /// @notice Decreases account's debt
    /// @param amount Underlying amount to repay, value above account's total debt indicates full repayment
    /// @dev Decreasing debt is prohibited when opening an account
    /// @dev Decreasing debt is prohibited if it was previously updated in the same block
    /// @dev The resulting debt amount must be within allowed range or zero
    /// @dev Full repayment brings account into a special mode that skips collateral checks and thus requires
    ///      an account to have no potential debt sources, e.g., all quotas must be disabled
    function decreaseDebt(uint256 amount) external;

    /// @notice Updates account's quota for a token
    /// @param token Token to update the quota for
    /// @param quotaChange Desired quota change in underlying token units
    /// @param minQuota Minimum resulting account's quota for token required not to revert
    /// @dev Enables token as collateral if quota is increased from zero, disables if decreased to zero
    /// @dev Quota increase is prohibited if there are forbidden tokens enabled as collateral on the account
    /// @dev Quota increase is prohibited if account has zero debt
    /// @dev Resulting account's quota for token must not exceed the limit defined in the facade
    function updateQuota(address token, int96 quotaChange, uint96 minQuota) external;

    /// @notice Schedules a delayed withdrawal from account
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw
    /// @dev Withdrawals are prohibited if there are forbidden tokens enabled as collateral on the account
    /// @dev Withdrawals are prohibited when opening or closing an account
    function scheduleWithdrawal(address token, uint256 amount) external;

    /// @notice Requests bot list to make a payment to the caller
    /// @param paymentAmount Paymenet amount in WETH
    /// @dev This method is only available in `botMulticall` and can only be called once
    function payBot(uint72 paymentAmount) external;

    /// @notice Sets advanced collateral check parameters
    /// @param collateralHints Optional array of token masks to check first to reduce the amount of computation
    ///        when known subset of account's collateral tokens covers all the debt
    /// @param minHealthFactor Min account's health factor in bps in order not to revert, must be at least 10000 (default)
    function setFullCheckParams(uint256[] calldata collateralHints, uint16 minHealthFactor) external;

    /// @notice Enables token as account's collateral, which makes it count towards account's total value
    /// @param token Token to enable as collateral
    /// @dev Enabling forbidden tokens is prohibited
    /// @dev Quoted tokens can only be enabled via `updateQuota`, this method is no-op for them
    function enableToken(address token) external;

    /// @notice Disables token as account's collateral
    /// @param token Token to disable as collateral
    /// @dev Quoted tokens can only be disabled via `updateQuota`, this method is no-op for them
    function disableToken(address token) external;

    /// @notice Revokes account's allowances for specified spender/token pairs
    /// @param revocations Array of spender/token pairs
    /// @dev Exists primarily to allow users to revoke allowances on accounts from old account factory on mainnet
    function revokeAdapterAllowances(RevocationPair[] calldata revocations) external;
}
