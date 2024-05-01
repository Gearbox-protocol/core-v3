// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {BalanceDelta} from "../libraries/BalancesLogic.sol";
import {PriceUpdate} from "./IPriceOracleV3.sol";

// ----------- //
// PERMISSIONS //
// ----------- //

uint192 constant ADD_COLLATERAL_PERMISSION = 1 << 0;
uint192 constant WITHDRAW_COLLATERAL_PERMISSION = 1 << 1;
uint192 constant INCREASE_DEBT_PERMISSION = 1 << 2;
uint192 constant DECREASE_DEBT_PERMISSION = 1 << 3;
uint192 constant UPDATE_QUOTA_PERMISSION = 1 << 4;
uint192 constant EXTERNAL_CALLS_PERMISSION = 1 << 5;

uint256 constant ALL_PERMISSIONS = ADD_COLLATERAL_PERMISSION | WITHDRAW_COLLATERAL_PERMISSION | INCREASE_DEBT_PERMISSION
    | DECREASE_DEBT_PERMISSION | UPDATE_QUOTA_PERMISSION | EXTERNAL_CALLS_PERMISSION;

// ----- //
// FLAGS //
// ----- //

/// @dev Indicates that there are enabled forbidden tokens on the account before multicall
uint256 constant FORBIDDEN_TOKENS_BEFORE_CALLS = 1 << 192;

/// @dev Indicates that external calls from credit account to adapters were made during multicall,
///      set to true on the first call to the adapter
uint256 constant EXTERNAL_CONTRACT_WAS_CALLED = 1 << 193;

/// @title Credit facade V3 multicall interface
/// @dev Unless specified otherwise, all these methods are only available in `openCreditAccount`,
///      `closeCreditAccount`, `multicall`, and, with account owner's permission, `botMulticall`
interface ICreditFacadeV3Multicall {
    /// @notice Applies on-demand price feed updates
    /// @param updates Array of price updates, see `PriceUpdate` for details
    /// @dev Reverts if placed not at the first position in the multicall
    /// @dev This method is available in all kinds of multicalls
    function onDemandPriceUpdates(PriceUpdate[] calldata updates) external;

    /// @notice Stores expected token balances (current balance + delta) after operations for a slippage check.
    ///         Normally, a check is performed automatically at the end of the multicall, but more fine-grained
    ///         behavior can be achieved by placing `storeExpectedBalances` and `compareBalances` where needed.
    /// @param balanceDeltas Array of (token, minBalanceDelta) pairs, deltas are allowed to be negative
    /// @dev Reverts if expected balances are already set
    /// @dev This method is available in all kinds of multicalls
    function storeExpectedBalances(BalanceDelta[] calldata balanceDeltas) external;

    /// @notice Performs a slippage check ensuring that current token balances are greater than saved expected ones
    /// @dev Resets stored expected balances
    /// @dev Reverts if expected balances are not stored
    /// @dev This method is available in all kinds of multicalls
    function compareBalances() external;

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
    /// @param quotaChange Desired quota change in underlying token units (`type(int96).min` to disable quota)
    /// @param minQuota Minimum resulting account's quota for token required not to revert
    /// @dev Enables token as collateral if quota is increased from zero, disables if decreased to zero
    /// @dev Quota increase is prohibited if there are forbidden tokens enabled as collateral on the account
    /// @dev Quota update is prohibited if account has zero debt
    /// @dev Resulting account's quota for token must not exceed the limit defined in the facade
    function updateQuota(address token, int96 quotaChange, uint96 minQuota) external;

    /// @notice Withdraws collateral from account
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw, `type(uint256).max` to withdraw all balance
    /// @param to Token recipient
    /// @dev This method can also be called during liquidation
    /// @dev Withdrawals are prohibited in multicalls if there are forbidden tokens enabled as collateral on the account
    /// @dev Withdrawals activate safe pricing (min of main and reserve feeds) in collateral check
    function withdrawCollateral(address token, uint256 amount, address to) external;

    /// @notice Sets advanced collateral check parameters
    /// @param collateralHints Optional array of token masks to check first to reduce the amount of computation
    ///        when known subset of account's collateral tokens covers all the debt. Underlying token is always
    ///        checked last so it's forbidden to pass its mask.
    /// @param minHealthFactor Min account's health factor in bps in order not to revert, must be at least 10000
    /// @dev This method is available in all kinds of multicalls
    function setFullCheckParams(uint256[] calldata collateralHints, uint16 minHealthFactor) external;
}
