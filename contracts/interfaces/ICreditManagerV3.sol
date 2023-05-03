// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import {IPoolQuotaKeeper, QuotaUpdate} from "./IPoolQuotaKeeper.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";
import {CancellationType} from "./IWithdrawManager.sol";

enum ClosureAction {
    CLOSE_ACCOUNT,
    LIQUIDATE_ACCOUNT,
    LIQUIDATE_EXPIRED_ACCOUNT
}

enum ManageDebtAction {
    INCREASE_DEBT,
    DECREASE_DEBT
}

uint8 constant WITHDRAWAL_FLAG = 1;

struct CreditAccountInfo {
    uint256 debt;
    uint256 cumulativeIndexAtOpen;
    uint256 cumulativeQuotaInterest;
    uint8 flags;
    uint248 enabledTokensMask;
    address borrower;
}

struct CollateralTokenData {
    address token;
    uint16 ltInitial;
    uint16 ltFinal;
    uint40 timestampRampStart;
    uint24 rampDuration;
}

struct RevocationPair {
    address spender;
    address token;
}

interface ICreditManagerV3Events {
    /// @dev Emits when a call to an external contract is made through the Credit Manager
    event ExecuteOrder(address indexed targetContract);

    /// @dev Emits when a configurator is upgraded
    event SetCreditConfigurator(address indexed newConfigurator);
}

/// @notice All Credit Manager functions are access-restricted and can only be called
///         by the Credit Facade or allowed adapters. Users are not allowed to
///         interact with the Credit Manager directly
interface ICreditManagerV3 is ICreditManagerV3Events, IVersion {
    //
    // CREDIT ACCOUNT MANAGEMENT
    //

    ///  @dev Opens credit account and borrows funds from the pool.
    /// @param debt Amount to be borrowed by the Credit Account
    /// @param onBehalfOf The owner of the newly opened Credit Account
    function openCreditAccount(uint256 debt, address onBehalfOf) external returns (address);

    ///  @dev Closes a Credit Account - covers both normal closure and liquidation
    /// - Checks whether the contract is paused, and, if so, if the payer is an emergency liquidator.
    ///   Only emergency liquidators are able to liquidate account while the CM is paused.
    ///   Emergency liquidations do not pay a liquidator premium or liquidation fees.
    /// - Calculates payments to various recipients on closure:
    ///    + Computes amountToPool, which is the amount to be sent back to the pool.
    ///      This includes the principal, interest and fees, but can't be more than
    ///      total position value
    ///    + Computes remainingFunds during liquidations - these are leftover funds
    ///      after paying the pool and the liquidator, and are sent to the borrower
    ///    + Computes protocol profit, which includes interest and liquidation fees
    ///    + Computes loss if the totalValue is less than borrow amount + interest
    /// - Checks the underlying token balance:
    ///    + if it is larger than amountToPool, then the pool is paid fully from funds on the Credit Account
    ///    + else tries to transfer the shortfall from the payer - either the borrower during closure, or liquidator during liquidation
    /// - Send assets to the "to" address, as long as they are not included into skipTokenMask
    /// - If convertWETH is true, the function converts WETH into ETH before sending
    /// - Returns the Credit Account back to factory
    ///
    /// @param creditAccount Credit account address
    /// @param closureAction Whether the account is closed, liquidated or liquidated due to expiry
    /// @param totalValue Portfolio value for liqution, 0 for ordinary closure
    /// @param payer Address which would be charged if credit account has not enough funds to cover amountToPool
    /// @param to Address to which the leftover funds will be sent
    /// @param skipTokenMask Tokenmask contains 1 for tokens which needed to be skipped for sending
    /// @param convertWETH If true converts WETH to ETH
    function closeCreditAccount(
        address creditAccount,
        ClosureAction closureAction,
        uint256 totalValue,
        address payer,
        address to,
        uint256 enabledTokenMask,
        uint256 skipTokenMask,
        uint256 debtWithInterest,
        bool convertWETH
    ) external returns (uint256 remainingFunds, uint256 loss);

    /// @dev Manages debt size for borrower:
    ///
    /// - Increase debt:
    ///   + Increases debt by transferring funds from the pool to the credit account
    ///   + Updates the cumulative index to keep interest the same. Since interest
    ///     is always computed dynamically as debt * (cumulativeIndexNew / cumulativeIndexOpen - 1),
    ///     cumulativeIndexOpen needs to be updated, as the borrow amount has changed
    ///
    /// - Decrease debt:
    ///   + Repays debt partially + all interest and fees accrued thus far
    ///   + Updates cunulativeIndex to cumulativeIndex now
    ///
    /// @param creditAccount Address of the Credit Account to change debt for
    /// @param amount Amount to increase / decrease the principal by
    /// @param action Increase/decrease
    /// @return newdebt The new debt principal
    function manageDebt(address creditAccount, uint256 amount, uint256 _enabledTokensMask, ManageDebtAction action)
        external
        returns (uint256 newdebt, uint256 enableTokenMask);

