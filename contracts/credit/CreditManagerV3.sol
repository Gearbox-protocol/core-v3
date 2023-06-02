// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

// LIBRARIES
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// LIBS & TRAITS
import {UNDERLYING_TOKEN_MASK, BitMask} from "../libraries/BitMask.sol";
import {CreditLogic} from "../libraries/CreditLogic.sol";
import {CollateralLogic} from "../libraries/CollateralLogic.sol";
import {CreditAccountHelper} from "../libraries/CreditAccountHelper.sol";

import {ReentrancyGuardTrait} from "../traits/ReentrancyGuardTrait.sol";
import {SanityCheckTrait} from "../traits/SanityCheckTrait.sol";
import {IERC20Helper} from "../libraries/IERC20Helper.sol";

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
    WITHDRAWAL_FLAG
} from "../interfaces/ICreditManagerV3.sol";
import "../interfaces/IAddressProviderV3.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracleV2.sol";
import {IPoolQuotaKeeperV3} from "../interfaces/IPoolQuotaKeeperV3.sol";

// CONSTANTS
import {
    DEFAULT_FEE_INTEREST,
    DEFAULT_FEE_LIQUIDATION,
    DEFAULT_LIQUIDATION_PREMIUM,
    PERCENTAGE_FACTOR
} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";
import "forge-std/console.sol";

