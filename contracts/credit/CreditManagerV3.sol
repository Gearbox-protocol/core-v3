// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

// LIBRARIES
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

// LIBS & TRAITS
import {UNDERLYING_TOKEN_MASK, BitMask} from "../libraries/BitMask.sol";
import {CreditLogic} from "../libraries/CreditLogic.sol";
import {CollateralLogic} from "../libraries/CollateralLogic.sol";
import {CreditAccountHelper} from "../libraries/CreditAccountHelper.sol";

import {ReentrancyGuardTrait} from "../traits/ReentrancyGuardTrait.sol";
import {SanityCheckTrait} from "../traits/SanityCheckTrait.sol";

// INTERFACES
import {IAccountFactoryBase} from "../interfaces/IAccountFactoryV3.sol";
import {ICreditAccountBase} from "../interfaces/ICreditAccountV3.sol";
import {IPoolBase, IPoolV3} from "../interfaces/IPoolV3.sol";
import {ClaimAction, IWithdrawalManagerV3} from "../interfaces/IWithdrawalManagerV3.sol";
import {
    ICreditManagerV3,
    ClosureAction,
    CollateralTokenData,
    ManageDebtAction,
    CreditAccountInfo,
    RevocationPair,
    CollateralDebtData,
    CollateralCalcTask,
    WITHDRAWAL_FLAG,
    DEFAULT_MAX_ENABLED_TOKENS,
    INACTIVE_CREDIT_ACCOUNT_ADDRESS
} from "../interfaces/ICreditManagerV3.sol";
import "../interfaces/IAddressProviderV3.sol";
import {IPriceOracleBase} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracleBase.sol";
import {IPoolQuotaKeeperV3} from "../interfaces/IPoolQuotaKeeperV3.sol";

// CONSTANTS
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

