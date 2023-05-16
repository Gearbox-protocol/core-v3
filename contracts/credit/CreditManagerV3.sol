// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

// LIBRARIES
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// LIBS & TRAITS
import {UNDERLYING_TOKEN_MASK, BitMask} from "../libraries/BitMask.sol";
import {CreditLogic} from "../libraries/CreditLogic.sol";
import {CreditAccountHelper} from "../libraries/CreditAccountHelper.sol";

import {ReentrancyGuardTrait} from "../traits/ReentrancyGuardTrait.sol";
import {SanityCheckTrait} from "../traits/SanityCheckTrait.sol";
import {IERC20Helper} from "../libraries/IERC20Helper.sol";

// INTERFACES
import {IAccountFactory, TakeAccountAction} from "../interfaces/IAccountFactory.sol";
import {ICreditAccount} from "../interfaces/ICreditAccount.sol";
import {IPoolBase, IPool4626} from "../interfaces/IPool4626.sol";
import {IWETHGateway} from "../interfaces/IWETHGateway.sol";
import {ClaimAction, IWithdrawalManager} from "../interfaces/IWithdrawalManager.sol";
import {
    ICreditManagerV3,
    ClosureAction,
    CollateralTokenData,
    ManageDebtAction,
    CreditAccountInfo,
    RevocationPair,
    CollateralDebtData,
    CollateralCalcTask,
    WITHDRAWAL_FLAG
} from "../interfaces/ICreditManagerV3.sol";
import "../interfaces/IAddressProviderV3.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import {IPoolQuotaKeeper} from "../interfaces/IPoolQuotaKeeper.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

// CONSTANTS
import {RAY} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";
import {
    DEFAULT_FEE_INTEREST,
    DEFAULT_FEE_LIQUIDATION,
    DEFAULT_LIQUIDATION_PREMIUM
} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

import "forge-std/console.sol";

