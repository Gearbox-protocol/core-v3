// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

// LIBRARIES
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// TRAITS
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SanityCheckTrait} from "../traits/SanityCheckTrait.sol";
import {BalanceHelperTrait} from "../traits/BalanceHelperTrait.sol";

// INTERFACES
import {IAccountFactory} from "@gearbox-protocol/core-v2/contracts/interfaces/IAccountFactory.sol";
import {ICreditAccount} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditAccount.sol";
import {IPoolService} from "@gearbox-protocol/core-v2/contracts/interfaces/IPoolService.sol";
import {IPool4626} from "../interfaces/IPool4626.sol";
import {IWETHGateway} from "../interfaces/IWETHGateway.sol";
import {IWithdrawManager, CancellationType} from "../interfaces/IWithdrawManager.sol";
import {
    ICreditManagerV2,
    ClosureAction,
    CollateralTokenData,
    ManageDebtAction,
    CreditAccountInfo,
    RevocationPair,
    WITHDRAWAL_FLAG
} from "../interfaces/ICreditManagerV2.sol";
import {IAddressProvider} from "@gearbox-protocol/core-v2/contracts/interfaces/IAddressProvider.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import {IPoolQuotaKeeper, QuotaUpdate, TokenLT} from "../interfaces/IPoolQuotaKeeper.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

// CONSTANTS
import {RAY} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";
import {
    DEFAULT_FEE_INTEREST,
    DEFAULT_FEE_LIQUIDATION,
    DEFAULT_LIQUIDATION_PREMIUM,
    LEVERAGE_DECIMALS,
    ALLOWANCE_THRESHOLD
} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

import "forge-std/console.sol";

uint256 constant ADDR_BIT_SIZE = 160;
uint256 constant INDEX_PRECISION = 10 ** 9;

struct Slot1 {
    /// @dev Interest fee charged by the protocol: fee = interest accrued * feeInterest
    uint16 feeInterest;
    /// @dev Liquidation fee charged by the protocol: fee = totalValue * feeLiquidation
    uint16 feeLiquidation;
    /// @dev Multiplier used to compute the total value of funds during liquidation.
    /// At liquidation, the borrower's funds are discounted, and the pool is paid out of discounted value
    /// The liquidator takes the difference between the discounted and actual values as premium.
    uint16 liquidationDiscount;
    /// @dev Liquidation fee charged by the protocol during liquidation by expiry. Typically lower than feeLiquidation.
    uint16 feeLiquidationExpired;
    /// @dev Multiplier used to compute the total value of funds during liquidation by expiry. Typically higher than
    /// liquidationDiscount (meaning lower premium).
    uint16 liquidationDiscountExpired;
    /// @dev Price oracle used to evaluate assets on Credit Accounts.
    IPriceOracleV2 priceOracle;
    /// @dev Liquidation threshold for the underlying token.
    uint16 ltUnderlying;
}