/// @title Credit Manager
/// @dev Encapsulates the business logic for managing Credit Accounts
contract CreditManagerV3 is ICreditManagerV3, SanityCheckTrait, ReentrancyGuardTrait {
    using EnumerableSet for EnumerableSet.AddressSet;
    using BitMask for uint256;
    using CreditLogic for CollateralDebtData;
    using CollateralLogic for CollateralDebtData;
    using SafeERC20 for IERC20;
    using IERC20Helper for IERC20;
    using CreditAccountHelper for ICreditAccountBase;

    // IMMUTABLE PARAMS

    /// @inheritdoc IVersion
    uint256 public constant override version = 3_00;

    /// @notice Address provider
    /// @dev While not used in this contract outside the constructor,
    ///      it is routinely used by other connected contracts
    address public immutable override addressProvider;

    /// @notice Factory contract for Credit Accounts
    address public immutable accountFactory;

    /// @notice Address of the underlying asset
    address public immutable override underlying;

    /// @notice Address of the connected pool
    address public immutable override pool;

    /// @notice Address of WETH
    address public immutable override weth;

    /// @notice Whether the CM supports quota-related logic
    bool public immutable override supportsQuotas;

    /// @notice Address of the connected Credit Facade
    address public override creditFacade;

    /// @notice The maximal number of enabled tokens on a single Credit Account
    uint8 public override maxEnabledTokens = 12;

    /// @notice Liquidation threshold for the underlying token.
    uint16 internal ltUnderlying;

    /// @notice Interest fee charged by the protocol: fee = interest accrued * feeInterest (this includes quota interest)
    uint16 internal feeInterest;

    /// @notice Liquidation fee charged by the protocol: fee = totalValue * feeLiquidation
    uint16 internal feeLiquidation;

    /// @notice Multiplier used to compute the total value of funds during liquidation.
    /// At liquidation, the borrower's funds are discounted, and the pool is paid out of discounted value
    /// The liquidator takes the difference between the discounted and actual values as premium.
    uint16 internal liquidationDiscount;

    /// @notice Total number of known collateral tokens.
    uint8 public collateralTokensCount;

    /// @notice Liquidation fee charged by the protocol during liquidation by expiry. Typically lower than feeLiquidation.
    uint16 internal feeLiquidationExpired;

    /// @notice Multiplier used to compute the total value of funds during liquidation by expiry. Typically higher than
    /// liquidationDiscount (meaning lower premium).
    uint16 internal liquidationDiscountExpired;

    /// @notice Price oracle used to evaluate assets on Credit Accounts.
    address public override priceOracle;

    /// @notice Points to the currently processed Credit Account during multicall, otherwise keeps address(1) for gas savings
    /// CreditFacade is a trusted source, so it generally sends the CA as an input for account management functions
    /// _activeCreditAccount is used to avoid adapters having to manually pass the Credit Account
    address internal _activeCreditAccount;

    /// @notice Mask of tokens to apply quota logic for
    uint256 public override quotedTokensMask;

    /// @notice Contract that handles withdrawals
    address public immutable override withdrawalManager;

    /// @notice Address of the connected Credit Configurator
    address public creditConfigurator;

    /// COLLATERAL TOKENS DATA

    /// @notice Map of token's bit mask to its address and LT parameters in a single-slot struct
    mapping(uint256 => CollateralTokenData) internal collateralTokensData;

    /// @notice Internal map of token addresses to their indidivual masks.
    /// @dev A mask is a uint256 that has only 1 non-zero bit in the position corresponding to
    ///         the token's index (i.e., tokenMask = 2 ** index)
    ///         Masks are used to efficiently track set inclusion, since it only involves
    ///         a single AND and comparison to zero
    mapping(address => uint256) internal tokenMasksMapInternal;

    /// CONTRACTS & ADAPTERS

    /// @notice Maps allowed adapters to their respective target contracts.
    mapping(address => address) public override adapterToContract;

    /// @notice Maps 3rd party contracts to their respective adapters
    mapping(address => address) public override contractToAdapter;

    /// CREDIT ACCOUNT DATA

    /// @notice Contains infomation related to CA, such as accumulated interest,
    ///         enabled tokens, the current borrower and miscellaneous flags
    mapping(address => CreditAccountInfo) public creditAccountInfo;

    /// @notice Set of all currently active contracts
    EnumerableSet.AddressSet internal creditAccountsSet;

    //
    // MODIFIERS
    //

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

    /// @notice Constructor
    /// @param _addressProvider Address of the repository to get system-level contracts from
    /// @param _pool Address of the pool to borrow funds from
    constructor(address _addressProvider, address _pool) {
        addressProvider = _addressProvider;
        pool = _pool; // U:[CM-1]

        underlying = IPoolBase(_pool).underlyingToken(); // U:[CM-1]

        try IPoolV3(_pool).supportsQuotas() returns (bool sq) {
            supportsQuotas = sq; // I:[CMQ-1]
        } catch {}

        // The underlying is the first token added as collateral
        _addToken(underlying); // U:[CM-1]

        weth =
            IAddressProviderV3(addressProvider).getAddressOrRevert({key: AP_WETH_TOKEN, _version: NO_VERSION_CONTROL}); // U:[CM-1]
        priceOracle = IAddressProviderV3(addressProvider).getAddressOrRevert({key: AP_PRICE_ORACLE, _version: 2}); // U:[CM-1]
        accountFactory = IAddressProviderV3(addressProvider).getAddressOrRevert({
            key: AP_ACCOUNT_FACTORY,
            _version: NO_VERSION_CONTROL
        }); // U:[CM-1]
        withdrawalManager =
            IAddressProviderV3(addressProvider).getAddressOrRevert({key: AP_WITHDRAWAL_MANAGER, _version: 3_00}); // U:[CM-1]

        creditConfigurator = msg.sender; // U:[CM-1]

        _activeCreditAccount = address(1);
    }

    //
    // CREDIT ACCOUNT MANAGEMENT
    //

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
        nonZeroAddress(onBehalfOf) // todo: add check
        nonReentrant // U:[CM-5]
        creditFacadeOnly // // U:[CM-2]
        returns (address creditAccount)
    {
        creditAccount = IAccountFactoryBase(accountFactory).takeCreditAccount(0, 0); // U:[CM-6]

        CreditAccountInfo storage newCreditAccountInfo = creditAccountInfo[creditAccount];

        newCreditAccountInfo.debt = debt; // U:[CM-6]
        newCreditAccountInfo.cumulativeIndexLastUpdate = _poolCumulativeIndexNow(); // U:[CM-6]

        // newCreditAccountInfo.since = uint64(block.number); // U:[CM-6]
        // newCreditAccountInfo.flags = 0; // U:[CM-6]
        // newCreditAccountInfo.borrower = onBehalfOf; // U:[CM-6]
        assembly {
            let slot := add(newCreditAccountInfo.slot, 4)
            let value := or(shl(80, onBehalfOf), shl(16, number()))
            sstore(slot, value)
        }

        if (supportsQuotas) {
            //     newCreditAccountInfo.cumulativeQuotaInterest = 1;
            //     newCreditAccountInfo.quotaProfits = 0;
            assembly {
                let slot := add(newCreditAccountInfo.slot, 2)
                sstore(slot, 1)
            } // U:[CM-6]
        }

        // Requests the pool to transfer tokens the Credit Account
        _poolLendCreditAccount(debt, creditAccount); // U:[CM-6]
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
        address borrower = getBorrowerOrRevert(creditAccount); // U:[CM-7]

        {
            CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[creditAccount];

            if (currentCreditAccountInfo.since == block.number) revert OpenCloseAccountInOneBlockException();

            // Sets borrower's Credit Account to zero address
            // delete creditAccountInfo[creditAccount].borrower; // U:[CM-8]
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

            (amountToPool, remainingFunds, profit, loss) = collateralDebtData.calcLiquidationPayments({
                liquidationDiscount: closureAction == ClosureAction.LIQUIDATE_ACCOUNT
                    ? liquidationDiscount
                    : liquidationDiscountExpired,
                feeLiquidation: closureAction == ClosureAction.LIQUIDATE_ACCOUNT ? feeLiquidation : feeLiquidationExpired,
                amountWithFeeFn: _amountWithFee,
                amountMinusFeeFn: _amountMinusFee
            }); // U:[CM-8]
        }
        {
            uint256 underlyingBalance = IERC20Helper.balanceOf({token: underlying, holder: creditAccount}); // U:[CM-8]

            // If there is an underlying shortfall, attempts to transfer it from the payer
            if (underlyingBalance < amountToPool + remainingFunds + 1) {
                unchecked {
                    IERC20(underlying).safeTransferFrom({
                        from: payer,
                        to: creditAccount,
                        value: _amountWithFee(amountToPool + remainingFunds + 1 - underlyingBalance)
                    }); // U:[CM-8]
                }
            }
        }

        // Transfers the due funds to the pool
        ICreditAccountBase(creditAccount).transfer({token: underlying, to: pool, amount: amountToPool}); // U:[CM-8]

        // Signals to the pool that debt has been repaid. The pool relies
        // on the Credit Manager to repay the debt correctly, and does not
        // check internally whether the underlying was actually transferred
        _poolRepayCreditAccount(collateralDebtData.debt, profit, loss); // U:[CM-8]

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

        // If the creditAccount has non-zero quotas, they need to be reduced to 0;
        // This is required to both free quota limits for other users and correctly
        // compute quota interest
        if (supportsQuotas && collateralDebtData.quotedTokens.length != 0) {
            /// In case of any loss, PQK sets limits to zero for all quoted tokens
            bool setLimitsToZero = loss > 0; // U:[CM-8] // I:[CMQ-8]

            IPoolQuotaKeeperV3(collateralDebtData._poolQuotaKeeper).removeQuotas({
                creditAccount: creditAccount,
                tokens: collateralDebtData.quotedTokens,
                setLimitsToZero: setLimitsToZero
            }); // U:[CM-8] I:[CMQ-6]
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
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 newDebt, uint256 tokensToEnable, uint256 tokensToDisable)
    {
        uint256[] memory collateralHints;
        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[creditAccount];

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

            // Pays the entire amount back to the pool
            ICreditAccountBase(creditAccount).transfer({token: underlying, to: pool, amount: amount}); // U:[CM-11]

            uint128 newCumulativeQuotaInterest;
            uint128 newQuotaProfits;
            {
                uint256 profit;

                uint128 quotaProfits = (supportsQuotas) ? currentCreditAccountInfo.quotaProfits : 0;

                (newDebt, newCumulativeIndex, profit, newCumulativeQuotaInterest, newQuotaProfits) = CreditLogic
                    .calcDecrease({
                    amount: _amountMinusFee(amount),
                    debt: collateralDebtData.debt,
                    cumulativeIndexNow: collateralDebtData.cumulativeIndexNow,
                    cumulativeIndexLastUpdate: collateralDebtData.cumulativeIndexLastUpdate,
                    cumulativeQuotaInterest: collateralDebtData.cumulativeQuotaInterest,
                    quotaProfits: quotaProfits,
                    feeInterest: feeInterest
                }); // U:[CM-11]

                /// @dev The amount of principal repaid is what is left after repaying all interest and fees
                ///      and is the difference between newDebt and debt
                _poolRepayCreditAccount(collateralDebtData.debt - newDebt, profit, 0); // U:[CM-11]
            }

            /// If quota logic is supported, we need to accrue quota interest in order to keep
            /// quota interest indexes in PQK and cumulativeQuotaInterest in Credit Manager consistent
            /// with each other, since this action caches all quota interest in Credit Manager
            if (supportsQuotas) {
                IPoolQuotaKeeperV3(collateralDebtData._poolQuotaKeeper).accrueQuotaInterest({
                    creditAccount: creditAccount,
                    tokens: collateralDebtData.quotedTokens
                });

                currentCreditAccountInfo.cumulativeQuotaInterest = newCumulativeQuotaInterest + 1; // U:[CM-11]
                currentCreditAccountInfo.quotaProfits = newQuotaProfits;
            }

            /// If the entire underlying balance was spent on repayment, it is disabled
            if (IERC20Helper.balanceOf({token: underlying, holder: creditAccount}) <= 1) {
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
    function addCollateral(address payer, address creditAccount, address token, uint256 amount)
        external
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 tokenMask)
    {
        tokenMask = getTokenMaskOrRevert({token: token}); // U:[CM-13]
        IERC20(token).safeTransferFrom({from: payer, to: creditAccount, value: amount}); // U:[CM-13]
    }

    ///
    /// APPROVALS
    ///

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
                uint256 allowance = IERC20(token).allowance(creditAccount, spender); // U:[CM-15]
                /// It checks that token is in collateral token list in _approveSpender function
                if (allowance > 1) {
                    _approveSpender({creditAccount: creditAccount, token: token, spender: spender, amount: 0}); // U:[CM-15]
                }
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
        _activeCreditAccount = creditAccount;
    }

    /// @notice Returns the current active credit account
    function getActiveCreditAccountOrRevert() public view override returns (address creditAccount) {
        creditAccount = _activeCreditAccount;
        if (creditAccount == address(1)) revert ActiveCreditAccountNotSetException();
    }

    //
    // COLLATERAL VALIDITY AND ACCOUNT HEALTH CHECKS
    //

    /// @notice Performs a full health check on an account with a custom order of evaluated tokens and
    ///      a custom minimal health factor
    /// @param creditAccount Address of the Credit Account to check
    /// @param enabledTokensMask Current enabled token mask
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
    ///                        consider the account unhealthy
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
        ///      prevented from being called internally
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
        if (supportsQuotas) {
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
            collateralDebtData.accruedFees = currentCreditAccountInfo.quotaProfits;
        }

        collateralDebtData.accruedInterest += CreditLogic.calcAccruedInterest({
            amount: collateralDebtData.debt,
            cumulativeIndexLastUpdate: collateralDebtData.cumulativeIndexLastUpdate,
            cumulativeIndexNow: collateralDebtData.cumulativeIndexNow
        }); // U:[CM-21] // I: [CMQ-07]

        collateralDebtData.accruedFees += (collateralDebtData.accruedInterest * feeInterest) / PERCENTAGE_FACTOR; // U:[CM-21]

        if (task == CollateralCalcTask.DEBT_ONLY) return collateralDebtData; // U:[CM-21]

        /// COLLATERAL
        /// Collateral values such as total value / total weighted value are computed and saved into the struct
        /// And zero-balance tokens encountered are removed from enabledTokensMask inside the struct as well
        /// If the task is FULL_COLLATERAL_CHECK_LAZY, then collateral value are only computed until twvUSD > totalDebtUSD,
        /// and any extra collateral on top of that is not included into the account's value
        address _priceOracle = priceOracle;

        collateralDebtData.totalDebtUSD = _convertToUSD({
            _priceOracle: _priceOracle,
            amountInToken: collateralDebtData.calcTotalDebt(),
            token: underlying
        }); // U:[CM-22]

        /// The logic for computing collateral is isolated into the `CreditLogic` library. See `CreditLogic.calcCollateral` for details.
        uint256 tokensToDisable;

        /// The limit is a TWV threshold at which lazy computation stops. Normally, it happens when TWV
        /// exceeds the total debt, but the user can also configure a custom HF threshold (above 1),
        /// in order to maintain a desired level of position health
        uint256 limit = (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY)
            ? collateralDebtData.totalDebtUSD * minHealthFactor / PERCENTAGE_FACTOR
            : type(uint256).max;

        (collateralDebtData.totalValueUSD, collateralDebtData.twvUSD, tokensToDisable) = collateralDebtData
            .calcCollateral({
            creditAccount: creditAccount,
            underlying: underlying,
            limit: limit,
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
    /// @param _poolQuotaKeeper The PoolQuotaKeeper contract storing the quota and quota interest data
    /// @return quotaTokens An array of address of quoted tokens on the Credit Account
    /// @return outstandingQuotaInterest Quota interest that has not been saved in the Credit Manager
    /// @return quotasPacked Current quotas on quoted tokens packet with their lts
    /// @return _quotedTokensMask The mask of enabled quoted tokens on the account
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
                for (uint256 i; tokensToCheckMask != 0; ++i) {
                    uint256 tokenMask;

                    tokenMask = (i < len) ? collateralHints[i] : 1 << (i - len);

                    if (tokensToCheckMask & tokenMask != 0) {
                        (address token, uint16 lt) = _collateralTokenByMask({tokenMask: tokenMask, calcLT: true}); // U:[CM-24]

                        (uint256 quota, uint128 outstandingInterestDelta) =
                            IPoolQuotaKeeperV3(_poolQuotaKeeper).getQuotaAndOutstandingInterest(ca, token); // U:[CM-24]

                        quotaTokens[j] = token; // U:[CM-24]
                        quotasPacked[j] = CollateralLogic.packQuota(uint96(quota), lt);

                        /// Quota interest is equal to quota * APY * time. Since quota is a uint96, this is unlikely to overflow in any realistic scenario.
                        outstandingQuotaInterest += outstandingInterestDelta; // U:[CM-24]

                        ++j; // U:[CM-24]
                    }
                    tokensToCheckMask = tokensToCheckMask.disable(tokenMask);
                }
            }
        }
    }

    //
    // QUOTAS MANAGEMENT
    //

    /// @notice Updates credit account's quotas for multiple tokens
    /// @param creditAccount Address of credit account
    /// @param token Address of quoted token
    /// @param quotaChange Change in quota in SIGNED format
    function updateQuota(address creditAccount, address token, int96 quotaChange, uint96 minQuota, uint96 maxQuota)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (int96 realQuotaChange, uint256 tokensToEnable, uint256 tokensToDisable)
    {
        /// The PoolQuotaKeeper returns the interest to be cached (quota interest is computed dynamically,
        /// so the cumulative index inside PQK needs to be updated before setting the new quota value).
        /// PQK also reports whether the quota was changed from zero to non-zero and vice versa, in order to
        /// safely enable and disable quoted tokens
        uint128 caInterestChange;
        bool enable;
        bool disable;
        uint128 tradingFees;

        (caInterestChange, tradingFees, realQuotaChange, enable, disable) = IPoolQuotaKeeperV3(poolQuotaKeeper())
            .updateQuota({
            creditAccount: creditAccount,
            token: token,
            quotaChange: quotaChange,
            minQuota: minQuota,
            maxQuota: maxQuota
        }); // U:[CM-25] // I: [CMQ-3]

        if (enable) {
            tokensToEnable = getTokenMaskOrRevert(token); // U:[CM-25]
        } else if (disable) {
            tokensToDisable = getTokenMaskOrRevert(token); // U:[CM-25]
        }

        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[creditAccount];

        currentCreditAccountInfo.cumulativeQuotaInterest += caInterestChange; // U:[CM-25] // I: [CMQ-3]

        if (tradingFees != 0) {
            currentCreditAccountInfo.quotaProfits += tradingFees;
        }
    }

    ///
    /// WITHDRAWALS
    ///

    /// @notice Schedules a delayed withdrawal of an asset from the account.
    /// @dev Withdrawals in Gearbox V3 are generally delayed for safety, and an intermediate WithdrawalManagerV3 contract
    ///      is used to store funds pending a withdrawal. When the withdrawal matures, a corresponding `claimWithdrawals` function
    ///      can be used to receive them outside the Gearbox system.
    /// @param creditAccount Credit Account to schedule a withdrawal for
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw
    function scheduleWithdrawal(address creditAccount, address token, uint256 amount)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 tokensToDisable)
    {
        uint256 tokenMask = getTokenMaskOrRevert({token: token}); // U:[CM-26]

        // If the configured delay is zero, then sending funds to the WithdrawalManagerV3 can be skipped
        // and they can be sent directly to the user
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

            // WITHDRAWAL_FLAG is enabled on the account to efficiently determine
            // whether the account has pending withdrawals in the future
            _enableFlag({creditAccount: creditAccount, flag: WITHDRAWAL_FLAG});
        }

        if (IERC20Helper.balanceOf({token: token, holder: creditAccount}) <= 1) {
            tokensToDisable = tokenMask; // U:[CM-27]
        }
    }

    /// @notice Resolves pending withdrawals, with logic dependent on the passed action.
    /// @param creditAccount Credit Account to claim withdrawals for
    /// @param to Address to claim withdrawals to
    /// @param action Action to perform:
    ///               * CLAIM - claims mature withdrawals to `to`, leaving immature withdrawals as-is
    ///               * CANCEL - claims mature withdrawals and returns immature withdrawals to the credit account
    ///               * FORCE_CLAIM - claims all pending withdrawals, regardless of maturity
    ///               * FORCE_CANCEL - returns all pending withdrawals to the Credit Account regardless of maturity
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
                // WITHDRAWAL_FLAG is disabled when there are no more pending withdrawals
                _disableFlag(creditAccount, WITHDRAWAL_FLAG); // U:[CM-29]
            }
        }
    }

    /// @notice Computes the value of cancellable withdrawals to add to Credit Account value
    /// @param _priceOracle Price Oracle to compute the value of withdrawn assets
    /// @param creditAccount Credit Account to compute value for
    /// @param isForceCancel Whether to cancel all withdrawals or only immature ones
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

    //
    // TRANSFER HELPERS
    //

    /// @notice Transfers all enabled assets from a Credit Account to the "to" address
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
            for (
                uint256 tokenMask = UNDERLYING_TOKEN_MASK; tokenMask <= tokensToTransferMask; tokenMask = tokenMask << 1
            ) {
                // enabledTokensMask & tokenMask == tokenMask when the token is enabled, and 0 otherwise
                if (tokensToTransferMask & tokenMask != 0) {
                    address token = getTokenByMask(tokenMask); // U:[CM-31]
                    uint256 amount = IERC20Helper.balanceOf({token: token, holder: creditAccount}); // U:[CM-31]
                    if (amount > 1) {
                        // 1 is subtracted from amount to leave a non-zero value in the balance mapping, optimizing future writes
                        // Since the amount is checked to be more than 1, the block can be marked as unchecked
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
    }

    /// @notice Requests the Credit Account to transfer a token to another address
    ///         If transfer fails (e.g., `to` gets blacklisted in the token), the token will be transferred
    ///         to withdrawal manager from which `to` can later claim it to an arbitrary address.
    /// @param creditAccount Address of the sender Credit Account
    /// @param token Address of the token
    /// @param to Recipient address
    /// @param amount Amount to transfer
    /// @param convertToETH If true, WETH will be transferred to withdrawal manager, from which Credit Facade can
    ///        claim it as ETH later in the transaction (ignored if token is not WETH)
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

    //
    // GETTERS
    //

    /// @notice Returns the mask for the provided token
    /// @param token Token to returns the mask for
    function getTokenMaskOrRevert(address token) public view override returns (uint256 tokenMask) {
        tokenMask = (token == underlying) ? 1 : tokenMasksMapInternal[token]; // U:[CM-34]
        if (tokenMask == 0) revert TokenNotAllowedException(); // U:[CM-34]
    }

    /// @notice Returns the collateral token with requested mask
    /// @param tokenMask Token mask corresponding to the token
    function getTokenByMask(uint256 tokenMask) public view override returns (address token) {
        (token,) = _collateralTokenByMask({tokenMask: tokenMask, calcLT: false}); // U:[CM-34]
    }

    /// @notice Returns the liquidation threshold for the provided token
    /// @param token Token to retrieve the LT for
    function liquidationThresholds(address token) public view override returns (uint16 lt) {
        uint256 tokenMask = getTokenMaskOrRevert(token);
        (, lt) = _collateralTokenByMask({tokenMask: tokenMask, calcLT: true}); // U:[CM-42]
    }

    /// @notice Returns the collateral token with requested mask and its liquidationThreshold
    /// @param tokenMask Token mask corresponding to the token
    function collateralTokenByMask(uint256 tokenMask)
        public
        view
        override
        returns (address token, uint16 liquidationThreshold)
    {
        return _collateralTokenByMask({tokenMask: tokenMask, calcLT: true}); // U:[CM-34, 42]
    }

    /// @notice Returns the collateral token with requested mask and its liquidationThreshold
    /// @param tokenMask Token mask corresponding to the token
    function _collateralTokenByMask(uint256 tokenMask, bool calcLT)
        internal
        view
        returns (address token, uint16 liquidationThreshold)
    {
        // The underlying is a special case and its mask is always 1
        if (tokenMask == 1) {
            token = underlying; // U:[CM-34]
            liquidationThreshold = ltUnderlying; // U:[CM-35]
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

                // The logic to calculate a ramping LT is isolated to the `CreditLogic` library.
                // See `CreditLogic.getLiquidationThreshold()` for details.
                liquidationThreshold = CreditLogic.getLiquidationThreshold({
                    ltInitial: ltInitial,
                    ltFinal: ltFinal,
                    timestampRampStart: timestampRampStart,
                    rampDuration: rampDuration
                }); // U:[CM-42]
            }
        }
    }

    /// @notice Returns the fee parameters of the Credit Manager
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
        _feeInterest = feeInterest; // U:[CM-41]
        _feeLiquidation = feeLiquidation; // U:[CM-41]
        _liquidationDiscount = liquidationDiscount; // U:[CM-41]
        _feeLiquidationExpired = feeLiquidationExpired; // U:[CM-41]
        _liquidationDiscountExpired = liquidationDiscountExpired; // U:[CM-41]
    }

    /// @notice Address of the connected pool
    /// @dev [DEPRECATED]: use pool() instead.
    function poolService() external view returns (address) {
        return pool; // U:[CM-1]
    }

    /// @notice Adress of the connected PoolQuotaKeeper
    /// @dev PoolQuotaKeeper is a contract that manages token quota parameters
    ///      and computes quota interest. Since quota interest is paid directly to the pool,
    ///      this contract is responsible for aligning quota interest values between the
    ///      pool, gauge and the Credit Manager
    function poolQuotaKeeper() public view returns (address) {
        return IPoolV3(pool).poolQuotaKeeper(); // U:[CM-47]
    }

    ///
    /// CREDIT ACCOUNT INFO
    ///

    /// @notice Returns the owner of the provided CA, or reverts if there is none
    /// @param creditAccount Credit Account to get the borrower for
    function getBorrowerOrRevert(address creditAccount) public view override returns (address borrower) {
        borrower = creditAccountInfo[creditAccount].borrower; // U:[CM-35]
        if (borrower == address(0)) revert CreditAccountNotExistsException(); // U:[CM-35]
    }

    /// @notice Returns the mask containing miscellaneous account flags
    /// @dev Currently, the following flags are supported:
    ///      * 1 - WITHDRAWALS_FLAG - whether the account has pending withdrawals
    ///      * 2 - BOT_PERMISSIONS_FLAG - whether the account has non-zero permissions for at least one bot
    /// @param creditAccount Account to get the mask for
    function flagsOf(address creditAccount) public view override returns (uint16) {
        return creditAccountInfo[creditAccount].flags; // U:[CM-35]
    }

    /// @notice Sets a flag for a Credit Account
    /// @param creditAccount Account to set a flag for
    /// @param flag Flag to set
    /// @param value The new flag value
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

    /// @notice Sets the flag in the CA's flag mask to 1
    function _enableFlag(address creditAccount, uint16 flag) internal {
        creditAccountInfo[creditAccount].flags |= flag; // U:[CM-36]
    }

    /// @notice Sets the flag in the CA's flag mask to 0
    function _disableFlag(address creditAccount, uint16 flag) internal {
        creditAccountInfo[creditAccount].flags &= ~flag; // U:[CM-36]
    }

    /// @notice Efficiently checks whether the CA has pending withdrawals using the flag
    function _hasWithdrawals(address creditAccount) internal view returns (bool) {
        return flagsOf(creditAccount) & WITHDRAWAL_FLAG != 0; // U:[CM-36]
    }

    /// @notice Returns the mask containing the account's enabled tokens
    /// @param creditAccount Credit Account to get the mask for
    function enabledTokensMaskOf(address creditAccount) public view override returns (uint256) {
        return creditAccountInfo[creditAccount].enabledTokensMask; // U:[CM-37]
    }

    /// @notice Checks quantity of enabled tokens and saves the mask to creditAccountInfo

    function _saveEnabledTokensMask(address creditAccount, uint256 enabledTokensMask) internal {
        if (enabledTokensMask.calcEnabledTokens() > maxEnabledTokens) {
            revert TooManyEnabledTokensException(); // U:[CM-37]
        }

        creditAccountInfo[creditAccount].enabledTokensMask = enabledTokensMask; // U:[CM-37]
    }

    ///
    /// FEE TOKEN SUPPORT
    ///

    /// @notice Returns the amount that needs to be transferred to get exactly `amount` delivered
    /// @dev Can be overriden in inheritor contracts to support tokens with fees (such as USDT)
    function _amountWithFee(uint256 amount) internal view virtual returns (uint256) {
        return amount;
    }

    /// @notice Returns the amount that will be delivered after `amount` is tranferred
    /// @dev Can be overriden in inheritor contracts to support tokens with fees (such as USDT)
    function _amountMinusFee(uint256 amount) internal view virtual returns (uint256) {
        return amount;
    }

    ///
    /// CREDIT ACCOUNTS
    ///

    /// @notice Returns the full set of currently active Credit Accounts
    function creditAccounts() external view override returns (address[] memory) {
        return creditAccountsSet.values();
    }

    //
    // CONFIGURATION
    //
    // The following functions change vital Credit Manager parameters
    // and can only be called by the Credit Configurator
    //

    /// @notice Adds a token to the list of collateral tokens
    /// @param token Address of the token to add
    function addToken(address token)
        external
        creditConfiguratorOnly // U:[CM-4]
    {
        _addToken(token); // U:[CM-38, 39]
    }

    /// @notice IMPLEMENTATION: addToken
    /// @param token Address of the token to add
    function _addToken(address token) internal {
        // Checks that the token is not already known (has an associated token mask)
        if (tokenMasksMapInternal[token] != 0) {
            revert TokenAlreadyAddedException(); // U:[CM-38]
        }

        // Checks that there aren't too many tokens
        // Since token masks are 255 bit numbers with each bit corresponding to 1 token,
        // only at most 255 are supported
        if (collateralTokensCount >= 255) revert TooManyTokensException(); // U:[CM-38]

        // The tokenMask of a token is a bit mask with 1 at position corresponding to its index
        // (i.e. 2 ** index or 1 << index)
        uint256 tokenMask = 1 << collateralTokensCount; // U:[CM-39]
        tokenMasksMapInternal[token] = tokenMask; // U:[CM-39]

        collateralTokensData[tokenMask].token = token; // U:[CM-39]
        collateralTokensData[tokenMask].timestampRampStart = type(uint40).max; // U:[CM-39]

        unchecked {
            ++collateralTokensCount; // U:[CM-39]
        }
    }

    /// @notice Sets fees and premiums
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
        feeInterest = _feeInterest; // U:[CM-40]
        feeLiquidation = _feeLiquidation; // U:[CM-40]
        liquidationDiscount = _liquidationDiscount; // U:[CM-40]
        feeLiquidationExpired = _feeLiquidationExpired; // U:[CM-40]
        liquidationDiscountExpired = _liquidationDiscountExpired; // U:[CM-40]
    }

    /// @notice Sets ramping parameters for a token's liquidation threshold
    /// @dev Ramping parameters allow to decrease the LT gradually over a period of time
    ///         which gives users/bots time to react and adjust their position for the new LT
    /// @dev A static LT can be forced by setting ltInitial to desired LT and setting timestampRampStart to unit40.max
    /// @param token The collateral token to set the LT for
    /// todo: add ltInitial
    /// @param ltFinal The final LT after ramping
    /// @param timestampRampStart Timestamp when the LT starts ramping
    /// @param rampDuration Duration of ramping
    function setCollateralTokenData(
        address token,
        uint16 ltInitial,
        uint16 ltFinal,
        uint40 timestampRampStart,
        uint24 rampDuration
    )
        external
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

    /// @notice Sets the quoted token mask
    /// @param _quotedTokensMask The new mask
    /// @dev Quoted tokens are counted as collateral not only based on their balances,
    ///         but also on their quotas set in thePpoolQuotaKeeper contract
    ///         Tokens in the mask also incur additional interest based on their quotas
    function setQuotedMask(uint256 _quotedTokensMask)
        external
        creditConfiguratorOnly // U:[CM-4]
    {
        quotedTokensMask = _quotedTokensMask & (type(uint256).max - 1); // U:[CM-43]
    }

    /// @notice Sets the maximal number of enabled tokens on a single Credit Account.
    /// @param _maxEnabledTokens The new enabled token quantity limit.
    function setMaxEnabledTokens(uint8 _maxEnabledTokens)
        external
        creditConfiguratorOnly // U: [CM-4]
    {
        maxEnabledTokens = _maxEnabledTokens; // U:[CM-44]
    }

    /// @notice Sets the link between an adapter and its corresponding targetContract
    /// @param adapter Address of the adapter to be used to access the target contract
    /// @param targetContract A 3rd-party contract for which the adapter is set
    /// @dev The function can be called with (adapter, address(0)) and (address(0), targetContract)
    ///         to disallow a particular target or adapter, since this would set values in respective
    ///         mappings to address(0).
    function setContractAllowance(address adapter, address targetContract)
        external
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

    /// @notice Sets the Credit Facade
    /// @param _creditFacade Address of the new Credit Facade
    function setCreditFacade(address _creditFacade)
        external
        creditConfiguratorOnly // U: [CM-4]
    {
        creditFacade = _creditFacade; // U:[CM-46]
    }

    /// @notice Sets the Price Oracle
    /// @param _priceOracle Address of the new Price Oracle
    function setPriceOracle(address _priceOracle)
        external
        creditConfiguratorOnly // U: [CM-4]
    {
        priceOracle = _priceOracle; // U:[CM-46]
    }

    /// @notice Sets a new Credit Configurator
    /// @param _creditConfigurator Address of the new Credit Configurator
    function setCreditConfigurator(address _creditConfigurator)
        external
        creditConfiguratorOnly // U: [CM-4]
    {
        creditConfigurator = _creditConfigurator; // U:[CM-46]
        emit SetCreditConfigurator(_creditConfigurator); // U:[CM-46]
    }

    ///
    /// EXTERNAL CALLS HELPERS
    ///

    //
    // POOL HELPERS
    //

    /// @notice Returns the current pool cumulative index
    function _poolCumulativeIndexNow() internal view returns (uint256) {
        return IPoolBase(pool).calcLinearCumulative_RAY();
    }

    /// @notice Notifies the pool that there was a debt repayment
    /// @param debt Amount of debt principal repaid
    /// @param profit Amount of treasury earned (if any)
    /// @param loss Amount of loss incurred (if any)
    function _poolRepayCreditAccount(uint256 debt, uint256 profit, uint256 loss) internal {
        IPoolBase(pool).repayCreditAccount(debt, profit, loss);
    }

    /// @notice Requests the pool to lend funds to a Credit Account
    /// @param amount Amount of funds to lend
    /// @param creditAccount Address of the Credit Account to lend to
    function _poolLendCreditAccount(uint256 amount, address creditAccount) internal {
        IPoolBase(pool).lendCreditAccount(amount, creditAccount); // F:[CM-20]
    }

    //
    // PRICE ORACLE
    //

    /// @notice Returns the value of a token amount in USD
    /// @param _priceOracle Price oracle to query for token value
    /// @param amountInToken Amount of token to convert
    /// @param token Token to convert
    function _convertToUSD(address _priceOracle, uint256 amountInToken, address token)
        internal
        view
        returns (uint256 amountInUSD)
    {
        amountInUSD = IPriceOracleV2(_priceOracle).convertToUSD(amountInToken, token);
    }

    /// @notice Returns amount of token after converting from a provided USD amount
    /// @param _priceOracle Price oracle to query for token value
    /// @param amountInUSD USD amount to convert
    /// @param token Token to convert to
    function _convertFromUSD(address _priceOracle, uint256 amountInUSD, address token)
        internal
        view
        returns (uint256 amountInToken)
    {
        amountInToken = IPriceOracleV2(_priceOracle).convertFromUSD(amountInUSD, token);
    }

    //
    // WITHDRAWAL MANAGER
    //

    /// @dev Internal wrapper for `addImmediateWithdrawal` to reduce contract size
    function _addImmediateWithdrawal(address token, address to, uint256 amount) internal {
        IWithdrawalManagerV3(withdrawalManager).addImmediateWithdrawal({token: token, to: to, amount: amount});
    }
}
