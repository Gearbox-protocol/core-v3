// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";
import {ClosureAction} from "../interfaces/ICreditManagerV3.sol";
import "./ICreditFacadeV3Multicall.sol";

struct DebtLimits {
    /// @dev Minimal borrowed amount per credit account
    uint128 minDebt;
    /// @dev Maximum aborrowed amount per credit account
    uint128 maxDebt;
}

struct CumulativeLossParams {
    /// @dev Current cumulative loss from all bad debt liquidations
    uint128 currentCumulativeLoss;
    /// @dev Max cumulative loss accrued before the system is paused
    uint128 maxCumulativeLoss;
}

struct FullCheckParams {
    uint256[] collateralHints;
    uint16 minHealthFactor;
    uint256 enabledTokensMaskAfter;
    address priceOracle;
}

struct TotalDebt {
    /// @dev Current total borrowing
    uint128 currentTotalDebt;
    /// @dev Total borrowing limit
    uint128 totalDebtLimit;
}

interface ICreditFacadeV3Events {
    /// @dev Emits when a new Credit Account is opened through the Credit Facade
    event OpenCreditAccount(
        address indexed creditAccount,
        address indexed onBehalfOf,
        address indexed caller,
        uint256 debt,
        uint16 referralCode
    );

    /// @dev Emits when the account owner closes their CA normally
    event CloseCreditAccount(address indexed creditAccount, address indexed borrower, address indexed to);

    /// @dev Emits when a Credit Account is liquidated due to low health factor
    event LiquidateCreditAccount(
        address indexed creditAccount,
        address indexed borrower,
        address indexed liquidator,
        address to,
        ClosureAction closureAction,
        uint256 remainingFunds
    );

    /// @dev Emits when the account owner increases CA's debt
    event IncreaseDebt(address indexed creditAccount, uint256 amount);

    /// @dev Emits when the account owner reduces CA's debt
    event DecreaseDebt(address indexed creditAccount, uint256 amount);

    /// @dev Emits when the account owner add new collateral to a CA
    event AddCollateral(address indexed creditAccount, address indexed token, uint256 value);

    /// @dev Emits when a multicall is started
    event StartMultiCall(address indexed creditAccount, address indexed caller);

    /// @dev Emits when a call to an external contract is made through the Credit Manager
    event Execute(address indexed creditAccount, address indexed targetContract);

    /// @dev Emits when a multicall is finished
    event FinishMultiCall();

    /// @dev Emits when enabledTokensMask is updated
    event SetEnabledTokensMask(address indexed creditAccount, uint256 enabledTokensMask);
}

interface ICreditFacadeV3 is ICreditFacadeV3Events, IVersion {
    //
    // CREDIT ACCOUNT MANAGEMENT
    //

    /// @dev Opens a Credit Account and runs a batch of operations in a multicall
    /// @param debt Debt size
    /// @param onBehalfOf The address to open an account for
    /// @param calls The array of MultiCall structs encoding the required operations. Generally must have
    /// at least a call to addCollateral, as otherwise the health check at the end will fail.
    /// @param referralCode Referral code which is used for potential rewards. 0 if no referral code provided
    function openCreditAccount(uint256 debt, address onBehalfOf, MultiCall[] calldata calls, uint16 referralCode)
        external
        payable
        returns (address creditAccount);

    /// @dev Runs a batch of transactions within a multicall and closes the account
    /// - Wraps ETH to WETH and sends it msg.sender if value > 0
    /// - Executes the multicall - the main purpose of a multicall when closing is to convert all assets to underlying
    /// in order to pay the debt.
    /// - Closes credit account:
    ///    + Checks the underlying balance: if it is greater than the amount paid to the pool, transfers the underlying
    ///      from the Credit Account and proceeds. If not, tries to transfer the shortfall from msg.sender.
    ///    + Transfers all enabled assets with non-zero balances to the "to" address, unless they are marked
    ///      to be skipped in skipTokenMask
    ///    + If convertToETH is true, converts WETH into ETH before sending to the recipient
    /// - Emits a CloseCreditAccount event
    ///
    /// @param to Address to send funds to during account closing
    /// @param skipTokenMask Uint-encoded bit mask where 1's mark tokens that shouldn't be transferred
    /// @param convertToETH If true, converts WETH into ETH before sending to "to"
    /// @param calls The array of MultiCall structs encoding the operations to execute before closing the account.
    function closeCreditAccount(
        address creditAccount,
        address to,
        uint256 skipTokenMask,
        bool convertToETH,
        MultiCall[] calldata calls
    ) external payable;

