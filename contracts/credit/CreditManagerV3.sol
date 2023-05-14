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

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
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
contract CreditManagerV3 is ICreditManagerV3, SanityCheckTrait, ReentrancyGuard {
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
    address public immutable override wethAddress;

    /// @dev Address of WETH Gateway
    address public immutable wethGateway;

    /// @dev Whether the CM supports quota-related logic
    bool public immutable override supportsQuotas;

    TakeAccountAction private immutable deployAccountAction;

    /// @dev The maximal number of enabled tokens on a single Credit Account
    uint8 public override maxAllowedEnabledTokenLength = 12;

    /// @dev Address of the connected Credit Facade
    address public override creditFacade;

    /// @dev Points to creditAccount during multicall, otherwise keeps address(1) for gas savings
    /// CreditFacade is trusted source, so primarly it sends creditAccount as parameter
    /// _externalCallCreditAccount is used for adapters interation when adapter calls approve / execute methods
    address internal _externalCallCreditAccount;

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

    /// @dev Liquidation threshold for the underlying token.
    uint16 internal ltUnderlying;

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

    /// @dev Total number of known collateral tokens.
    uint8 public collateralTokensCount;

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
        if (msg.sender != creditFacade) revert CallerNotCreditFacadeException();
        _;
    }

    /// @dev Restricts calls to Withdrawal Manager only
    modifier withdrawalManagerOnly() {
        if (msg.sender != address(withdrawalManager)) revert CallerNotWithdrawalManagerException();
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
    constructor(address _addressProvider, address _pool) {
        addressProvider = _addressProvider;
        pool = _pool; // F:[CM-1]

        underlying = IPoolBase(pool).underlyingToken(); // F:[CM-1]

        try IPool4626(_pool).supportsQuotas() returns (bool sq) {
            supportsQuotas = sq;
        } catch {}

        // The underlying is the first token added as collateral
        _addToken(underlying); // F:[CM-1]

        wethAddress = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_WETH_TOKEN, NO_VERSION_CONTROL); // F:[CM-1]
        wethGateway = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_WETH_GATEWAY, 3_00); // F:[CM-1]
        priceOracle = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_PRICE_ORACLE, 2); // F:[CM-1]
        accountFactory = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_ACCOUNT_FACTORY, 1); // F:[CM-1]
        withdrawalManager = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_WITHDRAWAL_MANAGER, 3_00);

        deployAccountAction = IAccountFactory(accountFactory).version() == 3_00
            ? TakeAccountAction.DEPLOY_NEW_ONE
            : TakeAccountAction.TAKE_USED_ONE;
        creditConfigurator = msg.sender; // F:[CM-1]

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
        nonReentrant
        creditFacadeOnly // F:[CM-2]
        returns (address creditAccount)
    {
        // Takes a Credit Account from the factory and sets initial parameters
        // The Credit Account will be connected to this Credit Manager until closing
        creditAccount = IAccountFactory(accountFactory).takeCreditAccount(
            uint256(deployNew ? deployAccountAction : TakeAccountAction.TAKE_USED_ONE), 0
        ); // F:[CM-8]

        creditAccountInfo[creditAccount].debt = debt;
        creditAccountInfo[creditAccount].cumulativeIndexLastUpdate = IPoolBase(pool).calcLinearCumulative_RAY();
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
    /// - If convertWETH is true, the function converts WETH into ETH before sending
    /// - Returns the Credit Account back to factory
    ///
    /// @param creditAccount Credit account address
    /// @param closureAction Whether the account is closed, liquidated or liquidated due to expiry
    // @param totalValue Portfolio value for liqution, 0 for ordinary closure
    /// @param payer Address which would be charged if credit account has not enough funds to cover amountToPool
    /// @param to Address to which the leftover funds will be sent
    /// @param skipTokensMask Tokenmask contains 1 for tokens which needed to be send directly
    /// @param convertWETH If true converts WETH to ETH
    function closeCreditAccount(
        address creditAccount,
        ClosureAction closureAction,
        CollateralDebtData memory collateralDebtData,
        address payer,
        address to,
        uint256 skipTokensMask,
        bool convertWETH
    )
        external
        override
        nonReentrant
        creditFacadeOnly // F:[CM-2]
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
            uint256 underlyingBalance = IERC20Helper.balanceOf(underlying, creditAccount);

            if (underlyingBalance > amountToPool + remainingFunds + 1) {
                // If there is an underlying surplus, transfers it to the "to" address
                unchecked {
                    _safeTokenTransfer(
                        creditAccount,
                        underlying,
                        to,
                        underlyingBalance - amountToPool - remainingFunds - 1,
                        convertWETH
                    ); // F:[CM-10,12,16]
                }
            } else if (underlyingBalance < amountToPool + remainingFunds + 1) {
                // If there is an underlying shortfall, attempts to transfer it from the payer
                unchecked {
                    IERC20(underlying).safeTransferFrom(
                        payer, creditAccount, _amountWithFee(amountToPool + remainingFunds - underlyingBalance + 1)
                    ); // F:[CM-11,13]
                }
            }
        }

        // Transfers the due funds to the pool
        ICreditAccount(creditAccount).transfer(underlying, pool, amountToPool); // F:[CM-10,11,12,13]

        // Signals to the pool that debt has been repaid. The pool relies
        // on the Credit Manager to repay the debt correctly, and does not
        // check internally whether the underlying was actually transferred
        IPoolBase(pool).repayCreditAccount(collateralDebtData.debt, profit, loss); // F:[CM-10,11,12,13]

        // transfer remaining funds to the borrower [liquidations only]
        if (remainingFunds > 1) {
            _safeTokenTransfer(creditAccount, underlying, borrower, remainingFunds, false); // F:[CM-13,18]
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

        uint256 enabledTokensMask = collateralDebtData.enabledTokensMask.disable(skipTokensMask);

        _transferAssetsTo(creditAccount, to, convertWETH, enabledTokensMask); // F:[CM-14,17,19]

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
        nonReentrant
        creditFacadeOnly // F:[CM-2]
        returns (uint256 newDebt, uint256 tokensToEnable, uint256 tokensToDisable)
    {
        CollateralDebtData memory collateralDebtData;

        uint256 newCumulativeIndex;
        if (action == ManageDebtAction.INCREASE_DEBT) {
            _setDebtAndCumulativeIndex({collateralDebtData: collateralDebtData, creditAccount: creditAccount});
            (newDebt, newCumulativeIndex) = collateralDebtData.calcIncrease(amount);

            // Requests the pool to lend additional funds to the Credit Account
            IPoolBase(pool).lendCreditAccount(amount, creditAccount); // F:[CM-20]
            tokensToEnable = UNDERLYING_TOKEN_MASK;
        } else {
            // Decrease
            collateralDebtData.enabledTokensMask = enabledTokensMask;

            _calcDebtAndQuotedCollateral({
                collateralDebtData: collateralDebtData,
                creditAccount: creditAccount,
                countQuotedCollateral: false
            });

            if (supportsQuotas) {
                IPoolQuotaKeeper(collateralDebtData._poolQuotaKeeper).accrueQuotaInterest(
                    creditAccount, collateralDebtData.quotedTokens
                ); // F: [CMQ-4,5]
            }

            // Pays the amount back to the pool
            ICreditAccount(creditAccount).transfer(underlying, pool, amount); // F:[CM-21]
            {
                uint256 amountToRepay;
                uint256 profit;

                (newDebt, newCumulativeIndex, amountToRepay, profit) =
                    collateralDebtData.calcDescrease({amount: amount, feeInterest: feeInterest});

                IPoolBase(pool).repayCreditAccount(amountToRepay, profit, 0); // F:[CM-21]
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
        creditFacadeOnly // F:[CM-2]
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
        nonReentrant
        creditFacadeOnly // F:[CM-2]
    {
        getBorrowerOrRevert(creditAccount);
        creditAccountInfo[creditAccount].borrower = to; // F:[CM-7]
    }

    /// @dev Requests the Credit Account to approve a collateral token to another contract.
    /// @param token Collateral token to approve
    /// @param amount New allowance amount
    function approveCreditAccount(address token, uint256 amount) external override nonReentrant {
        address targetContract = _getTargetContractOrRevert();
        _approveSpender(token, targetContract, externalCallCreditAccountOrRevert(), amount);
    }

    function _approveSpender(address token, address targetContract, address creditAccount, uint256 amount) internal {
        // Checks that the token is a collateral token
        // Forbidden tokens can be approved, since users need that to
        // sell them off
        getTokenMaskOrRevert(token);

        ICreditAccount(creditAccount).safeApprove(token, targetContract, amount);
    }

    /// @dev Requests a Credit Account to make a low-level call with provided data
    /// This is the intended pathway for state-changing interactions with 3rd-party protocols
    /// @param data Data to pass with the call
    function executeOrder(bytes memory data) external override nonReentrant returns (bytes memory) {
        address targetContract = _getTargetContractOrRevert();
        // Emits an event
        emit ExecuteOrder(targetContract); // F:[CM-29]

        // Returned data is provided as-is to the caller;
        // It is expected that is is parsed and returned as a correct type
        // by the adapter itself.
        return ICreditAccount(externalCallCreditAccountOrRevert()).execute(targetContract, data); // F:[CM-29]
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
    ) external creditFacadeOnly nonReentrant {
        if (minHealthFactor < PERCENTAGE_FACTOR) {
            revert CustomHealthFactorTooLowException();
        }

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.enabledTokensMask = enabledTokensMask;
        collateralDebtData._priceOracle = priceOracle;

        _calcFullCollateral(collateralDebtData, creditAccount, minHealthFactor, collateralHints, true);

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
        collateralDebtData.enabledTokensMask = enabledTokensMaskOf(creditAccount);

        if (task == CollateralCalcTask.DEBT_ONLY) {
            _calcDebtAndQuotedCollateral({
                collateralDebtData: collateralDebtData,
                creditAccount: creditAccount,
                countQuotedCollateral: false
            });
        } else {
            address _priceOracle = priceOracle;
            uint256[] memory collateralHints;

            collateralDebtData._priceOracle = priceOracle;

            _calcFullCollateral({
                collateralDebtData: collateralDebtData,
                creditAccount: creditAccount,
                minHealthFactor: PERCENTAGE_FACTOR,
                collateralHints: collateralHints,
                lazy: false
            });
            collateralDebtData.calcHealthFactor();

            if (
                task == CollateralCalcTask.DEBT_COLLATERAL_CANCEL_WITHDRAWALS
                    || task == CollateralCalcTask.DEBT_COLLATERAL_FORCE_CANCEL_WITHDRAWALS
            ) {
                _calcAndUpdateCancellableWithdrawalsValue({
                    collateralDebtData: collateralDebtData,
                    creditAccount: creditAccount,
                    isForceCancel: task == CollateralCalcTask.DEBT_COLLATERAL_FORCE_CANCEL_WITHDRAWALS
                });
            }

            collateralDebtData.totalValue =
                IPriceOracleV2(_priceOracle).convertFromUSD(collateralDebtData.totalValueUSD, underlying); // F:[FA-41]
        }
    }

    /// @dev Calculates total value for provided Credit Account in USD
    // @param _priceOracle Oracle used to convert assets to USD
    // @param creditAccount Address of the Credit Account

    function _calcFullCollateral(
        CollateralDebtData memory collateralDebtData,
        address creditAccount,
        uint16 minHealthFactor,
        uint256[] memory collateralHints,
        bool lazy
    ) internal view {
        _calcDebtAndQuotedCollateral({
            collateralDebtData: collateralDebtData,
            creditAccount: creditAccount,
            countQuotedCollateral: true
        });

        collateralDebtData.calcTotalDebtUSD(underlying);

        collateralDebtData.calcNonQuotedTokensCollateral({
            creditAccount: creditAccount,
            stopIfReachLimit: lazy,
            minHealthFactor: minHealthFactor,
            collateralHints: collateralHints,
            quotedTokenMask: supportsQuotas ? quotedTokenMask : 0,
            collateralTokensByMaskFn: collateralTokensByMask
        });

        collateralDebtData.isLiquidatable = collateralDebtData.twvUSD < collateralDebtData.totalDebtUSD;
    }

    function _calcDebtAndQuotedCollateral(
        CollateralDebtData memory collateralDebtData,
        address creditAccount,
        bool countQuotedCollateral
    ) internal view {
        // The total weighted value of a Credit Account has to be compared
        // with the entire debt sum, including interest and fees
        _setDebtAndCumulativeIndex({collateralDebtData: collateralDebtData, creditAccount: creditAccount});

        if (supportsQuotas) {
            collateralDebtData.cumulativeQuotaInterest = creditAccountInfo[creditAccount].cumulativeQuotaInterest - 1;
            collateralDebtData._poolQuotaKeeper = address(poolQuotaKeeper());

            collateralDebtData.calcQuotedTokensCollateral({
                creditAccount: creditAccount,
                quotedTokenMask: quotedTokenMask,
                maxAllowedEnabledTokenLength: maxAllowedEnabledTokenLength,
                underlying: underlying,
                collateralTokensByMaskFn: _collateralTokensByMask,
                countCollateral: countQuotedCollateral
            });
        }

        collateralDebtData.calcAccruedInterestAndFees({feeInterest: feeInterest});
    }
    //
    // QUOTAS MANAGEMENT
    //

    /// @dev Updates credit account's quotas for multiple tokens
    /// @param creditAccount Address of credit account
    function updateQuota(address creditAccount, address token, int96 quotaChange)
        external
        override
        creditFacadeOnly // F: [CMQ-3]
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        (uint256 caInterestChange, bool enable, bool disable) =
            poolQuotaKeeper().updateQuota(creditAccount, token, quotaChange); // F: [CMQ-3]

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
    /// @param convertWETH Whether WETH must be converted to ETH before sending
    /// @param enabledTokensMask A bit mask encoding enabled tokens. All of the tokens included
    ///        in the mask will be transferred. If any tokens need to be skipped, they must be
    ///        excluded from the mask beforehand.
    function _transferAssetsTo(address creditAccount, address to, bool convertWETH, uint256 enabledTokensMask)
        internal
    {
        // Since underlying should have been transferred to "to" before this function is called
        // (if there is a surplus), its tokenMask of 1 is skipped

        // Since enabledTokensMask encodes all enabled tokens as 1,
        // tokenMask > enabledTokensMask is equivalent to the last 1 bit being passed
        // The loop can be ended at this point
        unchecked {
            for (uint256 tokenMask = 2; tokenMask <= enabledTokensMask; tokenMask = tokenMask << 1) {
                // enabledTokensMask & tokenMask == tokenMask when the token is enabled,
                // and 0 otherwise
                if (enabledTokensMask & tokenMask != 0) {
                    address token = getTokenByMask(tokenMask); // F:[CM-44]
                    uint256 amount = IERC20Helper.balanceOf(token, creditAccount); // F:[CM-44]
                    if (amount > 1) {
                        // 1 is subtracted from amount to leave a non-zero value
                        // in the balance mapping, optimizing future writes
                        // Since the amount is checked to be more than 1,
                        // the block can be marked as unchecked

                        // F:[CM-44]
                        _safeTokenTransfer(creditAccount, token, to, amount - 1, convertWETH); // F:[CM-44]
                    }
                }
            }
            // The loop iterates by moving 1 bit to the left,
            // which corresponds to moving on to the next token
            // F:[CM-44]
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
            ICreditAccount(creditAccount).transfer(token, wethGateway, amount); // F:[CM-45]
            IWETHGateway(wethGateway).depositFor(to, amount); // F:[CM-45]
        } else {
            try ICreditAccount(creditAccount).safeTransfer(token, to, amount) { // F:[CM-45]
            } catch {
                uint256 delivered =
                    ICreditAccount(creditAccount).transferDeliveredBalanceControl(token, withdrawalManager, amount);
                IWithdrawalManager(withdrawalManager).addImmediateWithdrawal(to, token, delivered);
            }
        }
    }

    function _checkEnabledTokenLength(uint256 enabledTokensMask) internal view {
        uint256 totalTokensEnabled = enabledTokensMask.calcEnabledTokens();
        if (totalTokensEnabled > maxAllowedEnabledTokenLength) {
            revert TooManyEnabledTokensException();
        }
    }

    //
    // GETTERS
    //

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

    /// @dev Returns the parameters of the Credit Account required to calculate debt
    /// @param creditAccount Address of the Credit Account
    function _setDebtAndCumulativeIndex(CollateralDebtData memory collateralDebtData, address creditAccount)
        internal
        view
    {
        collateralDebtData.debt = creditAccountInfo[creditAccount].debt; // F:[CM-49,50]
        collateralDebtData.cumulativeIndexLastUpdate = creditAccountInfo[creditAccount].cumulativeIndexLastUpdate; // F:[CM-49,50]
        collateralDebtData.cumulativeIndexNow = IPoolBase(pool).calcLinearCumulative_RAY(); // F:[CM-49,50]
    }

    /// @dev Returns the liquidation threshold for the provided token
    /// @param token Token to retrieve the LT for
    function liquidationThresholds(address token) public view override returns (uint16 lt) {
        // Underlying is a special case and its LT is stored separately
        if (token == underlying) return ltUnderlying; // F:[CM-47]

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
        return IPoolQuotaKeeper(IPool4626(address(pool)).poolQuotaKeeper());
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
        feeInterest = _feeInterest; // F:[CM-51]
        feeLiquidation = _feeLiquidation; // F:[CM-51]
        liquidationDiscount = _liquidationDiscount; // F:[CM-51]
        feeLiquidationExpired = _feeLiquidationExpired; // F:[CM-51]
        liquidationDiscountExpired = _liquidationDiscountExpired; // F:[CM-51]
    }

    //
    // CONFIGURATION
    //

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
    ) external creditConfiguratorOnly {
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
        creditConfiguratorOnly // F: [CMQ-2]
    {
        quotedTokenMask = _quotedTokenMask; // F: [CMQ-2]
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
    function setContractAllowance(address adapter, address targetContract) external creditConfiguratorOnly {
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
        creditConfiguratorOnly // F:[CM-4]
    {
        creditFacade = _creditFacade;
    }

    /// @dev Sets the Price Oracle
    /// @param _priceOracle Address of the new Price Oracle
    function setPriceOracle(address _priceOracle)
        external
        creditConfiguratorOnly // F:[CM-4]
    {
        priceOracle = _priceOracle;
    }

    /// @dev Sets a new Credit Configurator
    /// @param _creditConfigurator Address of the new Credit Configurator
    function setCreditConfigurator(address _creditConfigurator)
        external
        creditConfiguratorOnly // F:[CM-4]
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
        creditFacadeOnly
        returns (uint256 tokensToDisable)
    {
        uint256 tokenMask = getTokenMaskOrRevert(token);

        if (IWithdrawalManager(withdrawalManager).delay() == 0) {
            address borrower = creditAccountInfo[creditAccount].borrower;
            _safeTokenTransfer(creditAccount, token, borrower, amount, false);
        } else {
            uint256 delivered =
                ICreditAccount(creditAccount).transferDeliveredBalanceControl(token, withdrawalManager, amount);

            IWithdrawalManager(withdrawalManager).addScheduledWithdrawal(
                creditAccount, token, delivered, tokenMask.calcIndex()
            );
            // enables withdrawal flag
            creditAccountInfo[creditAccount].flags |= WITHDRAWAL_FLAG;
        }

        if (IERC20Helper.balanceOf(token, creditAccount) <= 1) {
            tokensToDisable = tokenMask;
        }
    }

    /// @inheritdoc ICreditManagerV3
    function claimWithdrawals(address creditAccount, address to, ClaimAction action)
        external
        override
        creditFacadeOnly
        returns (uint256 tokensToEnable)
    {
        if (_hasWithdrawals(creditAccount)) {
            bool hasScheduled;

            (hasScheduled, tokensToEnable) =
                IWithdrawalManager(withdrawalManager).claimScheduledWithdrawals(creditAccount, to, action);
            if (!hasScheduled) {
                // disables withdrawal flag
                creditAccountInfo[creditAccount].flags &= ~WITHDRAWAL_FLAG;
            }
        }
    }

    function _hasWithdrawals(address creditAccount) internal view returns (bool) {
        return creditAccountInfo[creditAccount].flags & WITHDRAWAL_FLAG != 0;
    }

    function _calcAndUpdateCancellableWithdrawalsValue(
        CollateralDebtData memory collateralDebtData,
        address creditAccount,
        bool isForceCancel
    ) internal view {
        if (_hasWithdrawals(creditAccount)) {
            (address token1, uint256 amount1, address token2, uint256 amount2) =
                IWithdrawalManager(withdrawalManager).cancellableScheduledWithdrawals(creditAccount, isForceCancel);

            if (amount1 != 0) {
                _addTotalValueInUSDUAndEnableInPlace(collateralDebtData, token1, amount1);
            }
            if (amount2 != 0) {
                _addTotalValueInUSDUAndEnableInPlace(collateralDebtData, token2, amount2);
            }
        }
    }

    function _addTotalValueInUSDUAndEnableInPlace(
        CollateralDebtData memory collateralDebtData,
        address token,
        uint256 amount
    ) internal view {
        collateralDebtData.totalValueUSD += CreditLogic.convertToUSD(collateralDebtData._priceOracle, amount, token);
        collateralDebtData.enabledTokensMask = collateralDebtData.enabledTokensMask.enable(getTokenMaskOrRevert(token));
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
                uint256 allowance = IERC20(token).allowance(creditAccount, spender);
                /// It checks that token is in collateral token list in _approveSpender function
                if (allowance > 1) _approveSpender(token, spender, creditAccount, 0);
            }
        }
    }

    ///
    function setCreditAccountForExternalCall(address creditAccount) external override creditFacadeOnly {
        _externalCallCreditAccount = creditAccount;
    }

    function externalCallCreditAccountOrRevert() public view override returns (address creditAccount) {
        creditAccount = _externalCallCreditAccount;
        if (creditAccount == address(1)) revert ExternalCallCreditAccountNotSetException();
    }

    function enabledTokensMaskOf(address creditAccount) public view override returns (uint256) {
        return uint256(creditAccountInfo[creditAccount].enabledTokensMask);
    }

    function flagsOf(address creditAccount) external view override returns (uint16) {
        return creditAccountInfo[creditAccount].flags;
    }

    function setFlagFor(address creditAccount, uint16 flag, bool value) external override creditFacadeOnly {
        if (value) {
            creditAccountInfo[creditAccount].flags |= flag;
        } else {
            creditAccountInfo[creditAccount].flags &= ~flag;
        }
    }

    function _saveEnabledTokensMask(address creditAccount, uint256 enabledTokensMask) internal {
        if (enabledTokensMask > type(uint248).max) {
            revert IncorrectParameterException();
        }
        _checkEnabledTokenLength(enabledTokensMask);
        creditAccountInfo[creditAccount].enabledTokensMask = uint248(enabledTokensMask);
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
}