    /// @dev Adds collateral to borrower's credit account
    /// @param payer Address of the account which will be charged to provide additional collateral
    /// @param creditAccount Address of the Credit Account
    /// @param token Collateral token to add
    /// @param amount Amount to add
    function addCollateral(address payer, address creditAccount, address token, uint256 amount)
        external
        returns (uint256);

    /// @dev Transfers Credit Account ownership to another address
    /// @param from Address of previous owner
    /// @param to Address of new owner
    function transferAccountOwnership(address from, address to) external;

    /// @dev Requests the Credit Account to approve a collateral token to another contract.\
    /// @param token Collateral token to approve
    /// @param amount New allowance amount
    function approveCreditAccount(address token, uint256 amount) external;

    /// @dev Requests a Credit Account to make a low-level call with provided data
    /// This is the intended pathway for state-changing interactions with 3rd-party protocols
    /// @param callData Data to pass with the call
    function executeOrder(bytes memory callData) external returns (bytes memory);

    //
    // COLLATERAL VALIDITY AND ACCOUNT HEALTH CHECKS
    //

    /// @dev Performs a full health check on an account with a custom order of evaluated tokens and
    ///      a custom minimal health factor
    /// @param creditAccount Address of the Credit Account to check
    /// @param collateralHints Array of token masks in the desired order of evaluation
    /// @param minHealthFactor Minimal health factor of the account, in PERCENTAGE format
    function fullCollateralCheck(
        address creditAccount,
        uint256 enabledTokenMaskBefore,
        uint256[] memory collateralHints,
        uint16 minHealthFactor
    ) external;

    //
    // QUOTAS MANAGEMENT
    //

    /// @dev Updates credit account's quotas for multiple tokens
    /// @param creditAccount Address of credit account
    /// @param quotaUpdates Requested quota updates, see `QuotaUpdate`
    function updateQuotas(address creditAccount, QuotaUpdate[] memory quotaUpdates)
        external
        returns (uint256 tokensToEnable, uint256 tokensToDisable);

    //
    // GETTERS
    //

    /// @dev Returns the address of a borrower's Credit Account, or reverts if there is none.
    /// @param creditAccount credit account address
    /// @return borrower Borrower's address
    function getBorrowerOrRevert(address creditAccount) external view returns (address borrower);

    /// @dev Computes amounts that must be sent to various addresses before closing an account
    /// @param totalValue Credit Accounts total value in underlying
    /// @param closureActionType Type of account closure
    ///        * CLOSE_ACCOUNT: The account is healthy and is closed normally
    ///        * LIQUIDATE_ACCOUNT: The account is unhealthy and is being liquidated to avoid bad debt
    ///        * LIQUIDATE_EXPIRED_ACCOUNT: The account has expired and is being liquidated (lowered liquidation premium)
    ///        * LIQUIDATE_PAUSED: The account is liquidated while the system is paused due to emergency (no liquidation premium)
    /// @param debt Credit Account's debt principal
    /// @param debtWithInterest Credit Account's debt principal + interest
    /// @return amountToPool Amount of underlying to be sent to the pool
    /// @return remainingFunds Amount of underlying to be sent to the borrower (only applicable to liquidations)
    /// @return profit Protocol's profit from fees (if any)
    /// @return loss Protocol's loss from bad debt (if any)
    function calcClosePayments(
        uint256 totalValue,
        ClosureAction closureActionType,
        uint256 debt,
        uint256 debtWithInterest
    ) external view returns (uint256 amountToPool, uint256 remainingFunds, uint256 profit, uint256 loss);

    /// @dev Calculates the debt accrued by a Credit Account
    /// @param creditAccount Address of the Credit Account
    /// @return debt The debt principal
    /// @return debtWithInterest The debt principal + accrued interest
    /// @return debtWithInterestAndFees The debt principal + accrued interest and protocol fees
    function calcCreditAccountAccruedInterest(address creditAccount)
        external
        view
        returns (uint256 debt, uint256 debtWithInterest, uint256 debtWithInterestAndFees);

    /// @dev Maps Credit Accounts to bit masks encoding their enabled token sets
    /// Only enabled tokens are counted as collateral for the Credit Account
    /// @notice An enabled token mask encodes an enabled token by setting
    ///         the bit at the position equal to token's index to 1
    function enabledTokensMap(address creditAccount) external view returns (uint256);