/// @title Credit Manager
/// @dev Encapsulates the business logic for managing Credit Accounts
contract CreditManagerV3 is ICreditManagerV3, SanityCheckTrait, ReentrancyGuardTrait {
    using EnumerableSet for EnumerableSet.AddressSet;
    using BitMask for uint256;
    using CreditLogic for CollateralDebtData;
    using CollateralLogic for CollateralDebtData;
    using SafeERC20 for IERC20;
    using CreditAccountHelper for ICreditAccountBase;

    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice Credit manager description
    string public override description;

    /// @notice Address provider contract address
    address public immutable override addressProvider;

    /// @notice Account factory contract address
    address public immutable override accountFactory;

    /// @notice Underlying token address
    address public immutable override underlying;

    /// @notice Address of the pool credit manager is connected to
    address public immutable override pool;

    /// @notice WETH token address
    address public immutable override weth;

    /// @notice Withdrawal manager contract address
    address public immutable override withdrawalManager;

    /// @notice Address of the connected credit facade
    address public override creditFacade;

    /// @notice Maximum number of tokens that can be enabled as collateral for a single credit account
    uint8 public override maxEnabledTokens = DEFAULT_MAX_ENABLED_TOKENS;

    /// @dev Liquidation threshold for the underlying token in bps
    uint16 internal ltUnderlying;

    /// @notice Interest fee charged by the protocol: fee = interest accrued * feeInterest (this includes quota interest)
    /// @notice In PERCENTAGE_FACTOR format
    uint16 internal feeInterest;

    /// @notice Liquidation fee charged by the protocol: fee = totalValue * feeLiquidation
    /// @notice In PERCENTAGE_FACTOR format
    uint16 internal feeLiquidation;

    /// @notice Multiplier used to compute the total value of funds during liquidation.
    /// At liquidation, the borrower's funds are discounted, and the pool is paid out of discounted value
    /// The liquidator takes the difference between the discounted and actual values as premium.
    /// @notice In PERCENTAGE_FACTOR format
    uint16 internal liquidationDiscount;

    /// @notice Total number of known collateral tokens.
    uint8 public override collateralTokensCount;

    /// @notice Liquidation fee charged by the protocol during liquidation by expiry. Typically lower than feeLiquidation.
    /// @notice In PERCENTAGE_FACTOR format
    uint16 internal feeLiquidationExpired;

    /// @notice Multiplier used to compute the total value of funds during liquidation by expiry. Typically higher than
    /// liquidationDiscount (meaning lower premium).
    /// @notice In PERCENTAGE_FACTOR format
    uint16 internal liquidationDiscountExpired;

    /// @notice Price oracle used to evaluate assets on Credit Accounts.
    address public override priceOracle;

    /// @notice Points to the currently processed Credit Account during multicall, otherwise keeps address(1) for gas savings
    /// CreditFacade is a trusted source, so it generally sends the CA as an input for account management functions
    /// _activeCreditAccount is used to avoid adapters having to manually pass the Credit Account
    address internal _activeCreditAccount;

    /// @notice Mask of tokens to apply quota logic for
    /// @custom:invariant `quotedTokensMask % 2 == 0`
    uint256 public override quotedTokensMask;

    /// @notice Address of the connected Credit Configurator
    address public override creditConfigurator;

    /// @notice Map of token's bit mask to its address and LT parameters in a single-slot struct
    mapping(uint256 => CollateralTokenData) internal collateralTokensData;

    /// @notice Internal map of token addresses to their indidivual masks.
    /// @dev A mask is a uint256 that has only 1 non-zero bit in the position corresponding to
    ///         the token's index (i.e., tokenMask = 2 ** index)
    ///         Masks are used to efficiently track set inclusion, since it only involves
    ///         a single AND and comparison to zero
    mapping(address => uint256) internal tokenMasksMapInternal;

    /// @notice Maps allowed adapters to their respective target contracts.
    mapping(address => address) public override adapterToContract;

    /// @notice Maps 3rd party contracts to their respective adapters
    mapping(address => address) public override contractToAdapter;

    /// @notice Contains infomation related to CA, such as accumulated interest,
    ///         enabled tokens, the current borrower and miscellaneous flags
    mapping(address => CreditAccountInfo) public override creditAccountInfo;

    /// @notice Set of all currently active contracts
    EnumerableSet.AddressSet internal creditAccountsSet;

    /// @notice Restricts calls to Credit Facade only
    modifier creditFacadeOnly() {
        _checkCreditFacade();
        _;
    }

    /// @notice Internal function wrapping `creditFacadeOnly` modifier logic
    ///         Used to optimize contract size
    function _checkCreditFacade() private view {
        if (msg.sender != creditFacade) revert CallerNotCreditFacadeException();
    }

    /// @notice Restricts calls to Credit Configurator only
    modifier creditConfiguratorOnly() {
        _checkCreditConfigurator();
        _;
    }

    /// @notice Internal function wrapping `creditFacadeOnly` modifier logic
    ///         Used to optimize contract size
    function _checkCreditConfigurator() private view {
        if (msg.sender != creditConfigurator) {
            revert CallerNotConfiguratorException();
        }
    }

    // TODO: adds underlying as collateral token
    /// @notice Constructor
    /// @param _addressProvider Address of the repository to get system-level contracts from
    /// @param _pool Address of the pool to borrow funds from
    constructor(address _addressProvider, address _pool, string memory _description) {
        addressProvider = _addressProvider;
        pool = _pool; // U:[CM-1]

        underlying = IPoolBase(_pool).underlyingToken(); // U:[CM-1]
        _addToken(underlying); // U:[CM-1]

        weth =
            IAddressProviderV3(addressProvider).getAddressOrRevert({key: AP_WETH_TOKEN, _version: NO_VERSION_CONTROL}); // U:[CM-1]
        priceOracle = IAddressProviderV3(addressProvider).getAddressOrRevert({key: AP_PRICE_ORACLE, _version: 3_00}); // U:[CM-1]
        accountFactory = IAddressProviderV3(addressProvider).getAddressOrRevert({
            key: AP_ACCOUNT_FACTORY,
            _version: NO_VERSION_CONTROL
        }); // U:[CM-1]
        withdrawalManager =
            IAddressProviderV3(addressProvider).getAddressOrRevert({key: AP_WITHDRAWAL_MANAGER, _version: 3_00}); // U:[CM-1]

        creditConfigurator = msg.sender; // U:[CM-1]

        _activeCreditAccount = INACTIVE_CREDIT_ACCOUNT_ADDRESS;

        description = _description;
    }

    /// @notice Address of the connected pool
    /// @dev [DEPRECATED]: use pool() instead.
    function poolService() external view override returns (address) {
        return pool; // U:[CM-1]
    }

    // ------------------ //
    // ACCOUNT MANAGEMENT //
    // ------------------ //

    ///  @notice Opens credit account and borrows funds from the pool.
    /// - Takes Credit Account from the factory;
    /// - Initializes `creditAccountInfo` fields
    /// - Requests the pool to lend underlying to the Credit Account
    ///
    /// @param debt Amount to be borrowed by the Credit Account
    /// @param onBehalfOf The owner of the newly opened Credit Account
    function openCreditAccount(uint256 debt, address onBehalfOf)
        external
        override
        nonZeroAddress(onBehalfOf)
        nonReentrant // U:[CM-5]
        creditFacadeOnly // // U:[CM-2]
        returns (address creditAccount)
    {
        creditAccount = IAccountFactoryBase(accountFactory).takeCreditAccount(0, 0); // U:[CM-6]

        CreditAccountInfo storage newCreditAccountInfo = creditAccountInfo[creditAccount];

        newCreditAccountInfo.debt = debt; // U:[CM-6]
        newCreditAccountInfo.cumulativeIndexLastUpdate = _poolCumulativeIndexNow(); // U:[CM-6]

        // newCreditAccountInfo.flags = 0; // U:[CM-6]
        // newCreditAccountInfo.since = uint64(block.number); // U:[CM-6]
        // newCreditAccountInfo.borrower = onBehalfOf; // U:[CM-6]
        assembly {
            let slot := add(newCreditAccountInfo.slot, 4)
            let value := or(shl(80, onBehalfOf), shl(16, and(number(), 0xFFFFFFFFFFFFFFFF)))
            sstore(slot, value)
        }

        // newCreditAccountInfo.cumulativeQuotaInterest = 1;
        // newCreditAccountInfo.quotaFees = 0;
        assembly {
            let slot := add(newCreditAccountInfo.slot, 2)
            sstore(slot, 1)
        } // U:[CM-6]

        // Requests the pool to transfer tokens the Credit Account
        if (debt != 0) _poolLendCreditAccount(debt, creditAccount); // U:[CM-6]
        creditAccountsSet.add(creditAccount); // U:[CM-6]
    }

    ///  @notice Closes a Credit Account - covers both normal closure and liquidation
    /// - Calculates payments to various recipients on closure.
    ///    + amountToPool is the amount to be sent back to the pool.
    ///      This includes the principal, interest and fees, but can't be more than
    ///      total position value
    ///    + Computes remainingFunds during liquidations - these are leftover funds
    ///      after paying the pool and the liquidator, and are sent to the borrower
    ///    + Computes protocol profit, which includes interest and liquidation fees
    ///    + Computes loss if the totalValue is less than borrow amount + interest
    ///   remainingFunds and loss are only computed during liquidation, since they are
    ///   meaningless during normal account closure.
    /// - Checks the underlying token balance:
    ///    + if it is larger than amountToPool, then the pool is paid fully from funds on the Credit Account
    ///    + else tries to transfer the shortfall from the payer - either the borrower during closure, or liquidator during liquidation
    /// - Signals the pool that the debt is repaid
    /// - If liquidation: transfers `remainingFunds` to the borrower
    /// - If the account has active quotas, requests the PoolQuotaKeeper to reduce them to 0,
    ///   which is required for correctness of interest calculations
    /// - Send assets to the "to" address, as long as they are not included into skipTokenMask
    /// - Returns the Credit Account back to factory
    ///
    /// @param creditAccount Credit account address
    /// @param closureAction Whether the account is closed, liquidated or liquidated due to expiry
    /// @param collateralDebtData Struct of collateral and debt parameters for the account
    /// @param payer Address which would be charged if credit account has not enough funds to cover amountToPool
    /// @param to Address to which the leftover funds will be sent
    /// @param skipTokensMask Tokenmask contains 1 for tokens which needed to be send directly
    /// @param convertToETH If true converts WETH to ETH
    /// @return remainingFunds Amount of underlying returned to the borrower after liquidation (0 is returned for normal account closure)
    /// @return loss Loss incurred during liquidation
    function closeCreditAccount(
        address creditAccount,
        ClosureAction closureAction,
        CollateralDebtData calldata collateralDebtData,
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
        address borrower = getBorrowerOrRevert(creditAccount); // U:[CM-7]

        {
            CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[creditAccount];

            if (currentCreditAccountInfo.since == block.number) {
                revert OpenCloseAccountInOneBlockException();
            }

            // Sets `borrower`, `since` and `flags` of Credit Account to zero
            assembly {
                let slot := add(currentCreditAccountInfo.slot, 4)
                sstore(slot, 0)
            }
        }

        uint256 amountToPool;
        uint256 profit;

        // Computations for various closure amounts are isolated into the `CreditLogic` library
        // See `CreditLogic.calcClosePayments` and `CreditLogic.calcLiquidationPayments`
        if (closureAction == ClosureAction.CLOSE_ACCOUNT) {
            (amountToPool, profit) = collateralDebtData.calcClosePayments({amountWithFeeFn: _amountWithFee}); // U:[CM-8]
        } else {
            // During liquidation, totalValue of the account is discounted
            // by (1 - liquidationPremium). This means that totalValue * liquidationPremium
            // is removed from all calculations and can be claimed by the liquidator at the end of transaction

            // The liquidation premium depends on liquidation type:
            // * For normal unhealthy account or emergency liquidations, usual premium applies
            // * For expiry liquidations, the premium is typically reduced,
            //   since the account does not risk bad debt, so the liquidation
            //   is not as urgent

            {
                bool isNormalLiquidation = closureAction == ClosureAction.LIQUIDATE_ACCOUNT;

                (amountToPool, remainingFunds, profit, loss) = collateralDebtData.calcLiquidationPayments({
                    liquidationDiscount: isNormalLiquidation ? liquidationDiscount : liquidationDiscountExpired,
                    feeLiquidation: isNormalLiquidation ? feeLiquidation : feeLiquidationExpired,
                    amountWithFeeFn: _amountWithFee,
                    amountMinusFeeFn: _amountMinusFee
                }); // U:[CM-8]
            }
        }

        {
            uint256 underlyingBalance = IERC20(underlying).safeBalanceOf({account: creditAccount}); // U:[CM-8]
            uint256 distributedFunds = amountToPool + remainingFunds + 1;

            // If there is an underlying shortfall, attempts to transfer it from the payer
            if (underlyingBalance < distributedFunds) {
                unchecked {
                    IERC20(underlying).safeTransferFrom({
                        from: payer,
                        to: creditAccount,
                        amount: _amountWithFee(distributedFunds - underlyingBalance)
                    }); // U:[CM-8]
                }
            }
        }

        // If the creditAccount has non-zero quotas, they need to be reduced to 0;
        // This is required to both free quota limits for other users and correctly
        // compute quota interest
        if (collateralDebtData.quotedTokens.length != 0) {
            /// In case of any loss, PQK sets limits to zero for all quoted tokens
            bool setLimitsToZero = loss > 0; // U:[CM-8]

            IPoolQuotaKeeperV3(collateralDebtData._poolQuotaKeeper).removeQuotas({
                creditAccount: creditAccount,
                tokens: collateralDebtData.quotedTokens,
                setLimitsToZero: setLimitsToZero
            }); // U:[CM-8]
        }

        if (amountToPool != 0) {
            // Transfers the due funds to the pool
            ICreditAccountBase(creditAccount).transfer({token: underlying, to: pool, amount: amountToPool}); // U:[CM-8]
        }

        if (collateralDebtData.debt + profit + loss != 0) {
            // Signals to the pool that debt has been repaid. The pool relies
            // on the Credit Manager to repay the debt correctly, and does not
            // check internally whether the underlying was actually transferred
            _poolRepayCreditAccount(collateralDebtData.debt, profit, loss); // U:[CM-8]
        }

        // transfer remaining funds to the borrower [liquidations only]
        if (remainingFunds > 1) {
            _safeTokenTransfer({
                creditAccount: creditAccount,
                token: underlying,
                to: borrower,
                amount: remainingFunds,
                convertToETH: false
            }); // U:[CM-8]
        }

        // All remaining assets on the account are transferred to the `to` address
        // If some asset cannot be transferred directly (e.g., `to` is blacklisted by USDC),
        // then an immediate withdrawal is added to withdrawal manager
        _batchTokensTransfer({
            creditAccount: creditAccount,
            to: to,
            convertToETH: convertToETH,
            tokensToTransferMask: collateralDebtData.enabledTokensMask.disable(skipTokensMask)
        }); // U:[CM-8, 9]

        // Returns Credit Account to the factory
        IAccountFactoryBase(accountFactory).returnCreditAccount({creditAccount: creditAccount}); // U:[CM-8]
        creditAccountsSet.remove(creditAccount); // U:[CM-8]
    }

    /// @notice Manages debt size for borrower:
    ///
    /// - Increase debt:
    ///   + Increases debt by transferring funds from the pool to the credit account
    ///   + Updates the cumulative index to keep interest the same. Since interest
    ///     is always computed dynamically as debt * (cumulativeIndexNew / cumulativeIndexOpen - 1),
    ///     cumulativeIndexOpen needs to be updated, as the debt amount has changed
    ///
    /// - Decrease debt:
    ///   + Repays the debt in the following order: quota interest + fees, normal interest + fees, debt;
    ///     In case of interest, if the (remaining) amount is not enough to cover it fully,
    ///     it is split pro-rata between interest and fees to preserve correct fee computations
    ///   + If there were non-zero quota interest, updates the quota interest after repayment
    ///   + If base interest was repaid, updates `cumulativeIndexLastUpdate`
    ///   + If debt was repaid, updates `debt`
    /// @dev For details on cumulativeIndex computations, see `CreditLogic.calcIncrease` and `CreditLogic.calcDecrease`
    ///
    /// @param creditAccount Address of the Credit Account to change debt for
    /// @param amount Amount to increase / decrease the total debt by
    /// @param enabledTokensMask The current enabledTokensMask (required for quota interest computation)
    /// @param action Whether to increase or decrease debt
    /// @return newDebt The new debt principal
    /// @return tokensToEnable The mask of tokens enabled after the operation
    /// @return tokensToDisable The mask of tokens disabled after the operation
    function manageDebt(address creditAccount, uint256 amount, uint256 enabledTokensMask, ManageDebtAction action)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 newDebt, uint256 tokensToEnable, uint256 tokensToDisable)
    {
        uint256[] memory collateralHints;
        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[creditAccount];

        if (amount == 0) return (currentCreditAccountInfo.debt, 0, 0);

        CollateralDebtData memory collateralDebtData = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMask,
            collateralHints: collateralHints,
            minHealthFactor: PERCENTAGE_FACTOR,
            task: (action == ManageDebtAction.INCREASE_DEBT)
                ? CollateralCalcTask.GENERIC_PARAMS
                : CollateralCalcTask.DEBT_ONLY
        }); // U:[CM-10, 11]

        uint256 newCumulativeIndex;
        if (action == ManageDebtAction.INCREASE_DEBT) {
            /// INCREASE DEBT

            (newDebt, newCumulativeIndex) = CreditLogic.calcIncrease({
                amount: amount,
                debt: collateralDebtData.debt,
                cumulativeIndexNow: collateralDebtData.cumulativeIndexNow,
                cumulativeIndexLastUpdate: collateralDebtData.cumulativeIndexLastUpdate
            }); // U:[CM-10]

            _poolLendCreditAccount(amount, creditAccount); // U:[CM-10]

            tokensToEnable = UNDERLYING_TOKEN_MASK; // U:[CM-10]
        } else {
            // DECREASE DEBT

            {
                uint256 maxRepayment = _amountWithFee(collateralDebtData.calcTotalDebt());

                // Passed amount being larger than total debt signals the Credit Manager that the user
                // wants to repay the entire current debt. This is hard to do offchain by passing the exact
                // amount, since total debt increases every block. Typically, the user would pass MAX_INT
                // in this case
                if (amount >= maxRepayment) {
                    /// If a user has active quotas on a zero-debt account, they can remove all collateral
                    /// and immediately go into bad debt on the next block due to quota interest. This check aims to prevent that.
                    if (collateralDebtData.quotedTokens.length != 0) {
                        revert DebtToZeroWithActiveQuotasException();
                    }

                    amount = maxRepayment;
                    action = ManageDebtAction.FULL_REPAYMENT;
                }
            }

            // Pays the entire amount back to the pool
            ICreditAccountBase(creditAccount).transfer({token: underlying, to: pool, amount: amount}); // U:[CM-11]

            uint128 newCumulativeQuotaInterest;
            uint128 newQuotaFees;

            uint256 profit;

            if (action == ManageDebtAction.FULL_REPAYMENT) {
                newDebt = 0;
                newCumulativeIndex = collateralDebtData.cumulativeIndexNow;
                profit = collateralDebtData.accruedFees;
                newCumulativeQuotaInterest = 0;
                newQuotaFees = 0;
            } else {
                (newDebt, newCumulativeIndex, profit, newCumulativeQuotaInterest, newQuotaFees) = CreditLogic
                    .calcDecrease({
                    amount: _amountMinusFee(amount),
                    debt: collateralDebtData.debt,
                    cumulativeIndexNow: collateralDebtData.cumulativeIndexNow,
                    cumulativeIndexLastUpdate: collateralDebtData.cumulativeIndexLastUpdate,
                    cumulativeQuotaInterest: collateralDebtData.cumulativeQuotaInterest,
                    quotaFees: currentCreditAccountInfo.quotaFees,
                    feeInterest: feeInterest
                }); // U:[CM-11]

                /// We need to accrue quota interest in order to keep  quota interest indexes in PQK
                /// and cumulativeQuotaInterest in Credit Manager consistent with each other,
                /// since this action caches all quota interest in Credit Manager
                /// Full repayment is only available if there are no active quotas, which means
                /// that all quota interest should already be accrued

                IPoolQuotaKeeperV3(collateralDebtData._poolQuotaKeeper).accrueQuotaInterest({
                    creditAccount: creditAccount,
                    tokens: collateralDebtData.quotedTokens
                });
            }

            /// The amount of principal repaid is what is left after repaying all interest and fees
            /// and is the difference between newDebt and debt
            _poolRepayCreditAccount(collateralDebtData.debt - newDebt, profit, 0); // U:[CM-11]

            currentCreditAccountInfo.cumulativeQuotaInterest = newCumulativeQuotaInterest + 1; // U:[CM-11]
            currentCreditAccountInfo.quotaFees = newQuotaFees;

            /// If the entire underlying balance was spent on repayment, it is disabled
            if (IERC20(underlying).safeBalanceOf({account: creditAccount}) <= 1) {
                tokensToDisable = UNDERLYING_TOKEN_MASK; // U:[CM-11]
            }
        }

        currentCreditAccountInfo.debt = newDebt; // U:[CM-10, 11]
        currentCreditAccountInfo.cumulativeIndexLastUpdate = newCumulativeIndex; // U:[CM-10, 11]
    }

    /// @notice Transfer collateral from the payer to the credit account
    /// @param payer Address of the account which will be charged to provide additional collateral
    /// @param creditAccount Address of the Credit Account
    /// @param token Collateral token to add
    /// @param amount Amount to add
    /// @return tokenMask Mask of the added token
    function addCollateral(address payer, address creditAccount, address token, uint256 amount)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 tokenMask)
    {
        tokenMask = getTokenMaskOrRevert({token: token}); // U:[CM-13]
        IERC20(token).safeTransferFrom({from: payer, to: creditAccount, amount: amount}); // U:[CM-13]
    }

    // -------- //
    // ADAPTERS //
    // -------- //

    /// @notice Requests the Credit Account to approve a collateral token to another contract.
    /// @param token Collateral token to approve
    /// @param amount New allowance amount
    function approveCreditAccount(address token, uint256 amount)
        external
        override
        nonReentrant // U:[CM-5]
    {
        address targetContract = _getTargetContractOrRevert(); // U:[CM-3]
        _approveSpender({
            creditAccount: getActiveCreditAccountOrRevert(),
            token: token,
            spender: targetContract,
            amount: amount
        }); // U:[CM-14]
    }

    /// @notice Revokes allowances for specified spender/token pairs
    /// @dev When used with an older account factory, the Credit Manager may receive
    ///      an account with existing allowances. If the user is not comfortable with
    ///      these allowances, they can revoke them.
    /// @param creditAccount Credit Account to revoke allowances for
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
                    revert ZeroAddressException(); // U:[CM-15]
                }
                /// It checks that token is in collateral token list in _approveSpender function
                _approveSpender({creditAccount: creditAccount, token: token, spender: spender, amount: 0}); // U:[CM-15]
            }
        }
    }

    /// @notice Internal wrapper for approving tokens, used to optimize contract size, since approvals
    ///         are used in several functions
    /// @param creditAccount Address of the Credit Account
    /// @param token Token to give an approval for
    /// @param spender The address of the spender
    /// @param amount The new allowance amount
    function _approveSpender(address creditAccount, address token, address spender, uint256 amount) internal {
        // Checks that the token is a collateral token
        // Forbidden tokens can be approved, since users need that to
        // sell them off
        getTokenMaskOrRevert({token: token}); // U:[CM-15]

        // The approval logic is isolated into `CreditAccountHelper.safeApprove`. See the corresponding
        // library for details
        ICreditAccountBase(creditAccount).safeApprove({token: token, spender: spender, amount: amount}); // U:[CM-15]
    }

    /// @notice Requests a Credit Account to make a low-level call with provided data
    /// This is the intended pathway for state-changing interactions with 3rd-party protocols
    /// @param data Data to pass with the call
    function execute(bytes calldata data)
        external
        override
        nonReentrant // U:[CM-5]
        returns (bytes memory)
    {
        address targetContract = _getTargetContractOrRevert(); // U:[CM-3]

        // Returned data is provided as-is to the caller;
        // It is expected that is is parsed and returned as a correct type
        // by the adapter itself.
        address creditAccount = getActiveCreditAccountOrRevert(); // U:[CM-16]
        return ICreditAccountBase(creditAccount).execute(targetContract, data); // U:[CM-16]
    }

    /// @notice Returns the target contract associated with the calling address (which is assumed to be an adapter),
    ///      and reverts if there is none. Used to ensure that an adapter can only make calls to its own target
    function _getTargetContractOrRevert() internal view returns (address targetContract) {
        targetContract = adapterToContract[msg.sender]; // U:[CM-15, 16]
        if (targetContract == address(0)) {
            revert CallerNotAdapterException(); // U:[CM-3]
        }
    }

    /// @notice Sets the active credit account (credit account returned to adapters to work on) to the provided address
    /// @dev CreditFacade must always ensure that `_activeCreditAccount` is address(1) between calls
    function setActiveCreditAccount(address creditAccount)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
    {
        if (_activeCreditAccount != INACTIVE_CREDIT_ACCOUNT_ADDRESS && creditAccount != INACTIVE_CREDIT_ACCOUNT_ADDRESS)
        {
            revert ActiveCreditAccountOverridenException();
        }
        _activeCreditAccount = creditAccount;
    }

    /// @notice Returns the current active credit account
    function getActiveCreditAccountOrRevert() public view override returns (address creditAccount) {
        creditAccount = _activeCreditAccount;
        if (creditAccount == INACTIVE_CREDIT_ACCOUNT_ADDRESS) {
            revert ActiveCreditAccountNotSetException();
        }
    }

    // ----------------- //
    // COLLATERAL CHECKS //
    // ----------------- //

    /// @notice Performs a full health check on an account with a custom order of evaluated tokens and
    ///      a custom minimal health factor
    /// @param creditAccount Address of the Credit Account to check
    /// @param enabledTokensMask Current enabled token mask
    /// @param collateralHints Array of token masks in the desired order of evaluation
    /// @param minHealthFactor Minimal health factor of the account, in PERCENTAGE_FACTOR format
    function fullCollateralCheck(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256[] calldata collateralHints,
        uint16 minHealthFactor
    )
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256)
    {
        if (minHealthFactor < PERCENTAGE_FACTOR) {
            revert CustomHealthFactorTooLowException(); // U:[CM-17]
        }

        /// Performs a generalized debt and collteral computation with the
        /// task FULL_COLLATERAL_CHECK_LAZY. This ensures that collateral computations
        /// stop as soon as it is determined that there is enough collateral to cover the debt,
        /// which is done in order to save gas
        CollateralDebtData memory collateralDebtData = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            minHealthFactor: minHealthFactor,
            collateralHints: collateralHints,
            enabledTokensMask: enabledTokensMask,
            task: CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY
        }); // U:[CM-18]

        /// If the TWV value outputted by the collateral computation is less than
        /// total debt, the full collateral check has failed
        if (collateralDebtData.twvUSD < collateralDebtData.totalDebtUSD) {
            revert NotEnoughCollateralException(); // U:[CM-18]
        }

        uint256 enabledTokensMaskAfter = collateralDebtData.enabledTokensMask;
        /// During a multicall, all changes to enabledTokenMask are stored in-memory
        /// to avoid redundant storage writes. Saving to storage is only done at the end
        /// of a full collateral check, which is performed after every multicall
        _saveEnabledTokensMask(creditAccount, enabledTokensMaskAfter); // U:[CM-18]

        return enabledTokensMaskAfter;
    }

    /// @notice Returns whether the passed credit account is unhealthy given the provided minHealthFactor
    /// @param creditAccount Address of the credit account to check
    /// @param minHealthFactor The health factor below which the function would
    ///                        consider the account unhealthy, in PERCENTAGE_FACTOR format
    function isLiquidatable(address creditAccount, uint16 minHealthFactor) external view override returns (bool) {
        uint256[] memory collateralHints;

        CollateralDebtData memory collateralDebtData = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMaskOf(creditAccount),
            collateralHints: collateralHints,
            minHealthFactor: minHealthFactor,
            task: CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY
        }); // U:[CM-18]

        return collateralDebtData.twvUSD < collateralDebtData.totalDebtUSD; // U:[CM-18]
    }

    /// @notice Calculates parameters related to account's debt and collateral,
    ///         with level of detail dependent on `task`
    /// @dev Unlike previous versions, Gearbox V3 uses a generalized Credit Manager function to compute debt and collateral
    ///      that is then reused in other contracts (including third-party contracts, such as bots). This allows to ensure that account health
    ///      computation logic is uniform across the codebase. The returned collateralDebtData object is intended to be a complete set of
    ///      data required to track account health, but can be filled partially to avoid unnecessary computation where needed.
    /// @param creditAccount Credit Account to compute parameters for
    /// @param task Determines the parameters to compute:
    ///             * GENERIC_PARAMS - computes debt and raw base interest indexes
    ///             * DEBT_ONLY - computes all debt parameters, including totalDebt, accrued base/quota interest and associated fees;
    ///               if quota logic is enabled, also returns all data relevant to quota interest and collateral computations in the struct
    ///             * DEBT_COLLATERAL_WITHOUT_WITHDRAWALS - computes all debt parameters and the total value of collateral
    ///               (both weighted and unweighted, in USD and underlying).
    ///             * DEBT_COLLATERAL_CANCEL_WITHDRAWALS - same as above, but includes immature withdrawals into the total value of the Credit Account;
    ///               NB: The value of withdrawals is not included into the total weighted value, so they have no bearing on whether an account can be
    ///               liquidated. However, during liquidations it is prudent to return immature withdrawals to the Credit Account, to defend against attacks
    ///               that involve withdrawals combined with oracle manipulations. Hence, this collateral computation method is used for liquidations.
    ///             * DEBT_COLLATERAL_FORCE_CANCEL_WITHDRAWALS - same as above, but also includes mature withdrawals into the total value of the Credit Account;
    ///               NB: This method of calculation is used for emergency liquidations. Emergency liquidations are performed when the system is paused due to a
    ///               perceived security risk. Returning mature withdrawals is a contingency for the case where a malicious withdrawal is scheduled, the system
    ///               is paused, and the withdrawal matures while the DAO coordinates a response.
    /// @return collateralDebtData A struct containing debt and collateral parameters. It is filled based on the passed task.
    ///                            For more information on struct fields, see its definition along the `ICreditManagerV3` interface
    /// @custom:invariant Unless `task == GENERIC_PARAMS`, from `creditAccountInfo[creditAccount].debt == 0`
    ///                   follows `collateralDebtData.accruedInterest == collateralDebtData.accruedFees == 0`
    function calcDebtAndCollateral(address creditAccount, CollateralCalcTask task)
        external
        view
        override
        returns (CollateralDebtData memory collateralDebtData)
    {
        uint256[] memory collateralHints;

        /// @dev FULL_COLLATERAL_CHECK_LAZY is a special calculation type
        ///      that can only be used safely internally, since it can stop early
        ///      and possibly return incorrect TWV/TV values. Therefore, it is
        ///      prevented from being called externally
        if (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY) {
            revert IncorrectParameterException(); // U:[CM-19]
        }

        collateralDebtData = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMaskOf(creditAccount),
            collateralHints: collateralHints,
            minHealthFactor: PERCENTAGE_FACTOR,
            task: task
        }); // U:[CM-20]
    }

    /// @notice Implementation for `calcDebtAndCollateral`.
    /// @param creditAccount Credit Account to compute collateral for
    /// @param enabledTokensMask Current enabled tokens mask
    /// @param collateralHints Array of token masks in the desired order of evaluation.
    ///        Used to optimize the length of lazy evaluation by putting the most valuable
    ///        tokens on the account first.
    /// @param minHealthFactor The health factor to stop the lazy evaluation at
    /// @param task The type of calculation to perform (see `calcDebtAndCollateral` for details)
    function _calcDebtAndCollateral(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256[] memory collateralHints,
        uint16 minHealthFactor,
        CollateralCalcTask task
    ) internal view returns (CollateralDebtData memory collateralDebtData) {
        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[creditAccount];

        /// GENERIC PARAMS
        /// The generic parameters include the debt principal and base interest current and LU indexes
        /// This is the minimal amount of debt data required to perform computations after increasing debt.
        collateralDebtData.debt = currentCreditAccountInfo.debt; // U:[CM-20]
        collateralDebtData.cumulativeIndexLastUpdate = currentCreditAccountInfo.cumulativeIndexLastUpdate; // U:[CM-20]
        collateralDebtData.cumulativeIndexNow = _poolCumulativeIndexNow(); // U:[CM-20]

        if (task == CollateralCalcTask.GENERIC_PARAMS) {
            return collateralDebtData;
        } // U:[CM-20]

        /// DEBT
        /// Debt parameters include accrued interest (with quota interest included, if applicable) and fees
        /// Parameters related to quoted tokens are cached inside the struct, since they are read from storage
        /// during quota interest computation and can be later reused to compute quota token collateral
        collateralDebtData.enabledTokensMask = enabledTokensMask; // U:[CM-21]

        // uint16[] memory quotaLts;
        uint256[] memory quotasPacked;
        collateralDebtData._poolQuotaKeeper = poolQuotaKeeper(); // U:[CM-21]

        (
            collateralDebtData.quotedTokens,
            collateralDebtData.cumulativeQuotaInterest,
            quotasPacked,
            collateralDebtData.quotedTokensMask
        ) = _getQuotedTokensData({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMask,
            collateralHints: collateralHints,
            _poolQuotaKeeper: collateralDebtData._poolQuotaKeeper
        }); // U:[CM-21]

        collateralDebtData.cumulativeQuotaInterest += currentCreditAccountInfo.cumulativeQuotaInterest - 1; // U:[CM-21]

        collateralDebtData.accruedInterest = collateralDebtData.cumulativeQuotaInterest;
        collateralDebtData.accruedFees = currentCreditAccountInfo.quotaFees;

        collateralDebtData.accruedInterest += CreditLogic.calcAccruedInterest({
            amount: collateralDebtData.debt,
            cumulativeIndexLastUpdate: collateralDebtData.cumulativeIndexLastUpdate,
            cumulativeIndexNow: collateralDebtData.cumulativeIndexNow
        }); // U:[CM-21]

        collateralDebtData.accruedFees += (collateralDebtData.accruedInterest * feeInterest) / PERCENTAGE_FACTOR; // U:[CM-21]

        if (task == CollateralCalcTask.DEBT_ONLY) return collateralDebtData; // U:[CM-21]

        /// COLLATERAL
        /// Collateral values such as total value / total weighted value are computed and saved into the struct
        /// And zero-balance tokens encountered are removed from enabledTokensMask inside the struct as well
        /// If the task is FULL_COLLATERAL_CHECK_LAZY, then collateral value are only computed until twvUSD > totalDebtUSD,
        /// and any extra collateral on top of that is not included into the account's value
        address _priceOracle = priceOracle;

        uint256 totalDebt = collateralDebtData.calcTotalDebt();

        collateralDebtData.totalDebtUSD = totalDebt == 0
            ? 0
            : _convertToUSD({_priceOracle: _priceOracle, amountInToken: totalDebt, token: underlying}); // U:[CM-22]

        /// The logic for computing collateral is isolated into the `CreditLogic` library. See `CreditLogic.calcCollateral` for details.
        uint256 tokensToDisable;

        /// TargetUSD is a TWV threshold at which lazy computation stops. Normally, it happens when TWV
        /// exceeds the total debt, but the user can also configure a custom HF threshold (above 1),
        /// in order to maintain a desired level of position health
        uint256 targetUSD = (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY)
            ? (collateralDebtData.totalDebtUSD * minHealthFactor) / PERCENTAGE_FACTOR
            : type(uint256).max;

        if ((task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY) && (targetUSD == 0)) {
            // If the user has zero total debt, we can safely skip all collateral computations during a
            // full collateral check
            return collateralDebtData; // U: [CM-18A]
        }
        (collateralDebtData.totalValueUSD, collateralDebtData.twvUSD, tokensToDisable) = collateralDebtData
            .calcCollateral({
            creditAccount: creditAccount,
            underlying: underlying,
            twvUSDTarget: targetUSD,
            collateralHints: collateralHints,
            quotasPacked: quotasPacked,
            priceOracle: _priceOracle,
            collateralTokenByMaskFn: _collateralTokenByMask,
            convertToUSDFn: _convertToUSD
        }); // U:[CM-22]

        collateralDebtData.enabledTokensMask = enabledTokensMask.disable(tokensToDisable); // U:[CM-22]

        if (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY) {
            return collateralDebtData;
        }

        /// WITHDRAWALS
        /// Withdrawals are added to the total value of the account primarily for liquidation purposes,
        /// since we want to return withdrawals to the Credit Account but also need to ensure that
        /// they are included into remainingFunds.
        if ((task != CollateralCalcTask.DEBT_COLLATERAL_WITHOUT_WITHDRAWALS) && _hasWithdrawals(creditAccount)) {
            collateralDebtData.totalValueUSD += _getCancellableWithdrawalsValue({
                _priceOracle: _priceOracle,
                creditAccount: creditAccount,
                isForceCancel: task == CollateralCalcTask.DEBT_COLLATERAL_FORCE_CANCEL_WITHDRAWALS
            }); // U:[CM-23]
        }

        /// The underlying-denominated total value is also added for liquidation payments calculations, unless the data is computed
        /// for fullCollateralCheck, which doesn't need this
        collateralDebtData.totalValue = _convertFromUSD(_priceOracle, collateralDebtData.totalValueUSD, underlying); // U:[CM-22,23]
    }

    /// @notice Gathers all data on the Credit Account's quoted tokens and quota interest
    /// @param creditAccount Credit Account to return quoted token data for
    /// @param enabledTokensMask Current mask of enabled tokens
    /// @param collateralHints Array of token masks in the desired order of evaluation.
    ///        The order of the final quoted tokens array will follow the order of hints,
    ///        which can help in stopping collateral computations early to optimize gas.
    /// @param _poolQuotaKeeper The PoolQuotaKeeper contract storing the quota and quota interest data
    /// @return quotaTokens An array of address of quoted tokens on the Credit Account
    /// @return outstandingQuotaInterest Quota interest that has not been saved in the Credit Manager
    /// @return quotasPacked Current quotas on quoted tokens packet with their lts
    /// @return _quotedTokensMask The mask of all quoted tokens in the credit manager
    function _getQuotedTokensData(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256[] memory collateralHints,
        address _poolQuotaKeeper
    )
        internal
        view
        returns (
            address[] memory quotaTokens,
            uint128 outstandingQuotaInterest,
            uint256[] memory quotasPacked,
            uint256 _quotedTokensMask
        )
    {
        _quotedTokensMask = quotedTokensMask; // U:[CM-24]

        uint256 tokensToCheckMask = enabledTokensMask & _quotedTokensMask; // U:[CM-24]

        // If there are not quoted tokens on the account, then zero-length arrays are returned
        // This is desirable, as it makes it simple to check whether there are any quoted tokens
        if (tokensToCheckMask != 0) {
            uint256 tokensToCheckLen = tokensToCheckMask.calcEnabledTokens(); // U:[CM-24]
            quotaTokens = new address[](tokensToCheckLen); // U:[CM-24]
            quotasPacked = new uint256[](tokensToCheckLen); // U:[CM-24]

            uint256 j;

            uint256 len = collateralHints.length;

            //  Picks creditAccount on top of stack to remove stack to deep error
            address ca = creditAccount;
            unchecked {
                uint256 i;
                while (tokensToCheckMask != 0) {
                    uint256 tokenMask;

                    if (i < len) {
                        tokenMask = collateralHints[i];
                        ++i;
                        if (tokensToCheckMask & tokenMask == 0) continue;
                    } else {
                        tokenMask = tokensToCheckMask & uint256(-int256(tokensToCheckMask));
                    }

                    (address token, uint16 lt) = _collateralTokenByMask({tokenMask: tokenMask, calcLT: true}); // U:[CM-24]

                    (uint256 quota, uint128 outstandingInterestDelta) =
                        IPoolQuotaKeeperV3(_poolQuotaKeeper).getQuotaAndOutstandingInterest(ca, token); // U:[CM-24]

                    quotaTokens[j] = token; // U:[CM-24]
                    quotasPacked[j] = CollateralLogic.packQuota(uint96(quota), lt);

                    /// Quota interest is equal to quota * APY * time. Since quota is a uint96, this is unlikely to overflow in any realistic scenario.
                    outstandingQuotaInterest += outstandingInterestDelta; // U:[CM-24]

                    ++j; // U:[CM-24]

                    tokensToCheckMask = tokensToCheckMask.disable(tokenMask);
                }
            }
        }
    }

    // ------ //
    // QUOTAS //
    // ------ //

    /// @notice Returns address of the quota keeper connected to the pool
    function poolQuotaKeeper() public view override returns (address) {
        return IPoolV3(pool).poolQuotaKeeper(); // U:[CM-47]
    }

    /// @notice Requests quota keeper to update credit account's quota for a given token
    /// @param creditAccount Account to update the quota for
    /// @param token Token to update the quota for
    /// @param quotaChange Requested quota change
    /// @param minQuota Minimum resulting account's quota for token required not to revert
    ///        (set by the user to prevent slippage)
    /// @param maxQuota Maximum resulting account's quota for token required not to revert
    ///        (set by the credit facade to prevent pool's diesel rate manipulation)
    /// @return tokensToEnable Mask of tokens that should be enabled after the operation
    ///         (equals `token`'s mask if changing quota from zero to non-zero value, zero otherwise)
    /// @return tokensToDisable Mask of tokens that should be disabled after the operation
    ///         (equals `token`'s mask if changing quota from non-zero value to zero, zero otherwise)
    /// @dev Accounts with zero debt are not allowed to increase quotas
    function updateQuota(address creditAccount, address token, int96 quotaChange, uint96 minQuota, uint96 maxQuota)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[creditAccount];
        if (quotaChange > 0 && currentCreditAccountInfo.debt == 0) {
            revert IncreaseQuotaOnZeroDebtAccountException();
        }

        (uint128 caInterestChange, uint128 quotaFees, bool enable, bool disable) = IPoolQuotaKeeperV3(poolQuotaKeeper())
            .updateQuota({
            creditAccount: creditAccount,
            token: token,
            requestedChange: quotaChange,
            minQuota: minQuota,
            maxQuota: maxQuota
        }); // U:[CM-25]

        if (enable) {
            tokensToEnable = getTokenMaskOrRevert(token); // U:[CM-25]
        } else if (disable) {
            tokensToDisable = getTokenMaskOrRevert(token); // U:[CM-25]
        }

        currentCreditAccountInfo.cumulativeQuotaInterest += caInterestChange; // U:[CM-25]
        if (quotaFees != 0) {
            currentCreditAccountInfo.quotaFees += quotaFees;
        }
    }

    // ----------- //
    // WITHDRAWALS //
    // ----------- //

    /// @notice Schedules a withdrawal from the credit account
    /// @param creditAccount Credit account to schedule a withdrawal from
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw
    /// @return tokensToDisable Mask of tokens that should be disabled after the operation
    ///         (equals `token`'s mask if withdrawing the entire balance, zero otherwise)
    /// @dev If withdrawal manager's delay is zero, token is immediately sent to the account owner.
    ///      Otherwise, token is sent to the withdrawal manager and `WITHDRAWAL_FLAG` is enabled for the account.
    function scheduleWithdrawal(address creditAccount, address token, uint256 amount)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 tokensToDisable)
    {
        uint256 tokenMask = getTokenMaskOrRevert({token: token}); // U:[CM-26]

        if (IWithdrawalManagerV3(withdrawalManager).delay() == 0) {
            address borrower = getBorrowerOrRevert({creditAccount: creditAccount});
            _safeTokenTransfer({
                creditAccount: creditAccount,
                token: token,
                to: borrower,
                amount: amount,
                convertToETH: false
            }); // U:[CM-27]
        } else {
            uint256 delivered = ICreditAccountBase(creditAccount).transferDeliveredBalanceControl({
                token: token,
                to: withdrawalManager,
                amount: amount
            }); // U:[CM-28]

            IWithdrawalManagerV3(withdrawalManager).addScheduledWithdrawal({
                creditAccount: creditAccount,
                token: token,
                amount: delivered,
                tokenIndex: tokenMask.calcIndex()
            }); // U:[CM-28]

            _enableFlag({creditAccount: creditAccount, flag: WITHDRAWAL_FLAG});
        }

        if (IERC20(token).safeBalanceOf({account: creditAccount}) <= 1) {
            tokensToDisable = tokenMask; // U:[CM-27]
        }
    }

    /// @notice Claims scheduled withdrawals from the credit account
    /// @param creditAccount Credit account to claim withdrawals from
    /// @param to Address to claim withdrawals to
    /// @param action Action to perform, see `ClaimAction` for details
    /// @return tokensToEnable Mask of tokens that should be enabled after the operation
    ///         (non-zero when tokens are returned to the account on withdrawal cancellation)
    /// @dev If account has no withdrawals scheduled after the operation, `WITHDRAWAL_FLAG` is disabled
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
                IWithdrawalManagerV3(withdrawalManager).claimScheduledWithdrawals(creditAccount, to, action); // U:[CM-29]

            if (!hasScheduled) {
                _disableFlag(creditAccount, WITHDRAWAL_FLAG); // U:[CM-29]
            }
        }
    }

    /// @dev Returns the USD value of `creditAccount`'s cancellable scheduled withdrawals
    /// @param isForceCancel Whether to account for immature or all scheduled withdrawals
    function _getCancellableWithdrawalsValue(address _priceOracle, address creditAccount, bool isForceCancel)
        internal
        view
        returns (uint256 totalValueUSD)
    {
        (address token1, uint256 amount1, address token2, uint256 amount2) =
            IWithdrawalManagerV3(withdrawalManager).cancellableScheduledWithdrawals(creditAccount, isForceCancel); // U:[CM-30]

        if (amount1 != 0) {
            totalValueUSD = _convertToUSD({_priceOracle: _priceOracle, amountInToken: amount1, token: token1}); // U:[CM-30]
        }
        if (amount2 != 0) {
            totalValueUSD += _convertToUSD({_priceOracle: _priceOracle, amountInToken: amount2, token: token2}); // U:[CM-30]
        }
    }

    /// @dev Checks whether credit account has scheduled withdrawals
    function _hasWithdrawals(address creditAccount) internal view returns (bool) {
        return flagsOf(creditAccount) & WITHDRAWAL_FLAG != 0; // U:[CM-36]
    }

    // --------------------- //
    // CREDIT MANAGER PARAMS //
    // --------------------- //

    /// @notice Returns `token`'s collateral mask in the credit manager
    /// @param token Token address
    /// @return tokenMask Collateral token mask in the credit manager
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function getTokenMaskOrRevert(address token) public view override returns (uint256 tokenMask) {
        if (token == underlying) return UNDERLYING_TOKEN_MASK; // U:[CM-34]

        tokenMask = tokenMasksMapInternal[token]; // U:[CM-34]
        if (tokenMask == 0) revert TokenNotAllowedException(); // U:[CM-34]
    }

    /// @notice Returns collateral token's address by its mask in the credit manager
    /// @param tokenMask Collateral token mask in the credit manager
    /// @return token Token address
    /// @dev Reverts if `tokenMask` doesn't correspond to any known collateral token
    function getTokenByMask(uint256 tokenMask) public view override returns (address token) {
        (token,) = _collateralTokenByMask({tokenMask: tokenMask, calcLT: false}); // U:[CM-34]
    }

    /// @notice Returns collateral token's liquidation threshold
    /// @param token Token address
    /// @return lt Token's liquidation threshold in bps
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function liquidationThresholds(address token) public view override returns (uint16 lt) {
        uint256 tokenMask = getTokenMaskOrRevert(token);
        (, lt) = _collateralTokenByMask({tokenMask: tokenMask, calcLT: true}); // U:[CM-42]
    }

    /// @notice Returns `token`'s liquidation threshold ramp parameters
    /// @param token Token to get parameters for
    /// @return ltInitial LT at the beginning of the ramp in bps
    /// @return ltFinal LT at the end of the ramp in bps
    /// @return timestampRampStart Timestamp of the beginning of the ramp
    /// @return rampDuration Ramp duration in seconds
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function ltParams(address token)
        external
        view
        override
        returns (uint16 ltInitial, uint16 ltFinal, uint40 timestampRampStart, uint24 rampDuration)
    {
        uint256 tokenMask = getTokenMaskOrRevert(token);
        CollateralTokenData memory tokenData = collateralTokensData[tokenMask];

        return (tokenData.ltInitial, tokenData.ltFinal, tokenData.timestampRampStart, tokenData.rampDuration);
    }

    /// @notice Returns collateral token's address and liquidation threshold by its mask
    /// @param tokenMask Collateral token mask in the credit manager
    /// @return token Token address
    /// @return liquidationThreshold Token's liquidation threshold in bps
    /// @dev Reverts if `tokenMask` doesn't correspond to any known collateral token
    function collateralTokenByMask(uint256 tokenMask)
        public
        view
        override
        returns (address token, uint16 liquidationThreshold)
    {
        return _collateralTokenByMask({tokenMask: tokenMask, calcLT: true}); // U:[CM-34, 42]
    }

    /// @dev Returns collateral token's address by its mask, optionally returns its liquidation threshold
    /// @dev Reverts if `tokenMask` doesn't correspond to any known collateral token
    function _collateralTokenByMask(uint256 tokenMask, bool calcLT)
        internal
        view
        returns (address token, uint16 liquidationThreshold)
    {
        if (tokenMask == UNDERLYING_TOKEN_MASK) {
            token = underlying; // U:[CM-34]
            if (calcLT) liquidationThreshold = ltUnderlying; // U:[CM-35]
        } else {
            CollateralTokenData storage tokenData = collateralTokensData[tokenMask]; // U:[CM-34]

            bytes32 rawData;
            assembly {
                rawData := sload(tokenData.slot)
                token := and(rawData, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) // U:[CM-34]
            }

            if (token == address(0)) {
                revert TokenNotAllowedException(); // U:[CM-34]
            }

            if (calcLT) {
                uint16 ltInitial;
                uint16 ltFinal;
                uint40 timestampRampStart;
                uint24 rampDuration;

                assembly {
                    ltInitial := and(shr(160, rawData), 0xFFFF)
                    ltFinal := and(shr(176, rawData), 0xFFFF)
                    timestampRampStart := and(shr(192, rawData), 0xFFFFFFFFFF)
                    rampDuration := and(shr(232, rawData), 0xFFFFFF)
                }

                liquidationThreshold = CreditLogic.getLiquidationThreshold({
                    ltInitial: ltInitial,
                    ltFinal: ltFinal,
                    timestampRampStart: timestampRampStart,
                    rampDuration: rampDuration
                }); // U:[CM-42]
            }
        }
    }

    /// @notice Returns credit manager's fee parameters (all fields in bps)
    /// @return _feeInterest Percentage of accrued interest taken by the protocol as profit
    /// @return _feeLiquidation Percentage of liquidated account value taken by the protocol as profit
    /// @return _liquidationDiscount Percentage of liquidated account value that is used to repay debt
    /// @return _feeLiquidationExpired Percentage of liquidated expired account value taken by the protocol as profit
    /// @return _liquidationDiscountExpired Percentage of liquidated expired account value that is used to repay debt
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
        _feeInterest = feeInterest; // U:[CM-41]
        _feeLiquidation = feeLiquidation; // U:[CM-41]
        _liquidationDiscount = liquidationDiscount; // U:[CM-41]
        _feeLiquidationExpired = feeLiquidationExpired; // U:[CM-41]
        _liquidationDiscountExpired = liquidationDiscountExpired; // U:[CM-41]
    }

    // ------------ //
    // ACCOUNT INFO //
    // ------------ //

    /// @notice Returns `creditAccount`'s owner or reverts if account is not opened in this credit manager
    function getBorrowerOrRevert(address creditAccount) public view override returns (address borrower) {
        borrower = creditAccountInfo[creditAccount].borrower; // U:[CM-35]
        if (borrower == address(0)) revert CreditAccountDoesNotExistException(); // U:[CM-35]
    }

    /// @notice Returns `creditAccount`'s flags as a bit mask
    /// @dev Does not revert if `creditAccount` is not opened in this credit manager
    function flagsOf(address creditAccount) public view override returns (uint16) {
        return creditAccountInfo[creditAccount].flags; // U:[CM-35]
    }

    /// @notice Sets `creditAccount`'s flag to a given value
    /// @param creditAccount Account to set a flag for
    /// @param flag Flag to set
    /// @param value The new flag value
    /// @custom:expects Credit facade ensures that `creditAccount` is opened in this credit manager
    function setFlagFor(address creditAccount, uint16 flag, bool value)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
    {
        if (value) {
            _enableFlag(creditAccount, flag); // U:[CM-36]
        } else {
            _disableFlag(creditAccount, flag); // U:[CM-36]
        }
    }

    /// @dev Enables `creditAccount`'s flag
    function _enableFlag(address creditAccount, uint16 flag) internal {
        creditAccountInfo[creditAccount].flags |= flag; // U:[CM-36]
    }

    /// @dev Disables `creditAccount`'s flag
    function _disableFlag(address creditAccount, uint16 flag) internal {
        creditAccountInfo[creditAccount].flags &= ~flag; // U:[CM-36]
    }

    /// @notice Returns `creditAccount`'s enabled tokens mask
    /// @dev Does not revert if `creditAccount` is not opened to this credit manager
    function enabledTokensMaskOf(address creditAccount) public view override returns (uint256) {
        return creditAccountInfo[creditAccount].enabledTokensMask; // U:[CM-37]
    }

    /// @dev Saves `creditAccount`'s `enabledTokensMask` in the storage
    /// @dev Ensures that the number of enabled tokens does not exceed `maxEnabledTokens`
    function _saveEnabledTokensMask(address creditAccount, uint256 enabledTokensMask) internal {
        if (enabledTokensMask.calcEnabledTokens() > maxEnabledTokens) {
            revert TooManyEnabledTokensException(); // U:[CM-37]
        }

        creditAccountInfo[creditAccount].enabledTokensMask = enabledTokensMask; // U:[CM-37]
    }

    /// @notice Returns an array of all credit accounts opened in this credit manager
    function creditAccounts() external view override returns (address[] memory) {
        return creditAccountsSet.values();
    }

    /// @notice Returns chunk of up to `limit` credit accounts opened in this credit manager starting from `offset`
    function creditAccounts(uint256 offset, uint256 limit) external view override returns (address[] memory result) {
        uint256 len = creditAccountsSet.length();
        uint256 resultLen = offset + limit > len ? len - offset : limit;

        result = new address[](resultLen);
        unchecked {
            for (uint256 i = 0; i < resultLen; ++i) {
                result[i] = creditAccountsSet.at(offset + i);
            }
        }
    }

    /// @notice Returns the number of open credit accounts opened in this credit manager
    function creditAccountsLen() external view override returns (uint256) {
        return creditAccountsSet.length();
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Adds `token` to the list of collateral tokens, see `_addToken` for details
    function addToken(address token)
        external
        override
        creditConfiguratorOnly // U:[CM-4]
    {
        _addToken(token); // U:[CM-38, 39]
    }

    /// @dev `addToken` implementation:
    ///      - Ensures that token is not already added
    ///      - Forbids adding more than 255 collateral tokens
    ///      - Adds token with LT = 0
    ///      - Increases the number of collateral tokens
    /// @param token Address of the token to add
    function _addToken(address token) internal {
        if (tokenMasksMapInternal[token] != 0) {
            revert TokenAlreadyAddedException(); // U:[CM-38]
        }
        if (collateralTokensCount >= 255) {
            revert TooManyTokensException(); // U:[CM-38]
        }

        uint256 tokenMask = 1 << collateralTokensCount; // U:[CM-39]
        tokenMasksMapInternal[token] = tokenMask; // U:[CM-39]

        collateralTokensData[tokenMask].token = token; // U:[CM-39]
        collateralTokensData[tokenMask].timestampRampStart = type(uint40).max; // U:[CM-39]

        unchecked {
            ++collateralTokensCount; // U:[CM-39]
        }
    }

    /// @notice Sets credit manager's fee parameters (all fields in bps)
    /// @param _feeInterest Percentage of accrued interest taken by the protocol as profit
    /// @param _feeLiquidation Percentage of liquidated account value taken by the protocol as profit
    /// @param _liquidationDiscount Percentage of liquidated account value that is used to repay debt
    /// @param _feeLiquidationExpired Percentage of liquidated expired account value taken by the protocol as profit
    /// @param _liquidationDiscountExpired Percentage of liquidated expired account value that is used to repay debt
    function setFees(
        uint16 _feeInterest,
        uint16 _feeLiquidation,
        uint16 _liquidationDiscount,
        uint16 _feeLiquidationExpired,
        uint16 _liquidationDiscountExpired
    )
        external
        override
        creditConfiguratorOnly // U:[CM-4]
    {
        feeInterest = _feeInterest; // U:[CM-40]
        feeLiquidation = _feeLiquidation; // U:[CM-40]
        liquidationDiscount = _liquidationDiscount; // U:[CM-40]
        feeLiquidationExpired = _feeLiquidationExpired; // U:[CM-40]
        liquidationDiscountExpired = _liquidationDiscountExpired; // U:[CM-40]
    }

    /// @notice Sets `token`'s liquidation threshold ramp parameters
    /// @param token Token to set parameters for
    /// @param ltInitial LT at the beginning of the ramp in bps
    /// @param ltFinal LT at the end of the ramp in bps
    /// @param timestampRampStart Timestamp of the beginning of the ramp
    /// @param rampDuration Ramp duration in seconds
    /// @dev If `token` is `underlying`, sets LT to `ltInitial` and ignores other parameters
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function setCollateralTokenData(
        address token,
        uint16 ltInitial,
        uint16 ltFinal,
        uint40 timestampRampStart,
        uint24 rampDuration
    )
        external
        override
        creditConfiguratorOnly // U:[CM-4]
    {
        if (token == underlying) {
            ltUnderlying = ltInitial; // U:[CM-42]
        } else {
            uint256 tokenMask = getTokenMaskOrRevert({token: token}); // U:[CM-41]
            CollateralTokenData storage tokenData = collateralTokensData[tokenMask];

            tokenData.ltInitial = ltInitial; // U:[CM-42]
            tokenData.ltFinal = ltFinal; // U:[CM-42]
            tokenData.timestampRampStart = timestampRampStart; // U:[CM-42]
            tokenData.rampDuration = rampDuration; // U:[CM-42]
        }
    }

    /// @notice Sets a new quoted token mask
    /// @param _quotedTokensMask The new quoted tokens mask
    /// @dev Excludes underlying token from the new mask
    function setQuotedMask(uint256 _quotedTokensMask)
        external
        override
        creditConfiguratorOnly // U:[CM-4]
    {
        quotedTokensMask = _quotedTokensMask & ~UNDERLYING_TOKEN_MASK; // U:[CM-43]
    }

    /// @notice Sets a new max number of enabled tokens
    /// @param _maxEnabledTokens The new max number of enabled tokens
    function setMaxEnabledTokens(uint8 _maxEnabledTokens)
        external
        override
        creditConfiguratorOnly // U: [CM-4]
    {
        maxEnabledTokens = _maxEnabledTokens; // U:[CM-44]
    }

    /// @notice Sets the link between the adapter and the target contract
    /// @param adapter Address of the adapter contract to use to access the third-party contract,
    ///        passing `address(0)` will forbid accessing `targetContract`
    /// @param targetContract Address of the third-pary contract for which the adapter is set,
    ///        passing `address(0)` will forbid using `adapter`
    /// @dev Reverts if `targetContract` or `adapter` is this contract's address
    function setContractAllowance(address adapter, address targetContract)
        external
        override
        creditConfiguratorOnly // U: [CM-4]
    {
        if (targetContract == address(this) || adapter == address(this)) {
            revert TargetContractNotAllowedException();
        } // U:[CM-45]

        if (adapter != address(0)) {
            adapterToContract[adapter] = targetContract; // U:[CM-45]
        }
        if (targetContract != address(0)) {
            contractToAdapter[targetContract] = adapter; // U:[CM-45]
        }
    }

    /// @notice Sets a new credit facade
    /// @param _creditFacade Address of the new credit facade
    function setCreditFacade(address _creditFacade)
        external
        override
        creditConfiguratorOnly // U: [CM-4]
    {
        creditFacade = _creditFacade; // U:[CM-46]
    }

    /// @notice Sets a new price oracle
    /// @param _priceOracle Address of the new price oracle
    function setPriceOracle(address _priceOracle)
        external
        override
        creditConfiguratorOnly // U: [CM-4]
    {
        priceOracle = _priceOracle; // U:[CM-46]
    }

    /// @notice Sets a new credit configurator
    /// @param _creditConfigurator Address of the new credit configurator
    function setCreditConfigurator(address _creditConfigurator)
        external
        override
        creditConfiguratorOnly // U: [CM-4]
    {
        creditConfigurator = _creditConfigurator; // U:[CM-46]
        emit SetCreditConfigurator(_creditConfigurator); // U:[CM-46]
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Transfers all balances of tokens specified by `tokensToTransferMask` from `creditAccount` to `to`
    /// @dev See `_safeTokenTransfer` for additional details
    function _batchTokensTransfer(address creditAccount, address to, bool convertToETH, uint256 tokensToTransferMask)
        internal
    {
        unchecked {
            while (tokensToTransferMask > 0) {
                uint256 tokenMask = tokensToTransferMask & uint256(-int256(tokensToTransferMask));
                tokensToTransferMask &= tokensToTransferMask - 1;

                address token = getTokenByMask(tokenMask); // U:[CM-31]
                uint256 amount = IERC20(token).safeBalanceOf({account: creditAccount}); // U:[CM-31]
                // 1 wei gas optimization
                if (amount > 1) {
                    _safeTokenTransfer({
                        creditAccount: creditAccount,
                        token: token,
                        to: to,
                        amount: amount - 1,
                        convertToETH: convertToETH
                    }); // U:[CM-31]
                }
            }
        }
    }

    /// @dev Transfers `amount` of `token` from `creditAccount` to `to`
    /// @dev If `convertToETH` is true and `token` is WETH, it will be transferred to the withdrawal manager,
    ///      from which the caller can later claim it as ETH to an arbitrary address
    /// @dev If transfer fails, the token will be transferred to withdrawal manager from which `to`
    ///      can later claim it to an arbitrary address (can be helpful for blacklistable tokens)
    function _safeTokenTransfer(address creditAccount, address token, address to, uint256 amount, bool convertToETH)
        internal
    {
        if (convertToETH && token == weth) {
            ICreditAccountBase(creditAccount).transfer({token: token, to: withdrawalManager, amount: amount}); // U:[CM-31, 32]
            _addImmediateWithdrawal({token: token, to: msg.sender, amount: amount}); // U:[CM-31, 32]
        } else {
            try ICreditAccountBase(creditAccount).safeTransfer({token: token, to: to, amount: amount}) {
                // U:[CM-31, 32, 33]
            } catch {
                uint256 delivered = ICreditAccountBase(creditAccount).transferDeliveredBalanceControl({
                    token: token,
                    to: withdrawalManager,
                    amount: amount
                }); // U:[CM-33]
                _addImmediateWithdrawal({token: token, to: to, amount: delivered}); // U:[CM-33]
            }
        }
    }

    /// @dev Returns amount of token that should be transferred to receive `amount`
    ///      Pools with fee-on-transfer underlying should override this method
    function _amountWithFee(uint256 amount) internal view virtual returns (uint256) {
        return amount;
    }

    /// @dev Returns amount of token that will be received if `amount` is transferred
    ///      Pools with fee-on-transfer underlying should override this method
    function _amountMinusFee(uint256 amount) internal view virtual returns (uint256) {
        return amount;
    }

    /// @dev Internal wrapper for `pool.calcLinearCumulative_RAY` call to reduce contract size
    function _poolCumulativeIndexNow() internal view returns (uint256) {
        return IPoolBase(pool).calcLinearCumulative_RAY();
    }

    /// @dev Internal wrapper for `pool.repayCreditAccount` call to reduce contract size
    function _poolRepayCreditAccount(uint256 debt, uint256 profit, uint256 loss) internal {
        IPoolBase(pool).repayCreditAccount(debt, profit, loss);
    }

    /// @dev Internal wrapper for `pool.lendCreditAccount` call to reduce contract size
    function _poolLendCreditAccount(uint256 amount, address creditAccount) internal {
        IPoolBase(pool).lendCreditAccount(amount, creditAccount); // F:[CM-20]
    }

    /// @dev Internal wrapper for `priceOracle.convertToUSD` call to reduce contract size
    function _convertToUSD(address _priceOracle, uint256 amountInToken, address token)
        internal
        view
        returns (uint256 amountInUSD)
    {
        amountInUSD = IPriceOracleBase(_priceOracle).convertToUSD(amountInToken, token);
    }

    /// @dev Internal wrapper for `priceOracle.convertFromUSD` call to reduce contract size
    function _convertFromUSD(address _priceOracle, uint256 amountInUSD, address token)
        internal
        view
        returns (uint256 amountInToken)
    {
        amountInToken = IPriceOracleBase(_priceOracle).convertFromUSD(amountInUSD, token);
    }

    /// @dev Internal wrapper for `withdrawalManager.addImmediateWithdrawal` call to reduce contract size
    function _addImmediateWithdrawal(address token, address to, uint256 amount) internal {
        IWithdrawalManagerV3(withdrawalManager).addImmediateWithdrawal({token: token, to: to, amount: amount});
    }
}