/// @title Credit Manager
/// @notice Encapsulates the business logic for managing Credit Accounts
///
/// More info: https://dev.gearbox.fi/developers/credit/credit_manager
contract CreditManagerV3 is ICreditManagerV3, SanityCheckTrait, ReentrancyGuardTrait {
    using EnumerableSet for EnumerableSet.AddressSet;
    using BitMask for uint256;
    using CreditLogic for CollateralDebtData;
    using CreditLogic for CollateralTokenData;
    using SafeERC20 for IERC20;
    using IERC20Helper for IERC20;
    using CreditAccountHelper for ICreditAccount;

    // IMMUTABLE PARAMS
    /// @dev contract version
    uint256 public constant override version = 3_00;

    /// @dev Factory contract for Credit Accounts
    address public immutable override addressProvider;

    /// @dev Factory contract for Credit Accounts
    address public immutable accountFactory;

    /// @dev Address of the underlying asset
    address public immutable override underlying;

    /// @dev Address of the connected pool
    address public immutable override pool;

    /// @dev Address of WETH
    address public immutable override weth;

    /// @dev Address of WETH Gateway
    address public immutable wethGateway;

    /// @dev Whether the CM supports quota-related logic
    bool public immutable override supportsQuotas;

    TakeAccountAction private immutable deployAccountAction;

    /// @dev Address of the connected Credit Facade
    address public override creditFacade;

    /// @dev The maximal number of enabled tokens on a single Credit Account
    uint8 public override maxEnabledTokens = 12;

    /// @dev Liquidation threshold for the underlying token.
    uint16 internal ltUnderlying;

    /// @dev Interest fee charged by the protocol: fee = interest accrued * feeInterest
    uint16 internal feeInterest;

    /// @dev Liquidation fee charged by the protocol: fee = totalValue * feeLiquidation
    uint16 internal feeLiquidation;

    /// @dev Multiplier used to compute the total value of funds during liquidation.
    /// At liquidation, the borrower's funds are discounted, and the pool is paid out of discounted value
    /// The liquidator takes the difference between the discounted and actual values as premium.
    uint16 internal liquidationDiscount;

    /// @dev Liquidation fee charged by the protocol during liquidation by expiry. Typically lower than feeLiquidation.
    uint16 internal feeLiquidationExpired;

    /// @dev Multiplier used to compute the total value of funds during liquidation by expiry. Typically higher than
    /// liquidationDiscount (meaning lower premium).
    uint16 internal liquidationDiscountExpired;

    /// @dev Price oracle used to evaluate assets on Credit Accounts.
    address public override priceOracle;

    /// @dev Points to creditAccount during multicall, otherwise keeps address(1) for gas savings
    /// CreditFacade is trusted source, so primarly it sends creditAccount as parameter
    /// _externalCallCreditAccount is used for adapters interation when adapter calls approve / execute methods
    address internal _externalCallCreditAccount;

    /// @dev Total number of known collateral tokens.
    uint8 public collateralTokensCount;

    /// @dev Mask of tokens to apply quotas for
    uint256 public override quotedTokenMask;

    /// @dev Withdrawal manager
    address public immutable override withdrawalManager;

    /// @dev Address of the connected Credit Configurator
    address public creditConfigurator;

    /// COLLATERAL TOKENS DATA

    /// @dev Map of token's bit mask to its address and LT parameters in a single-slot struct
    mapping(uint256 => CollateralTokenData) internal collateralTokensData;

    /// @dev Internal map of token addresses to their indidivual masks.
    /// @notice A mask is a uint256 that has only 1 non-zero bit in the position correspondingto
    ///         the token's index (i.e., tokenMask = 2 ** index)
    ///         Masks are used to efficiently check set inclusion, since it only involves
    ///         a single AND and comparison to zero
    mapping(address => uint256) internal tokenMasksMapInternal;

    /// CONTRACTS & ADAPTERS

    /// @dev Maps allowed adapters to their respective target contracts.
    mapping(address => address) public override adapterToContract;

    /// @dev Maps 3rd party contracts to their respective adapters
    mapping(address => address) public override contractToAdapter;

    /// CREDIT ACCOUNT DATA

    /// @dev Contains infomation related to CA
    mapping(address => CreditAccountInfo) public creditAccountInfo;

    /// @dev Array of the allowed contracts
    EnumerableSet.AddressSet private creditAccountsSet;

    //
    // MODIFIERS
    //

    /// @dev Restricts calls to Credit Facade only
    modifier creditFacadeOnly() {
        _checkCreditFacade();
        _;
    }

    function _checkCreditFacade() private view {
        if (msg.sender != creditFacade) revert CallerNotCreditFacadeException();
    }

    /// @dev Restricts calls to Credit Configurator only
    modifier creditConfiguratorOnly() {
        _checkCreditConfigurator();
        _;
    }

    function _checkCreditConfigurator() private view {
        if (msg.sender != creditConfigurator) {
            revert CallerNotConfiguratorException();
        }
    }

    /// @dev Constructor
    /// @param _pool Address of the pool to borrow funds from
    constructor(address _addressProvider, address _pool) {
        addressProvider = _addressProvider;
        pool = _pool; // U:[CM-1]

        underlying = IPoolBase(pool).underlyingToken(); // U:[CM-1]

        try IPool4626(_pool).supportsQuotas() returns (bool sq) {
            supportsQuotas = sq;
        } catch {}

        // The underlying is the first token added as collateral
        _addToken(underlying); // U:[CM-1]

        weth = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_WETH_TOKEN, NO_VERSION_CONTROL); // U:[CM-1]
        wethGateway = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_WETH_GATEWAY, 3_00); // U:[CM-1]
        priceOracle = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_PRICE_ORACLE, 2); // U:[CM-1]
        accountFactory = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_ACCOUNT_FACTORY, 1);
        withdrawalManager = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_WITHDRAWAL_MANAGER, 3_00);

        deployAccountAction = IAccountFactory(accountFactory).version() == 3_00
            ? TakeAccountAction.DEPLOY_NEW_ONE
            : TakeAccountAction.TAKE_USED_ONE;
        creditConfigurator = msg.sender; // U:[CM-1]

        _externalCallCreditAccount = address(1);
    }

    //
    // CREDIT ACCOUNT MANAGEMENT
    //

    ///  @dev Opens credit account and borrows funds from the pool.
    /// - Takes Credit Account from the factory;
    /// - Requests the pool to lend underlying to the Credit Account
    ///
    /// @param debt Amount to be borrowed by the Credit Account
    /// @param onBehalfOf The owner of the newly opened Credit Account
    function openCreditAccount(uint256 debt, address onBehalfOf, bool deployNew)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // // U:[CM-2]
        returns (address creditAccount)
    {
        // Takes a Credit Account from the factory and sets initial parameters
        // The Credit Account will be connected to this Credit Manager until closing
        creditAccount = IAccountFactory(accountFactory).takeCreditAccount(
            uint256(deployNew ? deployAccountAction : TakeAccountAction.TAKE_USED_ONE), 0
        ); // F:[CM-8]

        creditAccountInfo[creditAccount].debt = debt;
        creditAccountInfo[creditAccount].cumulativeIndexLastUpdate = _poolCumulativeIndexNow();
        creditAccountInfo[creditAccount].flags = 0;
        creditAccountInfo[creditAccount].borrower = onBehalfOf;

        if (supportsQuotas) creditAccountInfo[creditAccount].cumulativeQuotaInterest = 1; // F: [CMQ-1]

        // Initializes the enabled token mask for Credit Account to 1 (only the underlying is enabled)
        // OUTDATED: enabledTokensMap is set in FullCollateralCheck
        // enabledTokensMap[creditAccount] = 1; // F:[CM-8]

        // Requests the pool to transfer tokens the Credit Account
        IPoolBase(pool).lendCreditAccount(debt, creditAccount); // F:[CM-8]
        creditAccountsSet.add(creditAccount);
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
    /// - If convertToETH is true, the function converts WETH into ETH before sending
    /// - Returns the Credit Account back to factory
    ///
    /// @param creditAccount Credit account address
    /// @param closureAction Whether the account is closed, liquidated or liquidated due to expiry
    // @param totalValue Portfolio value for liqution, 0 for ordinary closure
    /// @param payer Address which would be charged if credit account has not enough funds to cover amountToPool
    /// @param to Address to which the leftover funds will be sent
    /// @param skipTokensMask Tokenmask contains 1 for tokens which needed to be send directly
    /// @param convertToETH If true converts WETH to ETH
    function closeCreditAccount(
        address creditAccount,
        ClosureAction closureAction,
        CollateralDebtData memory collateralDebtData,
        address payer,
        address to,
        uint256 skipTokensMask,
        bool convertToETH
    )
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 remainingFunds, uint256 loss)
    {
        // Checks that the Credit Account exists for the borrower
        address borrower = getBorrowerOrRevert(creditAccount); // F:[CM-6, 9, 10]

        // Sets borrower's Credit Account to zero address
        creditAccountInfo[creditAccount].borrower = address(0); // F:[CM-9]

        // Makes all computations needed to close credit account
        uint256 amountToPool;
        uint256 profit;

        if (closureAction == ClosureAction.CLOSE_ACCOUNT) {
            (amountToPool, profit) = collateralDebtData.calcClosePayments({amountWithFeeFn: _amountWithFee});
        } else {
            // During liquidation, totalValue of the account is discounted
            // by (1 - liquidationPremium). This means that totalValue * liquidationPremium
            // is removed from all calculations and can be claimed by the liquidator at the end of transaction

            // The liquidation premium depends on liquidation type:
            // * For normal unhealthy account or emergency liquidations, usual premium applies
            // * For expiry liquidations, the premium is typically reduced,
            //   since the account does not risk bad debt, so the liquidation
            //   is not as urgent

            (amountToPool, remainingFunds, profit, loss) = collateralDebtData.calcLiquidationPayments({
                liquidationDiscount: closureAction == ClosureAction.LIQUIDATE_ACCOUNT
                    ? liquidationDiscount
                    : liquidationDiscountExpired,
                feeLiquidation: closureAction == ClosureAction.LIQUIDATE_ACCOUNT ? feeLiquidation : feeLiquidationExpired,
                amountWithFeeFn: _amountWithFee,
                amountMinusFeeFn: _amountWithFee
            });
        }
        {
            uint256 underlyingBalance = IERC20Helper.balanceOf({token: underlying, holder: creditAccount});

            // If there is an underlying shortfall, attempts to transfer it from the payer
            if (underlyingBalance < amountToPool + remainingFunds + 1) {
                unchecked {
                    IERC20(underlying).safeTransferFrom({
                        from: payer,
                        to: creditAccount,
                        value: _amountWithFee(amountToPool + remainingFunds - underlyingBalance + 1)
                    }); // F:[CM-11,13]
                }
            }
        }

        // Transfers the due funds to the pool
        ICreditAccount(creditAccount).transfer({token: underlying, to: pool, amount: amountToPool}); // F:[CM-10,11,12,13]

        // Signals to the pool that debt has been repaid. The pool relies
        // on the Credit Manager to repay the debt correctly, and does not
        // check internally whether the underlying was actually transferred
        _poolRepayCreditAccount(collateralDebtData.debt, profit, loss); // F:[CM-10,11,12,13]

        // transfer remaining funds to the borrower [liquidations only]
        if (remainingFunds > 1) {
            _safeTokenTransfer({
                creditAccount: creditAccount,
                token: underlying,
                to: borrower,
                amount: remainingFunds,
                convertToETH: false
            }); // F:[CM-13,18]
        }

        if (supportsQuotas && collateralDebtData.quotedTokens.length > 0) {
            /// In case of amy loss, PQK sets limits to zero for all quoted tokens
            bool setLimitsToZero = loss > 0;

            IPoolQuotaKeeper(collateralDebtData._poolQuotaKeeper).removeQuotas({
                creditAccount: creditAccount,
                tokens: collateralDebtData.quotedTokens,
                setLimitsToZero: setLimitsToZero
            }); // F: [CMQ-6]
        }

        _batchTokensTransfer({
            creditAccount: creditAccount,
            to: to,
            convertToETH: convertToETH,
            tokensToTransferMask: collateralDebtData.enabledTokensMask.disable(skipTokensMask)
        }); // F:[CM-14,17,19]

        // Returns Credit Account to the factory
        IAccountFactory(accountFactory).returnCreditAccount(creditAccount); // F:[CM-9]
        creditAccountsSet.remove(creditAccount);
    }

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
    /// @param action Increase/decrease bed debt
    /// @return newDebt The new debt principal
    function manageDebt(address creditAccount, uint256 amount, uint256 enabledTokensMask, ManageDebtAction action)
        external
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 newDebt, uint256 tokensToEnable, uint256 tokensToDisable)
    {
        CollateralDebtData memory collateralDebtData;
        uint256[] memory collateralHints;

        uint256 newCumulativeIndex;
        if (action == ManageDebtAction.INCREASE_DEBT) {
            collateralDebtData = _calcDebtAndCollateral({
                creditAccount: creditAccount,
                enabledTokensMask: enabledTokensMask,
                collateralHints: collateralHints,
                minHealthFactor: PERCENTAGE_FACTOR,
                task: CollateralCalcTask.GENERIC_PARAMS
            });
            (newDebt, newCumulativeIndex) = collateralDebtData.calcIncrease(amount);

            // Requests the pool to lend additional funds to the Credit Account
            IPoolBase(pool).lendCreditAccount(amount, creditAccount); // F:[CM-20]
            tokensToEnable = UNDERLYING_TOKEN_MASK;
        } else {
            // Decrease
            collateralDebtData = _calcDebtAndCollateral({
                creditAccount: creditAccount,
                enabledTokensMask: enabledTokensMask,
                collateralHints: collateralHints,
                minHealthFactor: PERCENTAGE_FACTOR,
                task: CollateralCalcTask.DEBT_ONLY
            });

            if (supportsQuotas) {
                IPoolQuotaKeeper(collateralDebtData._poolQuotaKeeper).accrueQuotaInterest(
                    creditAccount, collateralDebtData.quotedTokens
                ); // F: [CMQ-4,5]
            }

            // Pays the amount back to the pool
            ICreditAccount(creditAccount).transfer({token: underlying, to: pool, amount: amount}); // F:[CM-21]
            {
                uint256 amountToRepay;
                uint256 profit;

                (newDebt, newCumulativeIndex, amountToRepay, profit) =
                    collateralDebtData.calcDecrease({amount: amount, feeInterest: feeInterest});

                _poolRepayCreditAccount(amountToRepay, profit, 0); // F:[CM-21]
            }

            if (supportsQuotas) {
                creditAccountInfo[creditAccount].cumulativeQuotaInterest = collateralDebtData.cumulativeQuotaInterest;
            }

            if (IERC20Helper.balanceOf(underlying, creditAccount) <= 1) {
                tokensToDisable = UNDERLYING_TOKEN_MASK;
            }
        }
        //
        // Sets new parameters on the Credit Account if they were changed
        if (newDebt != collateralDebtData.debt || newCumulativeIndex != collateralDebtData.cumulativeIndexLastUpdate) {
            creditAccountInfo[creditAccount].debt = newDebt; // F:[CM-20. 21]
            creditAccountInfo[creditAccount].cumulativeIndexLastUpdate = newCumulativeIndex; // F:[CM-20. 21]
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
        creditFacadeOnly // U:[CM-2]
        returns (uint256 tokenMask)
    {
        tokenMask = getTokenMaskOrRevert(token);
        IERC20(token).safeTransferFrom(payer, creditAccount, amount); // F:[CM-22]
    }

    /// @dev Transfers Credit Account ownership to another address
    /// @param creditAccount Address of creditAccount to be transferred
    /// @param to Address of new owner
    function transferAccountOwnership(address creditAccount, address to)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
    {
        getBorrowerOrRevert(creditAccount);
        creditAccountInfo[creditAccount].borrower = to; // F:[CM-7]
    }

    /// @dev Requests the Credit Account to approve a collateral token to another contract.
    /// @param token Collateral token to approve
    /// @param amount New allowance amount
    function approveCreditAccount(address token, uint256 amount)
        external
        override
        nonReentrant // U:[CM-5]
    {
        address targetContract = _getTargetContractOrRevert(); // U:[CM-3]
        _approveSpender({
            creditAccount: getExternalCallCreditAccountOrRevert(),
            token: token,
            spender: targetContract,
            amount: amount
        });
    }

    function _approveSpender(address creditAccount, address token, address spender, uint256 amount) internal {
        // Checks that the token is a collateral token
        // Forbidden tokens can be approved, since users need that to
        // sell them off
        getTokenMaskOrRevert(token);

        ICreditAccount(creditAccount).safeApprove({token: token, spender: spender, amount: amount});
    }

    /// @dev Requests a Credit Account to make a low-level call with provided data
    /// This is the intended pathway for state-changing interactions with 3rd-party protocols
    /// @param data Data to pass with the call
    function executeOrder(bytes memory data)
        external
        override
        nonReentrant // U:[CM-5]
        returns (bytes memory)
    {
        address targetContract = _getTargetContractOrRevert(); // U:[CM-3]
        // Emits an event
        emit ExecuteOrder(targetContract); // F:[CM-29]

        // Returned data is provided as-is to the caller;
        // It is expected that is is parsed and returned as a correct type
        // by the adapter itself.
        address creditAccount = getExternalCallCreditAccountOrRevert();
        return ICreditAccount(creditAccount).execute(targetContract, data); // F:[CM-29]
    }

    function _getTargetContractOrRevert() internal view returns (address targetContract) {
        targetContract = adapterToContract[msg.sender];

        // Checks that msg.sender is the adapter associated with the passed target contract.
        if (targetContract == address(0)) {
            revert CallerNotAdapterException();
            // F:[CM-28]
        }
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
        uint256 enabledTokensMask,
        uint256[] memory collateralHints,
        uint16 minHealthFactor
    )
        external
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
    {
        if (minHealthFactor < PERCENTAGE_FACTOR) {
            revert CustomHealthFactorTooLowException();
        }

        CollateralDebtData memory collateralDebtData = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            minHealthFactor: minHealthFactor,
            collateralHints: collateralHints,
            enabledTokensMask: enabledTokensMask,
            task: CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY
        });

        if (collateralDebtData.isLiquidatable) {
            revert NotEnoughCollateralException();
        }

        _saveEnabledTokensMask(creditAccount, collateralDebtData.enabledTokensMask);
    }

    /// @dev Calculates total value for provided Credit Account in underlying
    /// More: https://dev.gearbox.fi/developers/credit/economy#totalUSD-value
    ///
    /// @param creditAccount Credit Account address
    // @return total Total value in underlying
    // @return twv Total weighted (discounted by liquidation thresholds) value in underlying
    function calcDebtAndCollateral(address creditAccount, CollateralCalcTask task)
        external
        view
        override
        returns (CollateralDebtData memory collateralDebtData)
    {
        uint256[] memory collateralHints;

        collateralDebtData = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMaskOf(creditAccount),
            collateralHints: collateralHints,
            minHealthFactor: PERCENTAGE_FACTOR,
            task: task
        });
    }

    function _calcDebtAndCollateral(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256[] memory collateralHints,
        uint16 minHealthFactor,
        CollateralCalcTask task
    ) internal view returns (CollateralDebtData memory collateralDebtData) {
        /// GET GENERIC PARAMS
        collateralDebtData.debt = creditAccountInfo[creditAccount].debt;
        collateralDebtData.cumulativeIndexLastUpdate = creditAccountInfo[creditAccount].cumulativeIndexLastUpdate;
        collateralDebtData.cumulativeIndexNow = _poolCumulativeIndexNow();

        if (task != CollateralCalcTask.GENERIC_PARAMS) {
            /// COMPUTE DEBT PARAMS
            collateralDebtData.enabledTokensMask = enabledTokensMask;

            if (supportsQuotas) {
                collateralDebtData.cumulativeQuotaInterest =
                    creditAccountInfo[creditAccount].cumulativeQuotaInterest - 1;
                collateralDebtData.quotedTokenMask = quotedTokenMask & collateralDebtData.enabledTokensMask;
                collateralDebtData._poolQuotaKeeper = address(poolQuotaKeeper());

                (
                    collateralDebtData.quotedTokens,
                    collateralDebtData.cumulativeQuotaInterest,
                    collateralDebtData.quotas,
                    collateralDebtData.quotedLts
                ) = _getQuotaTokenData({
                    creditAccount: creditAccount,
                    enabledTokensMask: enabledTokensMask,
                    _poolQuotaKeeper: collateralDebtData._poolQuotaKeeper
                });
            }

            (collateralDebtData.accruedInterest, collateralDebtData.accruedFees) =
                collateralDebtData.calcAccruedInterestAndFees({feeInterest: feeInterest});

            if (task != CollateralCalcTask.DEBT_ONLY) {
                /// Computes collateral. If task == FULL_COLLATERAL_CHECK_LAZY, until it finds enough collateral
                collateralDebtData._priceOracle = priceOracle;
                collateralDebtData.totalDebtUSD = _convertToUSD(
                    collateralDebtData._priceOracle,
                    collateralDebtData.calcTotalDebt(), // F: [CM-42]
                    underlying
                );

                uint256 tokensToDisable;
                (collateralDebtData.totalValueUSD, collateralDebtData.twvUSD, tokensToDisable) = collateralDebtData
                    .calcCollateral({
                    creditAccount: creditAccount,
                    underlying: underlying,
                    lazy: task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY,
                    minHealthFactor: minHealthFactor,
                    collateralHints: collateralHints,
                    collateralTokensByMaskFn: _collateralTokensByMask,
                    convertToUSDFn: _convertToUSD
                });

                collateralDebtData.enabledTokensMask = collateralDebtData.enabledTokensMask.disable(tokensToDisable);
                collateralDebtData.isLiquidatable = collateralDebtData.twvUSD < collateralDebtData.totalDebtUSD;

                if (task != CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY) {
                    // If there is not fullCoolaralCheck calc, than it adds some useful pararms
                    collateralDebtData.hf =
                        uint16(collateralDebtData.twvUSD * PERCENTAGE_FACTOR / collateralDebtData.totalDebtUSD);
                    collateralDebtData.totalValue =
                        _convertFromUSD(collateralDebtData._priceOracle, collateralDebtData.totalValueUSD, underlying); // F:[FA-41]

                    if (
                        (task != CollateralCalcTask.DEBT_COLLATERAL_WITHOUT_WITHDRAWALS)
                            && _hasWithdrawals(creditAccount)
                    ) {
                        collateralDebtData.totalValueUSD += addCancellableWithdrawalsValue({
                            collateralDebtData: collateralDebtData,
                            creditAccount: creditAccount,
                            isForceCancel: task == CollateralCalcTask.DEBT_COLLATERAL_FORCE_CANCEL_WITHDRAWALS
                        });
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
    /// @param token Address of quoted token
    /// @param quotaChange Change in quota in SIGNED format
    function updateQuota(address creditAccount, address token, int96 quotaChange)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        (uint256 caInterestChange, bool enable, bool disable) =
            poolQuotaKeeper().updateQuota({creditAccount: creditAccount, token: token, quotaChange: quotaChange}); // F: [CMQ-3]

        if (enable) {
            tokensToEnable = getTokenMaskOrRevert(token);
        } else if (disable) {
            tokensToDisable = getTokenMaskOrRevert(token);
        }

        creditAccountInfo[creditAccount].cumulativeQuotaInterest += caInterestChange; // F: [CMQ-3]
    }

    //
    // INTERNAL HELPERS
    //

    /// @dev Transfers all enabled assets from a Credit Account to the "to" address
    /// @param creditAccount Credit Account to transfer assets from
    /// @param to Recipient address
    /// @param convertToETH Whether WETH must be converted to ETH before sending
    /// @param tokensToTransferMask A bit mask encoding tokens to be transfered. All of the tokens included
    ///        in the mask will be transferred. If any tokens need to be skipped, they must be
    ///        excluded from the mask beforehand.
    function _batchTokensTransfer(address creditAccount, address to, bool convertToETH, uint256 tokensToTransferMask)
        internal
    {
        // Since tokensToTransferMask encodes all enabled tokens as 1, tokenMask > enabledTokensMask is equivalent
        // to the last 1 bit being passed. The loop can be ended at this point
        unchecked {
            for (uint256 tokenMask = 1; tokenMask <= tokensToTransferMask; tokenMask = tokenMask << 1) {
                // enabledTokensMask & tokenMask == tokenMask when the token is enabled, and 0 otherwise
                if (tokensToTransferMask & tokenMask != 0) {
                    address token = getTokenByMask(tokenMask); // F:[CM-44]
                    uint256 amount = IERC20Helper.balanceOf({token: token, holder: creditAccount}); // F:[CM-44]
                    if (amount > 1) {
                        // 1 is subtracted from amount to leave a non-zero value in the balance mapping, optimizing future writes
                        // Since the amount is checked to be more than 1, the block can be marked as unchecked
                        _safeTokenTransfer({
                            creditAccount: creditAccount,
                            token: token,
                            to: to,
                            amount: amount - 1,
                            convertToETH: convertToETH
                        }); // F:[CM-44]
                    }
                }
            }
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
        if (convertToETH && token == weth) {
            ICreditAccount(creditAccount).transfer({token: token, to: wethGateway, amount: amount}); // F:[CM-45]
            IWETHGateway(wethGateway).depositFor({to: to, amount: amount}); // F:[CM-45]
        } else {
            try ICreditAccount(creditAccount).safeTransfer({token: token, to: to, amount: amount}) { // F:[CM-45]
            } catch {
                uint256 delivered = ICreditAccount(creditAccount).transferDeliveredBalanceControl({
                    token: token,
                    to: withdrawalManager,
                    amount: amount
                });
                /// what `account` is ?
                IWithdrawalManager(withdrawalManager).addImmediateWithdrawal({
                    account: to,
                    token: token,
                    amount: delivered
                });
            }
        }
    }

    function _checkEnabledTokenLength(uint256 enabledTokensMask) internal view {
        if (enabledTokensMask.calcEnabledTokens() > maxEnabledTokens) {
            revert TooManyEnabledTokensException();
        }
    }

    function _poolCumulativeIndexNow() internal view returns (uint256) {
        return IPoolBase(pool).calcLinearCumulative_RAY();
    }

    function _poolRepayCreditAccount(uint256 debt, uint256 profit, uint256 loss) internal {
        IPoolBase(pool).repayCreditAccount(debt, profit, loss);
    }

    //
    // GETTERS
    //

    /// @dev Returns the collateral token with requested mask and its liquidationThreshold
    /// @param tokenMask Token mask corresponding to the token

    // TODO: naming!
    function collateralTokensByMask(uint256 tokenMask)
        public
        view
        override
        returns (address token, uint16 liquidationThreshold)
    {
        return _collateralTokensByMask({tokenMask: tokenMask, calcLT: true});
    }

    function getTokenByMask(uint256 tokenMask) public view override returns (address token) {
        (token,) = _collateralTokensByMask({tokenMask: tokenMask, calcLT: false});
    }

    /// @dev Returns the collateral token with requested mask and its liquidationThreshold
    /// @param tokenMask Token mask corresponding to the token
    function _collateralTokensByMask(uint256 tokenMask, bool calcLT)
        internal
        view
        returns (address token, uint16 liquidationThreshold)
    {
        // The underlying is a special case and its mask is always 1
        if (tokenMask == 1) {
            token = underlying; // F:[CM-47]
            liquidationThreshold = ltUnderlying;
        } else {
            CollateralTokenData storage tokenData = collateralTokensData[tokenMask]; // F:[CM-47]
            token = tokenData.getTokenOrRevert();

            if (calcLT) {
                liquidationThreshold = tokenData.getLiquidationThreshold();
            }
        }
    }

    /// @dev Returns the address of a borrower's Credit Account, or reverts if there is none.
    /// @param borrower Borrower's address
    function getBorrowerOrRevert(address creditAccount) public view override returns (address borrower) {
        borrower = creditAccountInfo[creditAccount].borrower; // F:[CM-48]
        if (borrower == address(0)) revert CreditAccountNotExistsException(); // F:[CM-48]
    }

    /// @dev Returns the liquidation threshold for the provided token
    /// @param token Token to retrieve the LT for
    function liquidationThresholds(address token) public view override returns (uint16 lt) {
        uint256 tokenMask = getTokenMaskOrRevert(token);
        (, lt) = _collateralTokensByMask({tokenMask: tokenMask, calcLT: true}); // F:[CM-47]
    }

    /// @dev Returns the mask for the provided token
    /// @param token Token to returns the mask for
    function getTokenMaskOrRevert(address token) public view override returns (uint256 tokenMask) {
        tokenMask = (token == underlying) ? 1 : tokenMasksMapInternal[token];
        if (tokenMask == 0) revert TokenNotAllowedException();
    }

    /// @dev Returns the fee parameters of the Credit Manager
    /// @return _feeInterest Percentage of interest taken by the protocol as profit
    /// @return _feeLiquidation Percentage of account value taken by the protocol as profit
    ///         during unhealthy account liquidations
    /// @return _liquidationDiscount Multiplier that reduces the effective totalValue during unhealthy account liquidations,
    ///         allowing the liquidator to take the unaccounted for remainder as premium. Equal to (1 - liquidationPremium)
    /// @return _feeLiquidationExpired Percentage of account value taken by the protocol as profit
    ///         during expired account liquidations
    /// @return _liquidationDiscountExpired Multiplier that reduces the effective totalValue during expired account liquidations,
    ///         allowing the liquidator to take the unaccounted for remainder as premium. Equal to (1 - liquidationPremiumExpired)
    function fees()
        external
        view
        override
        returns (
            uint16 _feeInterest,
            uint16 _feeLiquidation,
            uint16 _liquidationDiscount,
            uint16 _feeLiquidationExpired,
            uint16 _liquidationDiscountExpired
        )
    {
        _feeInterest = feeInterest; // F:[CM-51]
        _feeLiquidation = feeLiquidation; // F:[CM-51]
        _liquidationDiscount = liquidationDiscount; // F:[CM-51]
        _feeLiquidationExpired = feeLiquidationExpired; // F:[CM-51]
        _liquidationDiscountExpired = liquidationDiscountExpired; // F:[CM-51]
    }

    /// @dev Address of the connected pool
    /// @notice [DEPRECATED]: use pool() instead.
    function poolService() external view returns (address) {
        return address(pool);
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
        creditConfiguratorOnly // U:[CM-4]
    {
        _addToken(token); // F:[CM-52]
    }

    /// @dev IMPLEMENTATION: addToken
    /// @param token Address of the token to add
    function _addToken(address token) internal {
        // Checks that the token is not already known (has an associated token mask)
        if (tokenMasksMapInternal[token] != 0) {
            revert TokenAlreadyAddedException();
        } // F:[CM-52]

        // Checks that there aren't too many tokens
        // Since token masks are 255 bit numbers with each bit corresponding to 1 token,
        // only at most 255 are supported
        if (collateralTokensCount >= 255) revert TooManyTokensException(); // F:[CM-52]

        // The tokenMask of a token is a bit mask with 1 at position corresponding to its index
        // (i.e. 2 ** index or 1 << index)
        uint256 tokenMask = 1 << collateralTokensCount;
        tokenMasksMapInternal[token] = tokenMask; // F:[CM-53]

        collateralTokensData[tokenMask].token = token;
        collateralTokensData[tokenMask].timestampRampStart = type(uint40).max; // F:[CM-47]

        ++collateralTokensCount; // F:[CM-47]
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
    function setFees(
        uint16 _feeInterest,
        uint16 _feeLiquidation,
        uint16 _liquidationDiscount,
        uint16 _feeLiquidationExpired,
        uint16 _liquidationDiscountExpired
    )
        external
        creditConfiguratorOnly // U:[CM-4]
    {
        feeInterest = _feeInterest; // F:[CM-51]
        feeLiquidation = _feeLiquidation; // F:[CM-51]
        liquidationDiscount = _liquidationDiscount; // F:[CM-51]
        feeLiquidationExpired = _feeLiquidationExpired; // F:[CM-51]
        liquidationDiscountExpired = _liquidationDiscountExpired; // F:[CM-51]
    }

    /// @dev Sets ramping parameters for a token's liquidation threshold
    /// @notice Ramping parameters allow to decrease the LT gradually over a period of time
    ///         which gives users/bots time to react and adjust their position for the new LT
    /// @param token The collateral token to set the LT for
    /// @param finalLT The final LT after ramping
    /// @param timestampRampStart Timestamp when the LT starts ramping
    /// @param rampDuration Duration of ramping
    function setCollateralTokenData(
        address token,
        uint16 initialLT,
        uint16 finalLT,
        uint40 timestampRampStart,
        uint24 rampDuration
    )
        external
        creditConfiguratorOnly // U:[CM-4]
    {
        if (token == underlying) {
            ltUnderlying = initialLT; // F:[CM-47]
        } else {
            uint256 tokenMask = getTokenMaskOrRevert(token);
            CollateralTokenData storage tokenData = collateralTokensData[tokenMask];

            tokenData.ltInitial = initialLT;
            tokenData.ltFinal = finalLT;
            tokenData.timestampRampStart = timestampRampStart;
            tokenData.rampDuration = rampDuration;
        }
    }

    /// @dev Sets the limited token mask
    /// @param _quotedTokenMask The new mask
    /// @notice Limited tokens are counted as collateral not based on their balances,
    ///         but instead based on their quotas set in the poolQuotaKeeper contract
    ///         Tokens in the mask also incur additional interest based on their quotas
    function setQuotedMask(uint256 _quotedTokenMask)
        external
        creditConfiguratorOnly // U:[CM-4]
    {
        quotedTokenMask = _quotedTokenMask; // F: [CMQ-2]
    }

    /// @dev Sets the maximal number of enabled tokens on a single Credit Account.
    /// @param _maxEnabledTokens The new enabled token quantity limit.
    function setMaxEnabledTokens(uint8 _maxEnabledTokens)
        external
        creditConfiguratorOnly // U: [CM-4]
    {
        maxEnabledTokens = _maxEnabledTokens; // F: [CC-37]
    }

    /// @dev Sets the link between an adapter and its corresponding targetContract
    /// @param adapter Address of the adapter to be used to access the target contract
    /// @param targetContract A 3rd-party contract for which the adapter is set
    /// @notice The function can be called with (adapter, address(0)) and (address(0), targetContract)
    ///         to disallow a particular target or adapter, since this would set values in respective
    ///         mappings to address(0).
    function setContractAllowance(address adapter, address targetContract)
        external
        creditConfiguratorOnly // U: [CM-4]
    {
        if (targetContract == address(this) || adapter == address(this)) {
            revert TargetContractNotAllowedException();
        } // F:[CC-13]

        if (adapter != address(0)) {
            adapterToContract[adapter] = targetContract; // F:[CM-56]
        }
        if (targetContract != address(0)) {
            contractToAdapter[targetContract] = adapter; // F:[CM-56]
        }
    }

    /// @dev Sets the Credit Facade
    /// @param _creditFacade Address of the new Credit Facade
    function setCreditFacade(address _creditFacade)
        external
        creditConfiguratorOnly // U: [CM-4]
    {
        creditFacade = _creditFacade;
    }

    /// @dev Sets the Price Oracle
    /// @param _priceOracle Address of the new Price Oracle
    function setPriceOracle(address _priceOracle)
        external
        creditConfiguratorOnly // U: [CM-4]
    {
        priceOracle = _priceOracle;
    }

    /// @dev Sets a new Credit Configurator
    /// @param _creditConfigurator Address of the new Credit Configurator
    function setCreditConfigurator(address _creditConfigurator)
        external
        creditConfiguratorOnly // U: [CM-4]
    {
        creditConfigurator = _creditConfigurator; // F:[CM-58]
        emit SetCreditConfigurator(_creditConfigurator); // F:[CM-58]
    }

    /// ----------- ///
    /// WITHDRAWALS ///
    /// ----------- ///

    /// @inheritdoc ICreditManagerV3
    function scheduleWithdrawal(address creditAccount, address token, uint256 amount)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 tokensToDisable)
    {
        uint256 tokenMask = getTokenMaskOrRevert({token: token});

        if (IWithdrawalManager(withdrawalManager).delay() == 0) {
            address borrower = getBorrowerOrRevert({creditAccount: creditAccount});
            _safeTokenTransfer({
                creditAccount: creditAccount,
                token: token,
                to: borrower,
                amount: amount,
                convertToETH: false
            });
        } else {
            uint256 delivered =
                ICreditAccount(creditAccount).transferDeliveredBalanceControl(token, withdrawalManager, amount);

            IWithdrawalManager(withdrawalManager).addScheduledWithdrawal(
                creditAccount, token, delivered, tokenMask.calcIndex()
            );
            // enables withdrawal flag
            _enableFlag({creditAccount: creditAccount, flag: WITHDRAWAL_FLAG});
        }

        if (IERC20Helper.balanceOf({token: token, holder: creditAccount}) <= 1) {
            tokensToDisable = tokenMask;
        }
    }

    /// @inheritdoc ICreditManagerV3
    function claimWithdrawals(address creditAccount, address to, ClaimAction action)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 tokensToEnable)
    {
        if (_hasWithdrawals(creditAccount)) {
            bool hasScheduled;

            (hasScheduled, tokensToEnable) =
                IWithdrawalManager(withdrawalManager).claimScheduledWithdrawals(creditAccount, to, action);
            if (!hasScheduled) {
                // disables withdrawal flag
                _disableFlag(creditAccount, WITHDRAWAL_FLAG);
            }
        }
    }

    function addCancellableWithdrawalsValue(
        CollateralDebtData memory collateralDebtData,
        address creditAccount,
        bool isForceCancel
    ) internal view returns (uint256 totalValueUSD) {
        (address token1, uint256 amount1, address token2, uint256 amount2) =
            IWithdrawalManager(withdrawalManager).cancellableScheduledWithdrawals(creditAccount, isForceCancel);

        if (amount1 != 0) {
            totalValueUSD = _convertToUSD(collateralDebtData._priceOracle, amount1, token1);
        }
        if (amount2 != 0) {
            totalValueUSD += _convertToUSD(collateralDebtData._priceOracle, amount2, token2);
        }
    }

    function _hasWithdrawals(address creditAccount) internal view returns (bool) {
        return creditAccountInfo[creditAccount].flags & WITHDRAWAL_FLAG != 0;
    }

    /// @notice Revokes allowances for specified spender/token pairs
    /// @param revocations Spender/token pairs to revoke allowances for
    function revokeAdapterAllowances(address creditAccount, RevocationPair[] calldata revocations)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
    {
        uint256 numRevocations = revocations.length;
        unchecked {
            for (uint256 i; i < numRevocations; ++i) {
                address spender = revocations[i].spender;
                address token = revocations[i].token;

                if (spender == address(0) || token == address(0)) {
                    revert ZeroAddressException();
                }
                uint256 allowance = IERC20(token).allowance(creditAccount, spender);
                /// It checks that token is in collateral token list in _approveSpender function
                if (allowance > 1) {
                    _approveSpender({creditAccount: creditAccount, token: token, spender: spender, amount: 0});
                }
            }
        }
    }

    ///
    function setCreditAccountForExternalCall(address creditAccount)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
    {
        _externalCallCreditAccount = creditAccount;
    }

    function getExternalCallCreditAccountOrRevert() public view override returns (address creditAccount) {
        creditAccount = _externalCallCreditAccount;
        if (creditAccount == address(1)) revert ExternalCallCreditAccountNotSetException();
    }

    function enabledTokensMaskOf(address creditAccount) public view override returns (uint256) {
        return creditAccountInfo[creditAccount].enabledTokensMask;
    }

    function flagsOf(address creditAccount) external view override returns (uint16) {
        return creditAccountInfo[creditAccount].flags;
    }

    function setFlagFor(address creditAccount, uint16 flag, bool value)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
    {
        if (value) {
            _enableFlag(creditAccount, flag);
        } else {
            _disableFlag(creditAccount, flag);
        }
    }

    function _enableFlag(address creditAccount, uint16 flag) internal {
        creditAccountInfo[creditAccount].flags |= flag;
    }

    function _disableFlag(address creditAccount, uint16 flag) internal {
        creditAccountInfo[creditAccount].flags &= ~flag;
    }

    function _saveEnabledTokensMask(address creditAccount, uint256 enabledTokensMask) internal {
        _checkEnabledTokenLength(enabledTokensMask);
        creditAccountInfo[creditAccount].enabledTokensMask = enabledTokensMask;
    }

    ///
    /// FEE TOKEN SUPPORT
    ///

    function _amountWithFee(uint256 amount) internal view virtual returns (uint256) {
        return amount;
    }

    function _amountMinusFee(uint256 amount) internal view virtual returns (uint256) {
        return amount;
    }

    // CREDIT ACCOUNTS
    function creditAccounts() external view returns (address[] memory) {
        return creditAccountsSet.values();
    }

    function _getQuotaAndOutstandingInterest(address _poolQuotaKeeper, address creditAccount, address token)
        internal
        view
        returns (uint256 quoted, uint256 outstandingInterest)
    {
        return IPoolQuotaKeeper(_poolQuotaKeeper).getQuotaAndInterest(creditAccount, token);
    }

    function _convertToUSD(address _priceOracle, uint256 amountInToken, address token)
        internal
        view
        returns (uint256 amountInUSD)
    {
        amountInUSD = IPriceOracleV2(_priceOracle).convertToUSD(amountInToken, token);
    }

    function _convertFromUSD(address _priceOracle, uint256 amountInUSD, address token)
        internal
        view
        returns (uint256 amountInToken)
    {
        amountInToken = IPriceOracleV2(_priceOracle).convertFromUSD(amountInUSD, token);
    }

    function _getQuotaTokenData(address creditAccount, uint256 enabledTokensMask, address _poolQuotaKeeper)
        internal
        view
        returns (
            address[] memory quotaTokens,
            uint256 outstandingQuotaInterest,
            uint256[] memory quotas,
            uint16[] memory lts
        )
    {
        uint256 j;
        uint256 _maxEnabledTokens = maxEnabledTokens;

        uint256 quotedMask = enabledTokensMask & quotedTokenMask;
        quotaTokens = new address[](_maxEnabledTokens);
        quotas = new uint256[](_maxEnabledTokens);
        lts = new uint16[](_maxEnabledTokens);

        unchecked {
            for (uint256 tokenMask = 2; tokenMask <= quotedMask; tokenMask <<= 1) {
                if (quotedMask & tokenMask != 0) {
                    address token;
                    (token, lts[j]) = _collateralTokensByMask(tokenMask, true);

                    quotaTokens[j] = token;

                    uint256 outstandingInterestDelta;
                    (quotas[j], outstandingInterestDelta) =
                        _getQuotaAndOutstandingInterest(_poolQuotaKeeper, creditAccount, token);

                    // Safe because quotaInterest =  (quota is uint96) * APY * time, so even with 1000% APY, it will take 10**10 years for overflow
                    outstandingQuotaInterest += outstandingInterestDelta;

                    ++j;

                    if (j >= _maxEnabledTokens) {
                        revert TooManyEnabledTokensException();
                    }
                }
            }
        }
    }
}