    /// @dev Returns the collateral token at requested index and its liquidation threshold
    /// @param id The index of token to return
    function collateralTokens(uint256 id) external view returns (address token, uint16 liquidationThreshold);

    /// @dev Returns the collateral token with requested mask and its liquidationThreshold
    /// @param tokenMask Token mask corresponding to the token
    function collateralTokensByMask(uint256 tokenMask)
        external
        view
        returns (address token, uint16 liquidationThreshold);

    /// @dev Returns the array of quoted tokens that are enabled on the account
    function getQuotedTokens(address creditAccount) external view returns (address[] memory tokens);

    /// @dev Total number of known collateral tokens.
    function collateralTokensCount() external view returns (uint8);

    /// @dev Returns the mask for the provided token
    /// @param token Token to returns the mask for
    function getTokenMaskOrRevert(address token) external view returns (uint256);

    /// @dev Mask of tokens to apply quotas for
    function quotedTokenMask() external view returns (uint256);

    /// @dev Maps allowed adapters to their respective target contracts.
    function adapterToContract(address adapter) external view returns (address);

    /// @dev Maps 3rd party contracts to their respective adapters
    function contractToAdapter(address targetContract) external view returns (address);

    /// @dev Address of the underlying asset
    function underlying() external view returns (address);

    /// @dev Address of the connected pool
    function pool() external view returns (address);

    /// @dev Address of the connected pool
    /// @notice [DEPRECATED]: use pool() instead.
    function poolService() external view returns (address);

    /// @dev Returns the current pool quota keeper connected to the pool
    function poolQuotaKeeper() external view returns (IPoolQuotaKeeper);

    /// @dev Whether the Credit Manager supports quotas
    function supportsQuotas() external view returns (bool);

    /// @dev Address of the connected Credit Configurator
    function creditConfigurator() external view returns (address);

    /// @dev Address of WETH
    function wethAddress() external view returns (address);

    /// @dev Address of WETHGateway
    function wethGateway() external view returns (address);

    /// @dev Returns the liquidation threshold for the provided token
    /// @param token Token to retrieve the LT for
    function liquidationThresholds(address token) external view returns (uint16);

    /// @dev The maximal number of enabled tokens on a single Credit Account
    function maxAllowedEnabledTokenLength() external view returns (uint8);

    /// @dev Returns the fee parameters of the Credit Manager
    /// @return feeInterest Percentage of interest taken by the protocol as profit
    /// @return feeLiquidation Percentage of account value taken by the protocol as profit
    ///         during unhealthy account liquidations
    /// @return liquidationDiscount Multiplier that reduces the effective totalValue during unhealthy account liquidations,
    ///         allowing the liquidator to take the unaccounted for remainder as premium. Equal to (1 - liquidationPremium)
    /// @return feeLiquidationExpired Percentage of account value taken by the protocol as profit
    ///         during expired account liquidations
    /// @return liquidationDiscountExpired Multiplier that reduces the effective totalValue during expired account liquidations,
    ///         allowing the liquidator to take the unaccounted for remainder as premium. Equal to (1 - liquidationPremiumExpired)
    function fees()
        external
        view
        returns (
            uint16 feeInterest,
            uint16 feeLiquidation,
            uint16 liquidationDiscount,
            uint16 feeLiquidationExpired,
            uint16 liquidationDiscountExpired
        );

    /// @dev Address of the connected Credit Facade
    function creditFacade() external view returns (address);

    /// @dev Address of the connected Price Oracle
    function priceOracle() external view returns (IPriceOracleV2);

    function calcTotalValue(address creditAccount)
        external
        view
        returns (uint256 enabledTokenMask, uint256 total, uint256 twv, uint256 debtWithInterest, bool canBeLiquidated);

    function withdraw(address creditAccount, address borrower, address token, uint256 amount)
        external
        returns (uint256 tokensToDisable);

    function cancelWithdrawals(address creditAccount, CancellationType ctype)
        external
        returns (uint256 tokensToEnable);

    /// @notice Revokes allowances for specified spender/token pairs
    /// @param revocations Spender/token pairs to revoke allowances for
    function revokeAdapterAllowances(address creditAccount, RevocationPair[] calldata revocations) external;

    function disableWithdrawalFlag(address creditAccount) external;

    function setCaForExternalCall(address creditAccount) external;

    function externalCallCreditAccountOrRevert() external view returns (address creditAccount);

    function getTokenByMask(uint256 tokenMask) external view returns (address token);
}
