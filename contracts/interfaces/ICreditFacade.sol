// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {Balance} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";
import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {ICreditManagerV2} from "./ICreditManagerV2.sol";
import {QuotaUpdate} from "./IPoolQuotaKeeper.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";
import {ClosureAction} from "../interfaces/ICreditManagerV2.sol";

struct FullCheckParams {
    uint256[] collateralHints;
    uint16 minHealthFactor;
    uint256 enabledTokensMaskAfter;
}

interface ICreditFacadeMulticall {
    /// @dev Instructs CreditFacadeV3 to check token balances at the end
    /// Used to control slippage after the entire sequence of operations, since tracking slippage
    /// On each operation is not ideal. Stores expected balances (computed as current balance + passed delta)
    /// and compare with actual balances at the end of a multicall, reverts
    /// if at least one is less than expected
    /// @param expected Array of expected balance changes
    /// @notice This is an extenstion function that does not exist in the Credit Facade
    ///         itself and can only be used within a multicall
    function revertIfReceivedLessThan(Balance[] memory expected) external;

    /// @dev Enables token in enabledTokenMask for the Credit Account of msg.sender
    /// @param token Address of token to enable
    function enableToken(address token) external;

    /// @dev Disables a token on the caller's Credit Account
    /// @param token Token to disable
    /// @notice This is an extenstion function that does not exist in the Credit Facade
    ///         itself and can only be used within a multicall
    function disableToken(address token) external;

    /// @dev Adds collateral to borrower's credit account
    /// @param token Address of a collateral token
    /// @param amount Amount to add
    function addCollateral(address token, uint256 amount) external payable;

    /// @dev Increases debt for msg.sender's Credit Account
    /// - Borrows the requested amount from the pool
    /// - Updates the CA's borrowAmount / cumulativeIndexOpen
    ///   to correctly compute interest going forward
    /// - Performs a full collateral check
    ///
    /// @param amount Amount to borrow
    function increaseDebt(uint256 amount) external;

    /// @dev Decrease debt
    /// - Decreases the debt by paying the requested amount + accrued interest + fees back to the pool
    /// - It's also include to this payment interest accrued at the moment and fees
    /// - Updates cunulativeIndex to cumulativeIndex now
    ///
    /// @param amount Amount to increase borrowed amount
    function decreaseDebt(uint256 amount) external;

    /// @dev Update msg.sender's Credit Account quotas for multiple tokens
    /// @param quotaUpdates Requested quota updates, see `QuotaUpdate`
    function updateQuotas(QuotaUpdate[] memory quotaUpdates) external;

    /// @dev Set collateral hints for a full check
    /// @param collateralHints Array of token mask in the desired order of checking
    /// @param minHealthFactor Minimal HF threshold to pass the collateral check in PERCENTAGE format.
    ///                        Cannot be lower than PERCENTAGE_FACTOR.
    function setFullCheckParams(uint256[] memory collateralHints, uint16 minHealthFactor) external;
}

interface ICreditFacadeEvents {
    /// @dev Emits when BlacklistHelper is set for CreditFacadeV3 upon creation
    event BlacklistHelperSet(address indexed blacklistHelper);

    /// @dev Emits when a new Credit Account is opened through the
    ///      Credit Facade
    event OpenCreditAccount(
        address indexed onBehalfOf, address indexed creditAccount, uint256 borrowAmount, uint16 referralCode
    );

    /// @dev Emits when the account owner closes their CA normally
    event CloseCreditAccount(address indexed borrower, address indexed to);

    /// @dev Emits when a Credit Account is liquidated due to low health factor
    event LiquidateCreditAccount(
        address indexed borrower,
        address indexed liquidator,
        address indexed to,
        ClosureAction closureAction,
        uint256 remainingFunds
    );

    /// @dev Emits when remaining funds in underlying currency are sent to blacklist helper
    ///      upon blacklisted borrower liquidation
    event UnderlyingSentToBlacklistHelper(address indexed borrower, uint256 amount);

    /// @dev Emits when the account owner increases CA's debt
    event IncreaseBorrowedAmount(address indexed borrower, uint256 amount);

    /// @dev Emits when the account owner reduces CA's debt
    event DecreaseBorrowedAmount(address indexed borrower, uint256 amount);