/// @title Credit Manager
/// @notice Encapsulates the business logic for managing Credit Accounts
///
/// More info: https://dev.gearbox.fi/developers/credit/credit_manager
contract CreditManagerV3 is ICreditManagerV2, SanityCheckTrait, ReentrancyGuard, BalanceHelperTrait {
    using SafeERC20 for IERC20;
    using Address for address payable;
    using SafeCast for uint256;

    /// @dev The maximal number of enabled tokens on a single Credit Account
    uint8 public override maxAllowedEnabledTokenLength = 12;

    /// @dev Address of the connected Credit Facade
    address public override creditFacade;

    /// @dev Points to creditAccount during multicall, otherwise keeps address(1) for gas savings
    /// CreditFacade is trusted source, so primarly it sends creditAccount as parameter
    /// externalCallCA is used for adapters interation when adapter calls approve / execute methods
    address public externalCallCA;

    /// @dev Stores fees & parameters commonly used together for gas savings
    Slot1 internal slot1;

    /// @dev A map from borrower addresses to Credit Account addresses
    mapping(address => address) public override creditAccounts;

    /// @dev Factory contract for Credit Accounts
    IAccountFactory public immutable _accountFactory;

    /// @dev Address of the underlying asset
    address public immutable override underlying;

    /// @dev Address of the connected pool
    address public immutable override pool;

    /// @dev Address of WETH
    address public immutable override wethAddress;

    /// @dev Address of WETH Gateway
    address public immutable wethGateway;

    /// @dev Address of the connected Credit Configurator
    address public creditConfigurator;

    /// @dev Map of token's bit mask to its address and LT parameters in a single-slot struct
    mapping(uint256 => CollateralTokenData) internal collateralTokensData;

    /// @dev Total number of known collateral tokens.
    uint256 public collateralTokensCount;

    /// @dev Internal map of token addresses to their indidivual masks.
    /// @notice A mask is a uint256 that has only 1 non-zero bit in the position correspondingto
    ///         the token's index (i.e., tokenMask = 2 ** index)
    ///         Masks are used to efficiently check set inclusion, since it only involves
    ///         a single AND and comparison to zero
    mapping(address => uint256) internal tokenMasksMapInternal;

    /// @dev Maps Credit Accounts to bit masks encoding their enabled token sets
    /// Only enabled tokens are counted as collateral for the Credit Account
    /// @notice An enabled token mask encodes an enabled token by setting
    ///         the bit at the position equal to token's index to 1
    mapping(address => CreditAccountInfo) internal creditAccountInfo;

    mapping(address => uint256) public borrowedAmounts;

    mapping(address => uint256) public cumulativeIndicies;

    /// @dev Previously accrued and unrepaid interest on quotas.
    ///      This does not always represent the most actual quota interest,
    ///      since it continuously accrues for all active quotas. The accrued interest
    ///      needs to be periodically cached to ensure that computations are correct
    mapping(address => uint256) public cumulativeQuotaInterest;

    /// @dev Maps allowed adapters to their respective target contracts.
    mapping(address => address) public override adapterToContract;

    /// @dev Maps 3rd party contracts to their respective adapters
    mapping(address => address) public override contractToAdapter;

    /// QUOTA-RELATED PARAMS

    /// @dev Whether the CM supports quota-related logic
    bool public immutable override supportsQuotas;

    /// @dev Mask of tokens to apply quotas for
    uint256 public override limitedTokenMask;

    IWithdrawManager public withdrawManager;

    /// @dev contract version
    uint256 public constant override version = 3_00;

    //
    // MODIFIERS
    //

    /// @dev Restricts calls to Credit Facade or allowed adapters
    modifier adaptersOnly() {
        if (adapterToContract[msg.sender] == address(0)) {
            revert CallerNotAdapterException();
        } //
        _;
    }

    /// @dev Restricts calls to Credit Facade only
    modifier creditFacadeOnly() {
        if (msg.sender != creditFacade) revert CallerNotCreditFacadeException();
        _;
    }

    /// @dev Restricts calls to Credit Facade only
    modifier withdrawManagerOnly() {
        if (msg.sender != address(withdrawManager)) revert CallerNotCreditFacadeException();
        _;
    }

    /// @dev Restricts calls to Credit Configurator only
    modifier creditConfiguratorOnly() {
        if (msg.sender != creditConfigurator) {
            revert CallerNotConfiguratorException();
        }
        _;
    }

    /// @dev Constructor
    /// @param _pool Address of the pool to borrow funds from
    constructor(address _pool) {
        IAddressProvider addressProvider = IPoolService(_pool).addressProvider();

        pool = _pool; // F:[CM-1]

        address _underlying = IPoolService(pool).underlyingToken(); // F:[CM-1]
        underlying = _underlying; // F:[CM-1]

        try IPool4626(pool).supportsQuotas() returns (bool sq) {
            supportsQuotas = sq;
        } catch {}

        // The underlying is the first token added as collateral
        _addToken(_underlying); // F:[CM-1]

        wethAddress = addressProvider.getWethToken(); // F:[CM-1]
        wethGateway = addressProvider.getWETHGateway(); // F:[CM-1]

        // Price oracle is stored in Slot1, as it is accessed frequently with fees
        slot1.priceOracle = IPriceOracleV2(addressProvider.getPriceOracle()); // F:[CM-1]
        _accountFactory = IAccountFactory(addressProvider.getAccountFactory()); // F:[CM-1]
        creditConfigurator = msg.sender; // F:[CM-1]

        externalCallCA = address(1);
    }

    //
    // CREDIT ACCOUNT MANAGEMENT
    //

    ///  @dev Opens credit account and borrows funds from the pool.
    /// - Takes Credit Account from the factory;
    /// - Requests the pool to lend underlying to the Credit Account
    ///
    /// @param borrowedAmount Amount to be borrowed by the Credit Account
    /// @param onBehalfOf The owner of the newly opened Credit Account
    function openCreditAccount(uint256 borrowedAmount, address onBehalfOf)
        external
        override
        nonReentrant
        creditFacadeOnly // F:[CM-2]
        nonZeroAddress(onBehalfOf) // TODO: Add test
        returns (address creditAccount)
    {
        // Takes a Credit Account from the factory and sets initial parameters
        // The Credit Account will be connected to this Credit Manager until closing
        creditAccount = _accountFactory.takeCreditAccount(0, 0); // F:[CM-8]

        borrowedAmounts[creditAccount] = borrowedAmount;
        cumulativeIndicies[creditAccount] = IPoolService(pool).calcLinearCumulative_RAY();

        // Requests the pool to transfer tokens the Credit Account
        IPoolService(pool).lendCreditAccount(borrowedAmount, creditAccount); // F:[CM-8]

        // Checks that the onBehalfOf does not already have an account, and records it as owner
        _safeCreditAccountSet(onBehalfOf, creditAccount); // F:[CM-7]

        // Initializes the enabled token mask for Credit Account to 1 (only the underlying is enabled)
        // OUTDATED: enabledTokensMap is set in FullCollateralCheck
        // enabledTokensMap[creditAccount] = 1; // F:[CM-8]

        if (supportsQuotas) cumulativeQuotaInterest[creditAccount] = 1; // F: [CMQ-1]
    }

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
    /// @param borrower Borrower address
    /// @param closureActionType Whether the account is closed, liquidated or liquidated due to expiry
    /// @param totalValue Portfolio value for liqution, 0 for ordinary closure
    /// @param payer Address which would be charged if credit account has not enough funds to cover amountToPool
    /// @param to Address to which the leftover funds will be sent
    /// @param skipTokensMask Tokenmask contains 1 for tokens which needed to be send directly
    /// @param convertWETH If true converts WETH to ETH
    function closeCreditAccount(
        address borrower,
        ClosureAction closureActionType,
        uint256 totalValue,
        address payer,
        address to,
        uint256 enabledTokenMask,
        uint256 skipTokensMask,
        uint256 borrowedAmountWithInterest,
        bool convertWETH
    )
        external
        override
        nonReentrant
        creditFacadeOnly // F:[CM-2]
        returns (uint256 remainingFunds, uint256 loss)
    {
        // Checks that the Credit Account exists for the borrower
        address creditAccount = getCreditAccountOrRevert(borrower); // F:[CM-6, 9, 10]

        // Sets borrower's Credit Account to zero address in the map
        // This needs to be done before other actions, to prevent inconsistent state
        // in the middle of closing transaction - e.g., _transferAssetsTo can be used to report a lower
        // value of a CA to third parties before the end of the function execution, since it
        // gives up control flow when some assets are already removed from the account
        delete creditAccounts[borrower]; // F:[CM-9]
        {
            // Makes all computations needed to close credit account
            uint256 amountToPool;
            uint256 borrowedAmount = borrowedAmounts[creditAccount];

            uint256 profit;

            (amountToPool, remainingFunds, profit, loss) =
                calcClosePayments(totalValue, closureActionType, borrowedAmount, borrowedAmountWithInterest); // F:[CM-10,11,12]

            uint256 underlyingBalance = _balanceOf(underlying, creditAccount);

            // If there is an underlying surplus, transfers it to the "to" address
            if (underlyingBalance > amountToPool + remainingFunds + 1) {
                unchecked {
                    _safeTokenTransfer(
                        creditAccount,
                        underlying,
                        to,
                        underlyingBalance - amountToPool - remainingFunds - 1,
                        convertWETH
                    ); // F:[CM-10,12,16]
                }
                // If there is an underlying shortfall, attempts to transfer it from the payer
            } else {
                unchecked {
                    IERC20(underlying).safeTransferFrom(
                        payer, creditAccount, amountToPool + remainingFunds - underlyingBalance + 1
                    ); // F:[CM-11,13]
                }
            }

            // Transfers the due funds to the pool
            _safeTokenTransfer(creditAccount, underlying, pool, amountToPool, false); // F:[CM-10,11,12,13]

            // Signals to the pool that debt has been repaid. The pool relies
            // on the Credit Manager to repay the debt correctly, and does not
            // check internally whether the underlying was actually transferred
            IPoolService(pool).repayCreditAccount(borrowedAmount, profit, loss); // F:[CM-10,11,12,13]
        }

        if (supportsQuotas) {
            TokenLT[] memory tokens;
            tokens = _getQuotedTokens(enabledTokenMask);

            if (tokens.length > 0) {
                poolQuotaKeeper().removeQuotas(creditAccount, tokens); // F: [CMQ-6]

                if (loss > 0) {
                    poolQuotaKeeper().setLimitsToZero(tokens); // F: [CMQ-12]
                }
            }
        }

        // transfer remaining funds to the borrower [liquidations only]
        if (remainingFunds > 1) {
            _safeTokenTransfer(creditAccount, underlying, borrower, remainingFunds, false); // F:[CM-13,18]
        }

        enabledTokenMask &= ~skipTokensMask;

        _transferAssetsTo(creditAccount, to, convertWETH, enabledTokenMask); // F:[CM-14,17,19]

        // Returns Credit Account to the factory
        _accountFactory.returnCreditAccount(creditAccount); // F:[CM-9]
    }

    /// @dev Manages debt size for borrower:
    ///
    /// - Increase debt:
    ///   + Increases debt by transferring funds from the pool to the credit account
    ///   + Updates the cumulative index to keep interest the same. Since interest
    ///     is always computed dynamically as borrowedAmount * (cumulativeIndexNew / cumulativeIndexOpen - 1),
    ///     cumulativeIndexOpen needs to be updated, as the borrow amount has changed
    ///
    /// - Decrease debt:
    ///   + Repays debt partially + all interest and fees accrued thus far
    ///   + Updates cunulativeIndex to cumulativeIndex now
    ///
    /// @param creditAccount Address of the Credit Account to change debt for
    /// @param amount Amount to increase / decrease the principal by
    /// @param action Increase/decrease bed debt
    /// @return newBorrowedAmount The new debt principal
    function manageDebt(address creditAccount, uint256 amount, uint256 enableTokenMask, ManageDebtAction action)
        external
        nonReentrant
        creditFacadeOnly // F:[CM-2]
        returns (uint256 newBorrowedAmount)
    {
        (uint256 borrowedAmount, uint256 cumulativeIndexAtOpen_RAY, uint256 cumulativeIndexNow_RAY) =
            _getCreditAccountParameters(creditAccount);

        uint256 newCumulativeIndex;
        if (action == ManageDebtAction.INCREASE_DEBT) {
            // Checks that there are no forbidden tokens, as borrowing
            // is prohibited when forbidden tokens are enabled on the account
            /// TODO: add in collateral
            // _checkForbiddenTokens(creditAccount);

            newBorrowedAmount = borrowedAmount + amount;

            // Computes the new cumulative index to keep the interest
            // unchanged with different principal
            newCumulativeIndex =
                _calcNewCumulativeIndex(borrowedAmount, amount, cumulativeIndexNow_RAY, cumulativeIndexAtOpen_RAY, true);

            // Requests the pool to lend additional funds to the Credit Account
            IPoolService(pool).lendCreditAccount(amount, creditAccount); // F:[CM-20]
        } else {
            // Decrease
            uint256 amountRepaid = amount;
            uint256 amountProfit = 0;

            if (supportsQuotas) {
                (amountRepaid, amountProfit) =
                    _computeQuotasAmountDebtDecrease(creditAccount, amountRepaid, amountProfit, enableTokenMask);
            }

            if (amountRepaid > 0) {
                // Computes the interest accrued thus far
                uint256 interestAccrued =
                    (borrowedAmount * cumulativeIndexNow_RAY) / cumulativeIndexAtOpen_RAY - borrowedAmount; // F:[CM-21]

                // Computes profit, taken as a percentage of the interest rate
                uint256 profit = (interestAccrued * slot1.feeInterest) / PERCENTAGE_FACTOR; // F:[CM-21]

                if (amountRepaid >= interestAccrued + profit) {
                    // If the amount covers all of the interest and fees, they are
                    // paid first, and the remainder is used to pay the principal

                    amountRepaid -= interestAccrued + profit;
                    newBorrowedAmount = borrowedAmount - amountRepaid; //  + interestAccrued + profit - amount;

                    amountProfit += profit;

                    // Since interest is fully repaid, the Credit Account's cumulativeIndexAtOpen
                    // is set to the current cumulative index - which means interest starts accruing
                    // on the new principal from zero
                    newCumulativeIndex = cumulativeIndexNow_RAY; // F:[CM-21]
                } else {
                    // If the amount is not enough to cover interest and fees,
                    // then the sum is split between dao fees and pool profits pro-rata. Since the fee is the percentage
                    // of interest, this ensures that the new fee is consistent with the
                    // new pending interest

                    uint256 amountToPool = (amountRepaid * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + slot1.feeInterest);

                    amountProfit += amountRepaid - amountToPool;
                    amountRepaid = 0;

                    // Since interest and fees are paid out first, the principal
                    // remains unchanged
                    newBorrowedAmount = borrowedAmount;

                    // Since the interest was only repaid partially, we need to recompute the
                    // cumulativeIndexAtOpen, so that "borrowAmount * (indexNow / indexAtOpenNew - 1)"
                    // is equal to interestAccrued - amountToInterest
                    newCumulativeIndex = _calcNewCumulativeIndex(
                        borrowedAmount, amountToPool, cumulativeIndexNow_RAY, cumulativeIndexAtOpen_RAY, false
                    );
                }
            } else {
                newBorrowedAmount = borrowedAmount;
                newCumulativeIndex = cumulativeIndexAtOpen_RAY;
            }

            // Pays the amount back to the pool
            ICreditAccount(creditAccount).safeTransfer(underlying, pool, amount); // F:[CM-21]

            // TODO: delete after tests or write Invaraiant test
            require(borrowedAmount - newBorrowedAmount == amountRepaid, "Ooops, something was wring");

            IPoolService(pool).repayCreditAccount(amountRepaid, amountProfit, 0); // F:[CM-21]
        }
        //
        // Sets new parameters on the Credit Account if they were changed
        if (newBorrowedAmount != borrowedAmount || newCumulativeIndex != cumulativeIndexAtOpen_RAY) {
            borrowedAmounts[creditAccount] = newBorrowedAmount;
            cumulativeIndicies[creditAccount] = newCumulativeIndex;
            // ICreditAccount(creditAccount).updateParameters(newBorrowedAmount, newCumulativeIndex); // F:[CM-20. 21]
        }
    }

    function _computeQuotasAmountDebtDecrease(
        address creditAccount,
        uint256 _amountRepaid,
        uint256 _amountProfit,
        uint256 enabledTokenMask
    ) internal returns (uint256 amountRepaid, uint256 amountProfit) {
        amountRepaid = _amountRepaid;
        amountProfit = _amountProfit;

        uint16 feeInterest = slot1.feeInterest;
        uint256 quotaInterestAccrued = cumulativeQuotaInterest[creditAccount] - 1;

        TokenLT[] memory tokens = _getQuotedTokens(enabledTokenMask);
        if (tokens.length > 0) {
            quotaInterestAccrued += poolQuotaKeeper().accrueQuotaInterest(creditAccount, tokens); // F: [CMQ-4,5]
        }

        if (quotaInterestAccrued > 1) {
            uint256 quotaProfit = (quotaInterestAccrued * feeInterest) / PERCENTAGE_FACTOR;

            if (amountRepaid >= quotaInterestAccrued + quotaProfit) {
                amountRepaid -= quotaInterestAccrued + quotaProfit; // F: [CMQ-5]
                amountProfit += quotaProfit; // F: [CMQ-5]
                cumulativeQuotaInterest[creditAccount] = 1; // F: [CMQ-5]
            } else {
                uint256 amountToPool = (amountRepaid * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest);

                amountProfit += amountRepaid - amountToPool; // F: [CMQ-4]
                amountRepaid = 0; // F: [CMQ-4]

                uint256 newCumulativeQuotaInterest = quotaInterestAccrued - amountToPool;

                cumulativeQuotaInterest[creditAccount] = newCumulativeQuotaInterest + 1; // F: [CMQ-4]
            }
        }
    }

    /// @dev Calculates the new cumulative index when debt is updated
    /// @param borrowedAmount Current debt principal
    /// @param delta Absolute value of total debt amount change
    /// @param cumulativeIndexNow Current cumulative index of the pool
    /// @param cumulativeIndexOpen Last updated cumulative index recorded for the corresponding debt position
    /// @param isIncrease Whether the debt is increased or decreased
    /// @notice Handles two potential cases:
    ///         * Debt principal is increased by delta - in this case, the principal is changed
    ///           but the interest / fees have to stay the same
    ///         * Interest is decreased by delta - in this case, the principal stays the same,
    ///           but the interest changes. The delta is assumed to have fee repayment excluded.
    ///         The debt decrease case where delta > interest + fees is trivial and should be handled outside
    ///         this function.
    function _calcNewCumulativeIndex(
        uint256 borrowedAmount,
        uint256 delta,
        uint256 cumulativeIndexNow,
        uint256 cumulativeIndexOpen,
        bool isIncrease
    ) internal pure returns (uint256 newCumulativeIndex) {
        if (isIncrease) {
            // In case of debt increase, the principal increases by exactly delta, but interest has to be kept unchanged
            // newCumulativeIndex is proven to be the solution to
            // borrowedAmount * (cumulativeIndexNow / cumulativeIndexOpen - 1) ==
            // == (borrowedAmount + delta) * (cumulativeIndexNow / newCumulativeIndex - 1)

            uint256 newBorrowedAmount = borrowedAmount + delta;

            newCumulativeIndex = (
                (cumulativeIndexNow * newBorrowedAmount * INDEX_PRECISION)
                    / (
                        (INDEX_PRECISION * cumulativeIndexNow * borrowedAmount) / cumulativeIndexOpen
                            + INDEX_PRECISION * delta
                    )
            );
        } else {
            // In case of debt decrease, the principal is the same, but the interest is reduced exactly by delta
            // newCumulativeIndex is proven to be the solution to
            // borrowedAmount * (cumulativeIndexNow / cumulativeIndexOpen - 1) - delta ==
            // == borrowedAmount * (cumulativeIndexNow / newCumulativeIndex - 1)

            newCumulativeIndex = (INDEX_PRECISION * cumulativeIndexNow * cumulativeIndexOpen)
                / (INDEX_PRECISION * cumulativeIndexNow - (INDEX_PRECISION * delta * cumulativeIndexOpen) / borrowedAmount);
        }
    }

    /// @dev Adds collateral to borrower's credit account
    /// @param payer Address of the account which will be charged to provide additional collateral
    /// @param creditAccount Address of the Credit Account
    /// @param token Collateral token to add
    /// @param amount Amount to add
    function addCollateral(address payer, address creditAccount, address token, uint256 amount)
        external
        nonReentrant
        creditFacadeOnly // F:[CM-2]
        returns (uint256 tokenMask)
    {
        tokenMask = getTokenMaskOrRevert(token);
        IERC20(token).safeTransferFrom(payer, creditAccount, amount); // F:[CM-22]
    }

    /// @dev Transfers Credit Account ownership to another address
    /// @param from Address of previous owner
    /// @param to Address of new owner
    function transferAccountOwnership(address from, address to)
        external
        override
        nonReentrant
        creditFacadeOnly // F:[CM-2]
        nonZeroAddress(to) // TODO: Add test
    {
        address creditAccount = getCreditAccountOrRevert(from); // F:[CM-6]
        delete creditAccounts[from]; // F:[CM-24]

        _safeCreditAccountSet(to, creditAccount); // F:[CM-23, 24]
    }

    /// @dev Requests the Credit Account to approve a collateral token to another contract.

    /// @param targetContract Spender to change allowance for
    /// @param token Collateral token to approve
    /// @param amount New allowance amount
    function approveCreditAccount(address targetContract, address token, uint256 amount)
        external
        override
        adaptersOnly
        nonReentrant
    {
        // This function can only be called by connected adapters (must be a correct adapter/contract pair),
        // Credit Facade or Universal Adapter
        if (
            (adapterToContract[msg.sender] != targetContract && msg.sender != creditFacade)
                || targetContract == address(0)
        ) {
            revert CallerNotAdapterException(); // F:[CM-3,25]
        }

        _approveSpender(token, targetContract, externalCallCreditAccountOrRevert(), amount);
    }

    function _approveSpender(address token, address targetContract, address creditAccount, uint256 amount) internal {
        // Checks that the token is a collateral token
        // Forbidden tokens can be approved, since users need that to
        // sell them off
        getTokenMaskOrRevert(token);

        // Attempts to set allowance directly to the required amount
        // If unsuccessful, assumes that the token requires setting allowance to zero first
        if (!_approve(token, targetContract, creditAccount, amount, false)) {
            _approve(token, targetContract, creditAccount, 0, true); // F:
            _approve(token, targetContract, creditAccount, amount, true);
        }
    }

    /// @dev Internal function used to approve token from a Credit Account
    /// Uses Credit Account's execute to properly handle both ERC20-compliant and
    /// non-compliant (no returned value from "approve") tokens
    function _approve(address token, address targetContract, address creditAccount, uint256 amount, bool revertIfFailed)
        internal
        returns (bool)
    {
        // Makes a low-level call to approve from the Credit Account
        // and parses the value. If nothing or true was returned,
        // assumes that the call succeeded
        try ICreditAccount(creditAccount).execute(token, abi.encodeCall(IERC20.approve, (targetContract, amount)))
        returns (bytes memory result) {
            if (result.length == 0 || abi.decode(result, (bool)) == true) {
                return true;
            }
        } catch {}

        // On the first try, failure is allowed to handle tokens
        // that prohibit changing allowance from non-zero value;
        // After that, failure results in a revert
        if (revertIfFailed) revert AllowanceFailedException();
        return false;
    }

    /// @dev Requests a Credit Account to make a low-level call with provided data
    /// This is the intended pathway for state-changing interactions with 3rd-party protocols
    /// @param targetContract Contract to be called
    /// @param data Data to pass with the call
    function executeOrder(address targetContract, bytes memory data)
        external
        override
        adaptersOnly
        nonReentrant
        returns (bytes memory)
    {
        // Checks that msg.sender is the adapter associated with the passed
        // target contract.
        if (adapterToContract[msg.sender] != targetContract || targetContract == address(0)) {
            revert TargetContractNotAllowedException();
            // F:[CM-28]
        }

        // Emits an event
        emit ExecuteOrder(targetContract); // F:[CM-29]

        // Returned data is provided as-is to the caller;
        // It is expected that is is parsed and returned as a correct type
        // by the adapter itself.
        return ICreditAccount(externalCallCreditAccountOrRevert()).execute(targetContract, data); // F:[CM-29]
    }

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
        uint256 enabledTokenMask,
        uint256[] memory collateralHints,
        uint16 minHealthFactor
    ) external creditFacadeOnly nonReentrant {
        if (minHealthFactor < PERCENTAGE_FACTOR) {
            revert CustomHealthFactorTooLowException();
        }

        IPriceOracleV2 _priceOracle = slot1.priceOracle;

        uint256 twvUSD;
        uint256 borrowAmountPlusInterestRateAndFeesUSD;

        (enabledTokenMask,, twvUSD, borrowAmountPlusInterestRateAndFeesUSD,) =
            _calcAllCollateral(_priceOracle, creditAccount, enabledTokenMask, minHealthFactor, collateralHints, true);

        if (twvUSD < borrowAmountPlusInterestRateAndFeesUSD) {
            revert NotEnoughCollateralException();
        }

        _saveEnabledTokenMask(creditAccount, enabledTokenMask);
    }

    /// @dev Calculates total value for provided Credit Account in underlying
    /// More: https://dev.gearbox.fi/developers/credit/economy#totalUSD-value
    ///
    /// @param creditAccount Credit Account address
    // @return total Total value in underlying
    // @return twv Total weighted (discounted by liquidation thresholds) value in underlying
    function calcTotalValue(address creditAccount)
        external
        view
        override
        returns (
            uint256 enabledTokenMask,
            uint256 total,
            uint256 hf,
            uint256 borrowedAmountWithInterest,
            bool canBeLiquidated
        )
    {
        IPriceOracleV2 _priceOracle = slot1.priceOracle;
        uint256[] memory collateralHints;
        enabledTokenMask = enabledTokensMap(creditAccount);
        uint256 totalUSD;
        uint256 twvUSD;
        uint256 borrowAmountPlusInterestRateAndFeesUSD;
        (, totalUSD, twvUSD, borrowAmountPlusInterestRateAndFeesUSD, borrowedAmountWithInterest) =
            _calcAllCollateral(_priceOracle, creditAccount, enabledTokenMask, PERCENTAGE_FACTOR, collateralHints, false);

        total = _convertFromUSD(_priceOracle, totalUSD, underlying); // F:[FA-41]
        hf = twvUSD * PERCENTAGE_FACTOR / borrowAmountPlusInterestRateAndFeesUSD;

        canBeLiquidated = twvUSD < borrowAmountPlusInterestRateAndFeesUSD;
    }

    /// @dev Calculates total value for provided Credit Account in USD
    // @param _priceOracle Oracle used to convert assets to USD
    // @param creditAccount Address of the Credit Account
    // @return totalUSD Total value of the account in USD
    // @return canBeLiquidated True if HF <1
    function _calcAllCollateral(
        IPriceOracleV2 _priceOracle,
        address creditAccount,
        uint256 enabledTokenMask,
        uint16 minHealthFactor,
        uint256[] memory collateralHints,
        bool lazy
    )
        internal
        view
        returns (
            uint256 _enabledTokenMask,
            uint256 totalUSD,
            uint256 twvUSD,
            uint256 borrowAmountPlusInterestRateAndFeesUSD,
            uint256 borrowedAmountWithInterestAndFees
        )
    {
        uint256 quotaInterest;

        if (supportsQuotas) {
            (totalUSD, twvUSD, quotaInterest) = _calcQuotedCollateral(creditAccount, enabledTokenMask, _priceOracle);
        }

        {
            // The total weighted value of a Credit Account has to be compared
            // with the entire debt sum, including interest and fees
            (,, borrowedAmountWithInterestAndFees) = _calcCreditAccountAccruedInterest(creditAccount, quotaInterest);

            borrowAmountPlusInterestRateAndFeesUSD = _convertToUSD(
                _priceOracle,
                borrowedAmountWithInterestAndFees * minHealthFactor, // F: [CM-42]
                underlying
            ) / PERCENTAGE_FACTOR;
        }

        // If quoted tokens fully cover the debt, we can stop here
        // after performing some additional cleanup
        if (twvUSD < borrowAmountPlusInterestRateAndFeesUSD || !lazy) {
            uint256 limit = lazy ? (borrowAmountPlusInterestRateAndFeesUSD - twvUSD) : type(uint256).max;
            uint256 _totalUSD;
            uint256 _twvUSD;

            (enabledTokenMask, _totalUSD, _twvUSD) =
                _calcNotQuotedCollateral(_priceOracle, creditAccount, enabledTokenMask, limit, collateralHints);
            totalUSD += _totalUSD;
            twvUSD += _twvUSD;
        }

        _enabledTokenMask = enabledTokenMask;
    }

    function _calcQuotedCollateral(address creditAccount, uint256 enabledTokenMask, IPriceOracleV2 _priceOracle)
        internal
        view
        returns (uint256 totalValueUSD, uint256 twvUSD, uint256 quotaInterest)
    {
        TokenLT[] memory tokens = _getQuotedTokens(enabledTokenMask);

        if (tokens.length > 0) {
            /// If credit account has any connected token - then check that
            (totalValueUSD, twvUSD, quotaInterest) = poolQuotaKeeper().computeQuotedCollateralUSD(
                address(this), creditAccount, address(_priceOracle), tokens
            ); // F: [CMQ-8]
        }

        quotaInterest += cumulativeQuotaInterest[creditAccount] - 1; // F: [CMQ-8]
    }

    function _calcNotQuotedCollateral(
        IPriceOracleV2 _priceOracle,
        address creditAccount,
        uint256 _enabledTokensMask,
        uint256 borrowAmountPlusInterestRateAndFeesUSD,
        uint256[] memory collateralHints
    ) internal view returns (uint256 enabledTokensMask, uint256 totalValue, uint256 twvUSD) {
        uint256 tokenMask;
        uint256 len = collateralHints.length;
        bool nonZeroBalance;

        enabledTokensMask = _enabledTokensMask;
        uint256 checkedTokenMask = supportsQuotas ? enabledTokensMask & (~limitedTokenMask) : enabledTokensMask;

        if (borrowAmountPlusInterestRateAndFeesUSD != type(uint256).max) {
            borrowAmountPlusInterestRateAndFeesUSD *= PERCENTAGE_FACTOR;
        }

        uint256 twvUSDx10K;

        unchecked {
            // TODO: add test that we check all values and it's always reachable
            for (uint256 i; checkedTokenMask != 0; ++i) {
                tokenMask = (i < len) ? collateralHints[i] : 1 << (i - len); // F: [CM-68]

                // CASE enabledTokenMask & tokenMask == 0 F:[CM-38]
                if (checkedTokenMask & tokenMask != 0) {
                    (totalValue, twvUSDx10K, nonZeroBalance) =
                        _calcOneNonQuotedTokenCollateral(_priceOracle, tokenMask, creditAccount, totalValue, twvUSDx10K);

                    // Collateral calculations are only done if there is a non-zero balance
                    if (nonZeroBalance) {
                        // Full collateral check evaluates a Credit Account's health factor lazily;
                        // Once the TWV computed thus far exceeds the debt, the check is considered
                        // successful, and the function returns without evaluating any further collateral
                        if (twvUSDx10K >= borrowAmountPlusInterestRateAndFeesUSD) {
                            break;
                        }
                        // Zero-balance tokens are disabled; this is done by flipping the
                        // bit in enabledTokenMask, which is then written into storage at the
                        // very end, to avoid redundant storage writes
                    } else {
                        enabledTokensMask &= ~tokenMask; // F:[CM-39]
                    }
                }

                checkedTokenMask &= (~tokenMask);
            }
        }

        twvUSD = twvUSDx10K / PERCENTAGE_FACTOR;
    }

    function _calcOneNonQuotedTokenCollateral(
        IPriceOracleV2 _priceOracle,
        uint256 tokenMask,
        address creditAccount,
        uint256 _totalValueUSD,
        uint256 _twvUSDx10K
    ) internal view returns (uint256 totalValueUSD, uint256 twvUSDx10K, bool nonZeroBalance) {
        (address token, uint16 liquidationThreshold) = collateralTokensByMask(tokenMask);
        uint256 balance = _balanceOf(token, creditAccount);

        // Collateral calculations are only done if there is a non-zero balance
        if (balance > 1) {
            uint256 balanceUSD = _convertToUSD(_priceOracle, balance, token);
            totalValueUSD = _totalValueUSD + balanceUSD;
            twvUSDx10K = _twvUSDx10K + balanceUSD * liquidationThreshold;

            nonZeroBalance = true;
        }
    }

    function _calcDelayedWithdrawalCollateral(address creditAccount)
        internal
        view
        returns (uint256 amount, uint256 enabledTokenMask)
    {
        // (address token1, uint256 amount1, address token2, uint256 amount2) =
    }

    /// @dev Returns the array of quoted tokens that are enabled on the account
    function getQuotedTokens(address creditAccount) public view returns (TokenLT[] memory tokens) {
        return _getQuotedTokens(enabledTokensMap(creditAccount));
    }

    function _getQuotedTokens(uint256 enabledTokensMask) internal view returns (TokenLT[] memory tokens) {
        uint256 quotedMask = enabledTokensMask & limitedTokenMask;

        if (quotedMask > 0) {
            tokens = new TokenLT[](maxAllowedEnabledTokenLength + 1);

            uint256 j;

            unchecked {
                for (uint256 tokenMask = 2; tokenMask <= quotedMask; tokenMask <<= 1) {
                    if (quotedMask & tokenMask != 0) {
                        (address token, uint16 lt) = collateralTokensByMask(tokenMask);
                        tokens[j] = TokenLT({token: token, lt: lt});
                        ++j;
                    }
                }
            }
        }
    }

    //
    // QUOTAS MANAGEMENT
    //

    /// @dev Updates credit account's quotas for multiple tokens
    /// @param creditAccount Address of credit account
    /// @param quotaUpdates Requested quota updates, see `QuotaUpdate`
    function updateQuotas(address creditAccount, QuotaUpdate[] memory quotaUpdates)
        external
        override
        creditFacadeOnly // F: [CMQ-3]
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        uint256 caInterestChange;
        (caInterestChange, tokensToEnable, tokensToDisable) =
            poolQuotaKeeper().updateQuotas(creditAccount, quotaUpdates); // F: [CMQ-3]

        cumulativeQuotaInterest[creditAccount] += caInterestChange; // F: [CMQ-3]
    }

    //
    // INTERNAL HELPERS
    //

    /// @dev Transfers all enabled assets from a Credit Account to the "to" address
    /// @param creditAccount Credit Account to transfer assets from
    /// @param to Recipient address
    /// @param convertWETH Whether WETH must be converted to ETH before sending
    /// @param enabledTokensMask A bit mask encoding enabled tokens. All of the tokens included
    ///        in the mask will be transferred. If any tokens need to be skipped, they must be
    ///        excluded from the mask beforehand.
    function _transferAssetsTo(address creditAccount, address to, bool convertWETH, uint256 enabledTokensMask)
        internal
    {
        // Since underlying should have been transferred to "to" before this function is called
        // (if there is a surplus), its tokenMask of 1 is skipped
        uint256 tokenMask = 2;

        // Since enabledTokensMask encodes all enabled tokens as 1,
        // tokenMask > enabledTokensMask is equivalent to the last 1 bit being passed
        // The loop can be ended at this point
        while (tokenMask <= enabledTokensMask) {
            // enabledTokensMask & tokenMask == tokenMask when the token is enabled,
            // and 0 otherwise
            if (enabledTokensMask & tokenMask != 0) {
                (address token,) = collateralTokensByMask(tokenMask); // F:[CM-44]
                uint256 amount = _balanceOf(token, creditAccount); // F:[CM-44]
                if (amount > 1) {
                    // 1 is subtracted from amount to leave a non-zero value
                    // in the balance mapping, optimizing future writes
                    // Since the amount is checked to be more than 1,
                    // the block can be marked as unchecked

                    // F:[CM-44]
                    unchecked {
                        _safeTokenTransfer(creditAccount, token, to, amount - 1, convertWETH); // F:[CM-44]
                    }
                }
            }

            // The loop iterates by moving 1 bit to the left,
            // which corresponds to moving on to the next token
            tokenMask = tokenMask << 1; // F:[CM-44]
        }
    }

    /// @dev Requests the Credit Account to transfer a token to another address
    ///      Able to unwrap WETH before sending, if requested
    /// @param creditAccount Address of the sender Credit Account
    /// @param token Address of the token
    /// @param to Recipient address
    /// @param amount Amount to transfer
    function _safeTokenTransfer(address creditAccount, address token, address to, uint256 amount, bool convertToETH)
        internal
    {
        if (convertToETH && token == wethAddress) {
            ICreditAccount(creditAccount).safeTransfer(token, wethGateway, amount); // F:[CM-45]
            IWETHGateway(wethGateway).depositFor(to, amount); // F:[CM-45]
        } else {
            try ICreditAccount(creditAccount).safeTransfer(token, to, amount) { // F:[CM-45]
            } catch {
                uint256 balanceBefore = _balanceOf(token, address(withdrawManager));
                ICreditAccount(creditAccount).safeTransfer(token, address(withdrawManager), amount);
                withdrawManager.addImmediateWithdrawal(
                    to, token, _balanceOf(token, address(withdrawManager)) - balanceBefore
                );
            }
        }
    }

    /// @dev Sets the Credit Account owner while checking that they do not
    ///      have an account already
    /// @param borrower The new owner of the Credit Account
    /// @param creditAccount The Credit Account address
    function _safeCreditAccountSet(address borrower, address creditAccount) internal {
        if (creditAccounts[borrower] != address(0)) {
            revert UserAlreadyHasAccountException();
        } // F:[CM-7]
        creditAccounts[borrower] = creditAccount; // F:[CM-7]
    }

    //
    // GETTERS
    //

    /// @dev Computes amounts that must be sent to various addresses before closing an account
    /// @param totalValue Credit Accounts total value in underlying
    /// @param closureActionType Type of account closure
    ///        * CLOSE_ACCOUNT: The account is healthy and is closed normally
    ///        * LIQUIDATE_ACCOUNT: The account is unhealthy and is being liquidated to avoid bad debt
    ///        * LIQUIDATE_EXPIRED_ACCOUNT: The account has expired and is being liquidated (lowered liquidation premium)
    ///        * LIQUIDATE_PAUSED: The account is liquidated while the system is paused due to emergency (no liquidation premium)
    /// @param borrowedAmount Credit Account's debt principal
    /// @param borrowedAmountWithInterest Credit Account's debt principal + interest
    /// @return amountToPool Amount of underlying to be sent to the pool
    /// @return remainingFunds Amount of underlying to be sent to the borrower (only applicable to liquidations)
    /// @return profit Protocol's profit from fees (if any)
    /// @return loss Protocol's loss from bad debt (if any)
    function calcClosePayments(
        uint256 totalValue,
        ClosureAction closureActionType,
        uint256 borrowedAmount,
        uint256 borrowedAmountWithInterest
    ) public view override returns (uint256 amountToPool, uint256 remainingFunds, uint256 profit, uint256 loss) {
        // The amount to be paid to pool is computed with fees included
        // The pool will compute the amount of Diesel tokens to treasury
        // based on profit
        amountToPool = borrowedAmountWithInterest
            + ((borrowedAmountWithInterest - borrowedAmount) * slot1.feeInterest) / PERCENTAGE_FACTOR; // F:[CM-43]

        if (
            closureActionType == ClosureAction.LIQUIDATE_ACCOUNT
                || closureActionType == ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT
        ) {
            // LIQUIDATION CASE

            // During liquidation, totalValue of the account is discounted
            // by (1 - liquidationPremium). This means that totalValue * liquidationPremium
            // is removed from all calculations and can be claimed by the liquidator at the end of transaction

            // The liquidation premium depends on liquidation type:
            // * For normal unhealthy account or emergency liquidations, usual premium applies
            // * For expiry liquidations, the premium is typically reduced,
            //   since the account does not risk bad debt, so the liquidation
            //   is not as urgent

            uint256 totalFunds = (
                totalValue
                    * (
                        closureActionType == ClosureAction.LIQUIDATE_ACCOUNT
                            ? slot1.liquidationDiscount
                            : slot1.liquidationDiscountExpired
                    )
            ) / PERCENTAGE_FACTOR; // F:[CM-43]

            amountToPool += (
                totalValue
                    * (
                        closureActionType == ClosureAction.LIQUIDATE_ACCOUNT
                            ? slot1.feeLiquidation
                            : slot1.feeLiquidationExpired
                    )
            ) / PERCENTAGE_FACTOR; // F:[CM-43]

            // If there are any funds left after all respective payments (this
            // includes the liquidation premium, since totalFunds is already
            // discounted from totalValue), they are recorded to remainingFunds
            // and will later be sent to the borrower.

            // If totalFunds is not sufficient to cover the entire payment to pool,
            // the Credit Manager will repay what it can. When totalFunds >= debt + interest,
            // this simply means that part of protocol fees will be waived (profit is reduced). Otherwise,
            // there is bad debt (loss > 0).

            // Since values are compared to each other before subtracting,
            // this can be marked as unchecked to optimize gas

            unchecked {
                if (totalFunds > amountToPool) {
                    remainingFunds = totalFunds - amountToPool - 1; // F:[CM-43]
                } else {
                    amountToPool = totalFunds; // F:[CM-43]
                }

                if (totalFunds >= borrowedAmountWithInterest) {
                    profit = amountToPool - borrowedAmountWithInterest; // F:[CM-43]
                } else {
                    loss = borrowedAmountWithInterest - amountToPool; // F:[CM-43]
                }
            }
        } else {
            // CLOSURE CASE

            // During closure, it is assumed that the user has enough to cover
            // the principal + interest + fees. closeCreditAccount, thus, will
            // attempt to charge them the entire amount.

            // Since in this case amountToPool + borrowedAmountWithInterest + fee,
            // this block can be marked as unchecked

            unchecked {
                profit = amountToPool - borrowedAmountWithInterest; // F:[CM-43]
            }
        }
    }

    /// @dev Returns the collateral token at requested index and its liquidation threshold
    /// @param id The index of token to return
    function collateralTokens(uint256 id) public view returns (address token, uint16 liquidationThreshold) {
        // Collateral tokens are stored under their masks rather than
        // indicies, so this is simply a convenience function that wraps
        // the getter by mask
        return collateralTokensByMask(1 << id);
    }

    /// @dev Returns the collateral token with requested mask and its liquidationThreshold
    /// @param tokenMask Token mask corresponding to the token
    function collateralTokensByMask(uint256 tokenMask)
        public
        view
        override
        returns (address token, uint16 liquidationThreshold)
    {
        // The underlying is a special case and its mask is always 1
        if (tokenMask == 1) {
            token = underlying; // F:[CM-47]
            liquidationThreshold = slot1.ltUnderlying;
        } else {
            CollateralTokenData memory tokenData = collateralTokensData[tokenMask]; // F:[CM-47]

            token = tokenData.token;

            if (token == address(0)) {
                revert TokenNotAllowedException();
            }

            if (block.timestamp < tokenData.timestampRampStart) {
                liquidationThreshold = tokenData.ltInitial; // F:[CM-47]
            } else if (block.timestamp < tokenData.timestampRampStart + tokenData.rampDuration) {
                liquidationThreshold = _getRampingLiquidationThreshold(
                    tokenData.ltInitial,
                    tokenData.ltFinal,
                    tokenData.timestampRampStart,
                    tokenData.timestampRampStart + tokenData.rampDuration
                );
            } else {
                liquidationThreshold = tokenData.ltFinal;
            }
        }
    }

    function _getRampingLiquidationThreshold(
        uint16 ltInitial,
        uint16 ltFinal,
        uint40 timestampRampStart,
        uint40 timestampRampEnd
    ) internal view returns (uint16) {
        return uint16(
            (ltInitial * (timestampRampEnd - block.timestamp) + ltFinal * (block.timestamp - timestampRampStart))
                / (timestampRampEnd - timestampRampStart)
        ); // F: [CM-72]
    }

    /// @dev Returns the address of a borrower's Credit Account, or reverts if there is none.
    /// @param borrower Borrower's address
    function getCreditAccountOrRevert(address borrower) public view override returns (address result) {
        result = creditAccounts[borrower]; // F:[CM-48]
        if (result == address(0)) revert HasNoOpenedAccountException(); // F:[CM-48]
    }

    /// @dev Calculates the debt accrued by a Credit Account
    /// @param creditAccount Address of the Credit Account
    /// @return borrowedAmount The debt principal
    /// @return borrowedAmountWithInterest The debt principal + accrued interest
    /// @return borrowedAmountWithInterestAndFees The debt principal + accrued interest and protocol fees
    function calcCreditAccountAccruedInterest(address creditAccount)
        external
        view
        override
        returns (uint256 borrowedAmount, uint256 borrowedAmountWithInterest, uint256 borrowedAmountWithInterestAndFees)
    {
        uint256 quotaInterest;

        if (supportsQuotas) {
            TokenLT[] memory tokens = getQuotedTokens(creditAccount);

            quotaInterest = cumulativeQuotaInterest[creditAccount] - 1;

            if (tokens.length > 0) {
                quotaInterest += poolQuotaKeeper().outstandingQuotaInterest(address(this), creditAccount, tokens); // F: [CMQ-10]
            }
        }

        return _calcCreditAccountAccruedInterest(creditAccount, quotaInterest);
    }

    /// @dev IMPLEMENTATION: calcCreditAccountAccruedInterest
    /// @param creditAccount Address of the Credit Account
    /// @param quotaInterest Total quota premiums accrued, computed elsewhere
    /// @return borrowedAmount The debt principal
    /// @return borrowedAmountWithInterest The debt principal + accrued interest
    /// @return borrowedAmountWithInterestAndFees The debt principal + accrued interest and protocol fees
    function _calcCreditAccountAccruedInterest(address creditAccount, uint256 quotaInterest)
        internal
        view
        returns (uint256 borrowedAmount, uint256 borrowedAmountWithInterest, uint256 borrowedAmountWithInterestAndFees)
    {
        uint256 cumulativeIndexAtOpen_RAY;
        uint256 cumulativeIndexNow_RAY;
        (borrowedAmount, cumulativeIndexAtOpen_RAY, cumulativeIndexNow_RAY) = _getCreditAccountParameters(creditAccount); // F:[CM-49]

        // Interest is never stored and is always computed dynamically
        // as the difference between the current cumulative index of the pool
        // and the cumulative index recorded in the Credit Account
        borrowedAmountWithInterest =
            (borrowedAmount * cumulativeIndexNow_RAY) / cumulativeIndexAtOpen_RAY + quotaInterest; // F:[CM-49]

        // Fees are computed as a percentage of interest
        borrowedAmountWithInterestAndFees = borrowedAmountWithInterest
            + ((borrowedAmountWithInterest - borrowedAmount) * slot1.feeInterest) / PERCENTAGE_FACTOR; // F: [CM-49]
    }

    /// @dev Returns the parameters of the Credit Account required to calculate debt
    /// @param creditAccount Address of the Credit Account
    /// @return borrowedAmount Debt principal amount
    /// @return cumulativeIndexAtOpen_RAY The cumulative index value used to calculate
    ///         interest in conjunction  with current pool index. Not necessarily the index
    ///         value at the time of account opening, since it can be updated by manageDebt.
    /// @return cumulativeIndexNow_RAY Current cumulative index of the pool
    function _getCreditAccountParameters(address creditAccount)
        internal
        view
        returns (uint256 borrowedAmount, uint256 cumulativeIndexAtOpen_RAY, uint256 cumulativeIndexNow_RAY)
    {
        borrowedAmount = borrowedAmounts[creditAccount]; // F:[CM-49,50]
        cumulativeIndexAtOpen_RAY = cumulativeIndicies[creditAccount]; // ICreditAccount(creditAccount).cumulativeIndexAtOpen(); // F:[CM-49,50]
        cumulativeIndexNow_RAY = IPoolService(pool).calcLinearCumulative_RAY(); // F:[CM-49,50]
    }

    /// @dev Returns the liquidation threshold for the provided token
    /// @param token Token to retrieve the LT for
    function liquidationThresholds(address token) public view override returns (uint16 lt) {
        // Underlying is a special case and its LT is stored separately
        if (token == underlying) return slot1.ltUnderlying; // F:[CM-47]

        uint256 tokenMask = getTokenMaskOrRevert(token);
        (, lt) = collateralTokensByMask(tokenMask); // F:[CM-47]
    }

    /// @dev Returns the mask for the provided token
    /// @param token Token to returns the mask for
    function getTokenMaskOrRevert(address token) public view override returns (uint256 tokenMask) {
        tokenMask = (token == underlying) ? 1 : tokenMasksMapInternal[token];
        if (tokenMask == 0) revert TokenNotAllowedException();
    }

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
        override
        returns (
            uint16 feeInterest,
            uint16 feeLiquidation,
            uint16 liquidationDiscount,
            uint16 feeLiquidationExpired,
            uint16 liquidationDiscountExpired
        )
    {
        feeInterest = slot1.feeInterest; // F:[CM-51]
        feeLiquidation = slot1.feeLiquidation; // F:[CM-51]
        liquidationDiscount = slot1.liquidationDiscount; // F:[CM-51]
        feeLiquidationExpired = slot1.feeLiquidationExpired; // F:[CM-51]
        liquidationDiscountExpired = slot1.liquidationDiscountExpired; // F:[CM-51]
    }

    /// @dev Returns the price oracle used to evaluate collateral tokens
    function priceOracle() external view override returns (IPriceOracleV2) {
        return slot1.priceOracle;
    }

    /// @dev Address of the connected pool
    /// @notice [DEPRECATED]: use pool() instead.
    function poolService() external view returns (address) {
        return pool;
    }

    function poolQuotaKeeper() public view returns (IPoolQuotaKeeper) {
        return IPoolQuotaKeeper(IPool4626(pool).poolQuotaKeeper());
    }

    //
    // CONFIGURATION
    //
    // The following function change vital Credit Manager parameters
    // and can only be called by the Credit Configurator
    //

    /// @dev Adds a token to the list of collateral tokens
    /// @param token Address of the token to add
    function addToken(address token)
        external
        creditConfiguratorOnly // F:[CM-4]
    {
        _addToken(token); // F:[CM-52]
    }

    /// @dev IMPLEMENTATION: addToken
    /// @param token Address of the token to add
    function _addToken(address token) internal {
        // Checks that the token is not already known (has an associated token mask)
        if (tokenMasksMapInternal[token] > 0) {
            revert TokenAlreadyAddedException();
        } // F:[CM-52]

        // Checks that there aren't too many tokens
        // Since token masks are 248 bit numbers with each bit corresponding to 1 token,
        // only at most 248 are supported
        if (collateralTokensCount >= 248) revert TooManyTokensException(); // F:[CM-52]

        // The tokenMask of a token is a bit mask with 1 at position corresponding to its index
        // (i.e. 2 ** index or 1 << index)
        uint256 tokenMask = 1 << collateralTokensCount;
        tokenMasksMapInternal[token] = tokenMask; // F:[CM-53]

        collateralTokensData[tokenMask] = CollateralTokenData({
            token: token,
            ltInitial: 0,
            ltFinal: 0,
            timestampRampStart: type(uint40).max,
            rampDuration: 0
        }); // F:[CM-47]

        collateralTokensCount++; // F:[CM-47]
    }

    /// @dev Sets fees and premiums
    /// @param _feeInterest Percentage of interest taken by the protocol as profit
    /// @param _feeLiquidation Percentage of account value taken by the protocol as profit
    ///         during unhealthy account liquidations
    /// @param _liquidationDiscount Multiplier that reduces the effective totalValue during unhealthy account liquidations,
    ///         allowing the liquidator to take the unaccounted for remainder as premium. Equal to (1 - liquidationPremium)
    /// @param _feeLiquidationExpired Percentage of account value taken by the protocol as profit
    ///         during expired account liquidations
    /// @param _liquidationDiscountExpired Multiplier that reduces the effective totalValue during expired account liquidations,
    ///         allowing the liquidator to take the unaccounted for remainder as premium. Equal to (1 - liquidationPremiumExpired)
    function setParams(
        uint16 _feeInterest,
        uint16 _feeLiquidation,
        uint16 _liquidationDiscount,
        uint16 _feeLiquidationExpired,
        uint16 _liquidationDiscountExpired
    )
        external
        creditConfiguratorOnly // F:[CM-4]
    {
        slot1.feeInterest = _feeInterest; // F:[CM-51]
        slot1.feeLiquidation = _feeLiquidation; // F:[CM-51]
        slot1.liquidationDiscount = _liquidationDiscount; // F:[CM-51]
        slot1.feeLiquidationExpired = _feeLiquidationExpired; // F:[CM-51]
        slot1.liquidationDiscountExpired = _liquidationDiscountExpired; // F:[CM-51]
    }

    //
    // CONFIGURATION
    //

    /// @dev Sets the liquidation threshold for a collateral token
    /// @notice Liquidation thresholds are weights used to compute
    ///         TWV with. They denote the risk of the token, with
    ///         more volatile and unpredictable tokens having lower LTs.
    /// @param token The collateral token to set the LT for
    /// @param liquidationThreshold The new LT
    function setLiquidationThreshold(address token, uint16 liquidationThreshold)
        external
        creditConfiguratorOnly // F:[CM-4]
    {
        // Underlying is a special case and its LT is stored in Slot1,
        // to be accessed frequently
        if (token == underlying) {
            // F:[CM-47]
            slot1.ltUnderlying = liquidationThreshold; // F:[CM-47]
        } else {
            uint256 tokenMask = getTokenMaskOrRevert(token); // F:[CM-47, 54]

            CollateralTokenData memory tokenData = collateralTokensData[tokenMask];

            _setLTRampParams(tokenData, tokenMask, liquidationThreshold, liquidationThreshold, type(uint40).max, 0); // F:[CM-47]
        }
    }

    /// @dev Sets ramping parameters for a token's liquidation threshold
    /// @notice Ramping parameters allow to decrease the LT gradually over a period of time
    ///         which gives users/bots time to react and adjust their position for the new LT
    /// @param token The collateral token to set the LT for
    /// @param finalLT The final LT after ramping
    /// @param timestampRampStart Timestamp when the LT starts ramping
    /// @param rampDuration Duration of ramping
    function rampLiquidationThreshold(address token, uint16 finalLT, uint40 timestampRampStart, uint24 rampDuration)
        external
        creditConfiguratorOnly
    {
        uint256 tokenMask = getTokenMaskOrRevert(token);

        if (tokenMask == 1) revert CannotRampLTForUnderlyingException();

        CollateralTokenData memory tokenData = collateralTokensData[tokenMask];

        _setLTRampParams(tokenData, tokenMask, tokenData.ltInitial, finalLT, timestampRampStart, rampDuration); // F: [CM-71]
    }

    /// @dev Internal function that sets the LT params
    function _setLTRampParams(
        CollateralTokenData memory tokenData,
        uint256 tokenMask,
        uint16 ltInitial,
        uint16 ltFinal,
        uint40 timestampRampStart,
        uint24 rampDuration
    ) internal {
        tokenData.ltInitial = ltInitial;
        tokenData.ltFinal = ltFinal;
        tokenData.timestampRampStart = timestampRampStart;
        tokenData.rampDuration = rampDuration;

        collateralTokensData[tokenMask] = tokenData;
    }

    /// @dev Sets the limited token mask
    /// @param _limitedTokenMask The new mask
    /// @notice Limited tokens are counted as collateral not based on their balances,
    ///         but instead based on their quotas set in the poolQuotaKeeper contract
    ///         Tokens in the mask also incur additional interest based on their quotas
    function setLimitedMask(uint256 _limitedTokenMask)
        external
        creditConfiguratorOnly // F: [CMQ-2]
    {
        limitedTokenMask = _limitedTokenMask; // F: [CMQ-2]
    }

    /// @dev Sets the maximal number of enabled tokens on a single Credit Account.
    /// @param newMaxEnabledTokens The new enabled token limit.
    function setMaxEnabledTokens(uint8 newMaxEnabledTokens)
        external
        creditConfiguratorOnly // F: [CM-4]
    {
        maxAllowedEnabledTokenLength = newMaxEnabledTokens; // F: [CC-37]
    }

    /// @dev Sets the link between an adapter and its corresponding targetContract
    /// @param adapter Address of the adapter to be used to access the target contract
    /// @param targetContract A 3rd-party contract for which the adapter is set
    /// @notice The function can be called with (adapter, address(0)) and (address(0), targetContract)
    ///         to disallow a particular target or adapter, since this would set values in respective
    ///         mappings to address(0).
    function changeContractAllowance(address adapter, address targetContract) external creditConfiguratorOnly {
        if (adapter != address(0)) {
            adapterToContract[adapter] = targetContract; // F:[CM-56]
        }
        if (targetContract != address(0)) {
            contractToAdapter[targetContract] = adapter; // F:[CM-56]
        }
    }

    /// @dev Sets the Credit Facade
    /// @param _creditFacade Address of the new Credit Facade
    function upgradeCreditFacade(address _creditFacade)
        external
        creditConfiguratorOnly // F:[CM-4]
    {
        creditFacade = _creditFacade;
    }

    /// @dev Sets the Price Oracle
    /// @param _priceOracle Address of the new Price Oracle
    function upgradePriceOracle(address _priceOracle)
        external
        creditConfiguratorOnly // F:[CM-4]
    {
        slot1.priceOracle = IPriceOracleV2(_priceOracle);
    }

    /// @dev Sets a new Credit Configurator
    /// @param _creditConfigurator Address of the new Credit Configurator
    function setConfigurator(address _creditConfigurator)
        external
        creditConfiguratorOnly // F:[CM-4]
    {
        creditConfigurator = _creditConfigurator; // F:[CM-58]
        emit SetConfigurator(_creditConfigurator); // F:[CM-58]
    }

    function _checkEnabledTokenLength(uint256 enabledTokenMask) internal view {
        uint256 totalTokensEnabled = _calcEnabledTokens(enabledTokenMask);
        if (totalTokensEnabled > maxAllowedEnabledTokenLength) {
            revert TooManyEnabledTokensException();
        }
    }

    /// @dev Calculates the number of enabled tokens, based on the
    ///      provided token mask
    /// @param enabledTokenMask Bit mask encoding a set of enabled tokens
    function _calcEnabledTokens(uint256 enabledTokenMask) internal pure returns (uint256 totalTokensEnabled) {
        // Bit mask is a number encoding enabled tokens as 1's;
        // Therefore, to count the number of enabled tokens, we simply
        // need to keep shifting the mask by one bit and checking if the rightmost bit is 1,
        // until the whole mask is 0;
        // Since bit shifting is overflow-safe and the loop has at most 256 steps,
        // the whole function can be marked as unsafe to optimize gas
        unchecked {
            while (enabledTokenMask > 0) {
                totalTokensEnabled += enabledTokenMask & 1;
                enabledTokenMask >>= 1;
            }
        }
    }

    function withdraw(address creditAccount, address to, address token, uint256 amount)
        external
        override
        creditFacadeOnly
        returns (uint256 tokensToDisable)
    {
        uint256 tokenMask = getTokenMaskOrRevert(token);

        uint256 balanceBefore = _balanceOf(token, address(withdrawManager));

        ICreditAccount(creditAccount).safeTransfer(token, address(withdrawManager), amount);
        withdrawManager.addDelayedWithdrawal(
            creditAccount, to, token, tokenMask, _balanceOf(token, address(withdrawManager)) - balanceBefore
        );

        _enableWithdrawalFlag(creditAccount);

        // We need to disable empty tokens in case they could be forbidden, to finally eliminate them
        if (_balanceOf(token, creditAccount) <= 1) {
            tokensToDisable = tokenMask;
        }
    }

    function cancelWithdrawals(address creditAccount, CancellationType ctype)
        external
        override
        creditFacadeOnly
        returns (uint256 tokensToEnable)
    {
        if (creditAccountInfo[creditAccount].flags & WITHDRAWAL_FLAG != 0) {
            return withdrawManager.cancelWithdrawals(creditAccount, ctype);
        }
    }

    /// @notice Revokes allowances for specified spender/token pairs
    /// @param revocations Spender/token pairs to revoke allowances for
    function revokeAdapterAllowances(address creditAccount, RevocationPair[] calldata revocations)
        external
        override
        creditFacadeOnly
    {
        uint256 numRevocations = revocations.length;
        unchecked {
            for (uint256 i; i < numRevocations; ++i) {
                address spender = revocations[i].spender;
                address token = revocations[i].token;

                if (spender == address(0) || token == address(0)) {
                    revert ZeroAddressException();
                }

                _approveSpender(token, spender, creditAccount, 1);
            }
        }
    }

    ///
    function setCaForExternalCall(address creditAccount) external override creditFacadeOnly {
        externalCallCA = creditAccount;
    }

    function externalCallCreditAccountOrRevert() public view returns (address creditAccount) {
        creditAccount = externalCallCA;
        if (creditAccount == address(1)) revert ExternalCallCreditAccountNotSetException();
    }

    function enabledTokensMap(address creditAccount) public view override returns (uint256) {
        return uint256(creditAccountInfo[creditAccount].enabledTokensMask);
    }

    function _saveEnabledTokenMask(address creditAccount, uint256 enabledTokenMask) internal {
        if (enabledTokenMask > type(uint248).max) {
            revert IncorrectParameterException();
        }
        _checkEnabledTokenLength(enabledTokenMask);
        creditAccountInfo[creditAccount].enabledTokensMask = uint248(enabledTokenMask);
    }

    function _enableWithdrawalFlag(address creditAccount) internal {
        creditAccountInfo[creditAccount].flags |= WITHDRAWAL_FLAG;
    }

    function disableWithdrawalFlag(address creditAccount) external override withdrawManagerOnly {
        creditAccountInfo[creditAccount].flags &= ~WITHDRAWAL_FLAG;
    }

    function _convertFromUSD(IPriceOracleV2 _priceOracle, uint256 amountInUSD, address token)
        internal
        view
        returns (uint256 amountInToken)
    {
        amountInToken = _priceOracle.convertFromUSD(amountInUSD, token);
    }

    function _convertToUSD(IPriceOracleV2 _priceOracle, uint256 amountInToken, address token)
        internal
        view
        returns (uint256 amountInUSD)
    {
        amountInUSD = _priceOracle.convertToUSD(amountInToken, token);
    }
}