    /// @dev Runs a batch of transactions within a multicall and liquidates the account
    /// - Computes the total value and checks that hf < 1. An account can't be liquidated when hf >= 1.
    ///   Total value has to be computed before the multicall, otherwise the liquidator would be able
    ///   to manipulate it.
    /// - Wraps ETH to WETH and sends it to msg.sender (liquidator) if value > 0
    /// - Executes the multicall - the main purpose of a multicall when liquidating is to convert all assets to underlying
    ///   in order to pay the debt.
    /// - Liquidate credit account:
    ///    + Computes the amount that needs to be paid to the pool. If totalValue * liquidationDiscount < borrow + interest + fees,
    ///      only totalValue * liquidationDiscount has to be paid. Since liquidationDiscount < 1, the liquidator can take
    ///      totalValue * (1 - liquidationDiscount) as premium. Also computes the remaining funds to be sent to borrower
    ///      as totalValue * liquidationDiscount - amountToPool.
    ///    + Checks the underlying balance: if it is greater than amountToPool + remainingFunds, transfers the underlying
    ///      from the Credit Account and proceeds. If not, tries to transfer the shortfall from the liquidator.
    ///    + Transfers all enabled assets with non-zero balances to the "to" address, unless they are marked
    ///      to be skipped in skipTokenMask. If the liquidator is confident that all assets were converted
    ///      during the multicall, they can set the mask to uint256.max - 1, to only transfer the underlying
    ///    + If convertToETH is true, converts WETH into ETH before sending
    /// - Emits LiquidateCreditAccount event
    ///
    /// @param to Address to send funds to after liquidation
    /// @param skipTokenMask Uint-encoded bit mask where 1's mark tokens that shouldn't be transferred
    /// @param convertToETH If true, converts WETH into ETH before sending to "to"
    /// @param calls The array of MultiCall structs encoding the operations to execute before liquidating the account.
    function liquidateCreditAccount(
        address creditAccount,
        address to,
        uint256 skipTokenMask,
        bool convertToETH,
        MultiCall[] calldata calls
    ) external;

    /// @dev Executes a batch of transactions within a Multicall, to manage an existing account
    ///  - Wraps ETH and sends it back to msg.sender, if value > 0
    ///  - Executes the Multicall
    ///  - Performs a fullCollateralCheck to verify that hf > 1 after all actions
    /// @param calls The array of MultiCall structs encoding the operations to execute.
    function multicall(address creditAccount, MultiCall[] calldata calls) external payable;

    /// @dev Executes a batch of transactions within a Multicall from bot on behalf of a borrower
    ///  - Wraps ETH and sends it back to msg.sender, if value > 0
    ///  - Executes the Multicall
    ///  - Performs a fullCollateralCheck to verify that hf > 1 after all actions
    /// @param borrower Borrower the perform the multicall for
    /// @param calls The array of MultiCall structs encoding the operations to execute.
    function botMulticall(address borrower, MultiCall[] calldata calls) external;

    // /// @dev Enables token in enabledTokensMask for the Credit Account of msg.sender
    // /// @param token Address of token to enable
    // function enableToken(address token) external;

    function claimWithdrawals(address creditAccount, address to) external;

    /// @dev Sets permissions and funding parameters for a bot
    /// @param creditAccount CA to set permissions for
    /// @param bot Bot to set permissions for
    /// @param permissions A bit mask of permissions
    /// @param fundingAmount Total amount of ETH available to the bot for payments
    /// @param weeklyFundingAllowance Amount of ETH available to the bot weekly
    function setBotPermissions(
        address creditAccount,
        address bot,
        uint192 permissions,
        uint72 fundingAmount,
        uint72 weeklyFundingAllowance
    ) external;

    //
    // GETTERS
    //

    /// @dev Bit mask encoding a set of forbidden tokens
    function forbiddenTokenMask() external view returns (uint256);

    /// @dev Returns the CreditManagerV3 connected to this Credit Facade
    function creditManager() external view returns (address);

    /// @return minDebt Minimal borrowed amount per credit account
    function debtLimits() external view returns (uint128 minDebt, uint128 maxDebt);

    /// @return currentTotalDebt The current total debt of Credit Manager (if tracked in Credit Facade)
    /// @return totalDebtLimit The current total debt limit of Credit Manager
    function totalDebt() external view returns (uint128 currentTotalDebt, uint128 totalDebtLimit);

    function maxDebtPerBlockMultiplier() external view returns (uint8);

    /// @return currentCumulativeLoss The total amount of loss accumulated since last reset
    /// @return maxCumulativeLoss The maximal amount of loss accumulated before the Credit Manager is paused
    function lossParams() external view returns (uint128 currentCumulativeLoss, uint128 maxCumulativeLoss);

    /// @dev Address of the IDegenNFTV2 that gatekeeps account openings in whitelisted mode
    function degenNFT() external view returns (address);

    /// @dev Maps addresses to their status as emergency liquidator.
    /// @notice Emergency liquidators are trusted addresses
    /// that are able to liquidate positions while the contracts are paused,
    /// e.g. when there is a risk of bad debt while an exploit is being patched.
    /// In the interest of fairness, emergency liquidators do not receive a premium
    /// And are compensated by the Gearbox DAO separately.
    function canLiquidateWhilePaused(address) external view returns (bool);

    /// @dev Timestamp at which accounts on an expirable CM will be liquidated
    function expirationDate() external view returns (uint40);

    /// @dev Returns whether the Credit Facade tracks the total debt on its own
    function trackTotalDebt() external view returns (bool);
}