    /// @dev Emits when the account owner add new collateral to a CA
    event AddCollateral(address indexed onBehalfOf, address indexed token, uint256 value);

    /// @dev Emits when a multicall is started
    event MultiCallStarted(address indexed borrower);

    /// @dev Emits when a multicall is finished
    event MultiCallFinished();

    /// @dev Emits when Credit Account ownership is transferred
    event TransferAccount(address indexed oldOwner, address indexed newOwner);

    /// @dev Emits when the user changes approval for account transfers to itself from another address
    event TransferAccountAllowed(address indexed from, address indexed to, bool state);
}

interface ICreditFacade is ICreditFacadeEvents, IVersion {
    //
    // CREDIT ACCOUNT MANAGEMENT
    //

    /// @dev Opens a Credit Account and runs a batch of operations in a multicall
    /// @param borrowedAmount Debt size
    /// @param onBehalfOf The address to open an account for. Transfers to it have to be allowed if
    /// msg.sender != obBehalfOf
    /// @param calls The array of MultiCall structs encoding the required operations. Generally must have
    /// at least a call to addCollateral, as otherwise the health check at the end will fail.
    /// @param referralCode Referral code which is used for potential rewards. 0 if no referral code provided
    function openCreditAccount(
        uint256 borrowedAmount,
        address onBehalfOf,
        MultiCall[] calldata calls,
        uint16 referralCode
    ) external payable;

    /// @dev Runs a batch of transactions within a multicall and closes the account
    /// - Wraps ETH to WETH and sends it msg.sender if value > 0
    /// - Executes the multicall - the main purpose of a multicall when closing is to convert all assets to underlying
    /// in order to pay the debt.
    /// - Closes credit account:
    ///    + Checks the underlying balance: if it is greater than the amount paid to the pool, transfers the underlying
    ///      from the Credit Account and proceeds. If not, tries to transfer the shortfall from msg.sender.
    ///    + Transfers all enabled assets with non-zero balances to the "to" address, unless they are marked
    ///      to be skipped in skipTokenMask
    ///    + If convertWETH is true, converts WETH into ETH before sending to the recipient
    /// - Emits a CloseCreditAccount event
    ///
    /// @param to Address to send funds to during account closing
    /// @param skipTokenMask Uint-encoded bit mask where 1's mark tokens that shouldn't be transferred
    /// @param convertWETH If true, converts WETH into ETH before sending to "to"
    /// @param calls The array of MultiCall structs encoding the operations to execute before closing the account.
    function closeCreditAccount(address to, uint256 skipTokenMask, bool convertWETH, MultiCall[] calldata calls)
        external
        payable;

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
    ///    + If convertWETH is true, converts WETH into ETH before sending
    /// - Emits LiquidateCreditAccount event
    ///
    /// @param to Address to send funds to after liquidation
    /// @param skipTokenMask Uint-encoded bit mask where 1's mark tokens that shouldn't be transferred
    /// @param convertWETH If true, converts WETH into ETH before sending to "to"
    /// @param calls The array of MultiCall structs encoding the operations to execute before liquidating the account.
    function liquidateCreditAccount(
        address borrower,
        address to,
        uint256 skipTokenMask,
        bool convertWETH,
        MultiCall[] calldata calls
    ) external payable;

    // /// @dev Adds collateral to borrower's credit account
    // /// @param onBehalfOf Address of the borrower whose account is funded
    // /// @param token Address of a collateral token
    // /// @param amount Amount to add
    // function addCollateral(address onBehalfOf, address token, uint256 amount) external payable;

    /// @dev Executes a batch of transactions within a Multicall, to manage an existing account
    ///  - Wraps ETH and sends it back to msg.sender, if value > 0
    ///  - Executes the Multicall
    ///  - Performs a fullCollateralCheck to verify that hf > 1 after all actions
    /// @param calls The array of MultiCall structs encoding the operations to execute.
    function multicall(MultiCall[] calldata calls) external payable;

    /// @dev Executes a batch of transactions within a Multicall from bot on behalf of a borrower
    ///  - Wraps ETH and sends it back to msg.sender, if value > 0
    ///  - Executes the Multicall
    ///  - Performs a fullCollateralCheck to verify that hf > 1 after all actions
    /// @param borrower Borrower the perform the multicall for
    /// @param calls The array of MultiCall structs encoding the operations to execute.
    function botMulticall(address borrower, MultiCall[] calldata calls) external payable;

    /// @dev Returns true if the borrower has an open Credit Account
    /// @param borrower Borrower address
    function hasOpenedCreditAccount(address borrower) external view returns (bool);

    /// @dev Approves account transfer from another user to msg.sender
    /// @param from Address for which account transfers are allowed/forbidden
    /// @param state True is transfer is allowed, false if forbidden
    function approveAccountTransfer(address from, bool state) external;

    // /// @dev Enables token in enabledTokenMask for the Credit Account of msg.sender
    // /// @param token Address of token to enable
    // function enableToken(address token) external;

    /// @dev Transfers credit account to another user
    /// By default, this action is forbidden, and the user has to approve transfers from sender to itself
    /// by calling approveAccountTransfer.
    /// This is done to prevent malicious actors from transferring compromised accounts to other users.
    /// @param to Address to transfer the account to
    function transferAccountOwnership(address to) external;

    //
    // GETTERS
    //

    /// @dev Calculates total value for provided Credit Account in underlying
    ///
    /// @param creditAccount Credit Account address
    /// @return total Total value in underlying
    // @return twv Total weighted (discounted by liquidation thresholds) value in underlying
    function calcTotalValue(address creditAccount) external view returns (uint256 total, uint256 twv);

    /**
     * @dev Calculates health factor for the credit account
     *
     *          sum(asset[i] * liquidation threshold[i])
     *   Hf = --------------------------------------------
     *         borrowed amount + interest accrued + fees
     *
     *
     * More info: https://dev.gearbox.fi/developers/credit/economy#health-factor
     *
     * @param creditAccount Credit account address
     * @return hf = Health factor in bp (see PERCENTAGE FACTOR in Constants.sol)
     */
    // function calcCreditAccountHealthFactor(address creditAccount) external view returns (uint256 hf);

    /// @dev Bit mask encoding a set of forbidden tokens
    function forbiddenTokenMask() external view returns (uint256);

    /// @dev Returns the CreditManagerV3 connected to this Credit Facade
    function creditManager() external view returns (ICreditManagerV2);

    /// @dev Returns true if 'from' is allowed to transfer Credit Accounts to 'to'
    /// @param from Sender address to check allowance for
    /// @param to Receiver address to check allowance for
    function transfersAllowed(address from, address to) external view returns (bool);

    /// @return maxBorrowedAmountPerBlock Maximal amount of new debt that can be taken per block
    /// @return isIncreaseDebtForbidden True if increasing debt is forbidden
    /// @return expirationDate Timestamp of the next expiration (for expirable Credit Facades only)
    function params()
        external
        view
        returns (uint128 maxBorrowedAmountPerBlock, bool isIncreaseDebtForbidden, uint40 expirationDate);

    /// @return minBorrowedAmount Minimal borrowed amount per credit account
    /// @return maxBorrowedAmount Maximal borrowed amount per credit account
    function limits() external view returns (uint128 minBorrowedAmount, uint128 maxBorrowedAmount);

    /// @return currentCumulativeLoss The total amount of loss accumulated since last reset
    /// @return maxCumulativeLoss The maximal amount of loss accumulated before the Credit Manager is paused
    function lossParams() external view returns (uint128 currentCumulativeLoss, uint128 maxCumulativeLoss);

    /// @dev Address of the DegenNFT that gatekeeps account openings in whitelisted mode
    function degenNFT() external view returns (address);

    /// @dev Address of the underlying asset
    function underlying() external view returns (address);

    /// @dev Address of the blacklist helper or address(0), if the underlying is not blacklistable
    function blacklistHelper() external view returns (address);

    /// @dev Whether the underlying of connected Credit Manager is blacklistable
    function isBlacklistableUnderlying() external view returns (bool);

    /// @dev Maps addresses to their status as emergency liquidator.
    /// @notice Emergency liquidators are trusted addresses
    /// that are able to liquidate positions while the contracts are paused,
    /// e.g. when there is a risk of bad debt while an exploit is being patched.
    /// In the interest of fairness, emergency liquidators do not receive a premium
    /// And are compensated by the Gearbox DAO separately.
    function canLiquidateWhilePaused(address) external view returns (bool);
}
