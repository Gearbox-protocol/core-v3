// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

// THIRD-PARTY
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
import {IPoolV3} from "../interfaces/IPoolV3.sol";
import {
    ICreditManagerV3,
    CollateralTokenData,
    ManageDebtAction,
    CreditAccountInfo,
    RevocationPair,
    CollateralDebtData,
    CollateralCalcTask,
    DEFAULT_MAX_ENABLED_TOKENS,
    INACTIVE_CREDIT_ACCOUNT_ADDRESS
} from "../interfaces/ICreditManagerV3.sol";
import "../interfaces/IAddressProviderV3.sol";
import {IPriceOracleV3} from "../interfaces/IPriceOracleV3.sol";
import {IPoolQuotaKeeperV3} from "../interfaces/IPoolQuotaKeeperV3.sol";

// CONSTANTS
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

/// @title Credit manager V3
/// @notice Credit manager implements core logic for credit accounts management.
///         The contract itself is not open to neither external users nor the DAO: users should use `CreditFacadeV3`
///         to open accounts and perform interactions with external protocols, while the DAO can configure manager
///         params using `CreditConfiguratorV3`. Both mentioned contracts perform some important safety checks.
contract CreditManagerV3 is ICreditManagerV3, SanityCheckTrait, ReentrancyGuardTrait {
    using EnumerableSet for EnumerableSet.AddressSet;
    using BitMask for uint256;
    using Math for uint256;
    using CreditLogic for CollateralDebtData;
    using CollateralLogic for CollateralDebtData;
    using SafeERC20 for IERC20;
    using CreditAccountHelper for ICreditAccountBase;

    /// @notice Contract version
    uint256 public constant override version = 3_01;

    /// @notice Address provider contract address
    address public immutable override addressProvider;

    /// @notice Account factory contract address
    address public immutable override accountFactory;

    /// @notice Underlying token address
    address public immutable override underlying;

    /// @notice Address of the pool credit manager is connected to
    address public immutable override pool;

    /// @notice Address of the connected credit facade
    address public override creditFacade;

    /// @notice Address of the connected credit configurator
    address public override creditConfigurator;

    /// @notice Price oracle contract address
    address public override priceOracle;

    /// @notice Maximum number of tokens that a credit account can have enabled as collateral
    uint8 public override maxEnabledTokens = DEFAULT_MAX_ENABLED_TOKENS;

    /// @notice Number of known collateral tokens
    uint8 public override collateralTokensCount;

    /// @dev Liquidation threshold for the underlying token in bps
    uint16 internal ltUnderlying;

    /// @dev Percentage of accrued interest in bps taken by the protocol as profit
    uint16 internal feeInterest;

    /// @dev Percentage of liquidated account value in bps taken by the protocol as profit
    uint16 internal feeLiquidation;

    /// @dev Percentage of liquidated account value in bps that is used to repay debt
    uint16 internal liquidationDiscount;

    /// @dev Percentage of liquidated expired account value in bps taken by the protocol as profit
    uint16 internal feeLiquidationExpired;

    /// @dev Percentage of liquidated expired account value in bps that is used to repay debt
    uint16 internal liquidationDiscountExpired;

    /// @dev Active credit account which is an account adapters can interfact with
    address internal _activeCreditAccount = INACTIVE_CREDIT_ACCOUNT_ADDRESS;

    /// @notice Bitmask of quoted tokens
    uint256 public override quotedTokensMask;

    /// @dev Mapping collateral token mask => data (packed address and LT parameters)
    mapping(uint256 => CollateralTokenData) internal collateralTokensData;

    /// @dev Mapping collateral token address => mask
    mapping(address => uint256) internal tokenMasksMapInternal;

    /// @notice Mapping adapter => target contract
    mapping(address => address) public override adapterToContract;

    /// @notice Mapping target contract => adapter
    mapping(address => address) public override contractToAdapter;

    /// @notice Mapping credit account => account info (owner, debt amount, etc.)
    mapping(address => CreditAccountInfo) public override creditAccountInfo;

    /// @dev Set of all credit accounts opened in this credit manager
    EnumerableSet.AddressSet internal creditAccountsSet;

    /// @notice Credit manager name
    string public override name;

    /// @dev Ensures that function caller is the credit facade
    modifier creditFacadeOnly() {
        _checkCreditFacade();
        _;
    }

    /// @dev Ensures that function caller is the credit configurator
    modifier creditConfiguratorOnly() {
        _checkCreditConfigurator();
        _;
    }

    /// @notice Constructor
    /// @param _addressProvider Address provider contract address
    /// @param _pool Address of the lending pool to connect this credit manager to
    /// @param _name Credit manager name
    /// @dev Adds pool's underlying as collateral token with LT = 0
    /// @dev Sets `msg.sender` as credit configurator
    constructor(address _addressProvider, address _pool, string memory _name) {
        addressProvider = _addressProvider;
        pool = _pool; // U:[CM-1]

        underlying = IPoolV3(_pool).underlyingToken(); // U:[CM-1]
        _addToken(underlying); // U:[CM-1]

        priceOracle = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_PRICE_ORACLE, 3_00); // U:[CM-1]
        accountFactory = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_ACCOUNT_FACTORY, NO_VERSION_CONTROL); // U:[CM-1]

        creditConfigurator = msg.sender; // U:[CM-1]

        name = _name;
    }

    // ------------------ //
    // ACCOUNT MANAGEMENT //
    // ------------------ //

    /// @notice Opens a new credit account
    /// @param onBehalfOf Owner of a newly opened credit account
    /// @return creditAccount Address of the newly opened credit account
    function openCreditAccount(address onBehalfOf)
        external
        override
        nonZeroAddress(onBehalfOf)
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (address creditAccount)
    {
        creditAccount = IAccountFactoryBase(accountFactory).takeCreditAccount(0, 0); // U:[CM-6]

        CreditAccountInfo storage newCreditAccountInfo = creditAccountInfo[creditAccount];

        // newCreditAccountInfo.flags = 0;
        // newCreditAccountInfo.lastDebtUpdate = 0;
        // newCreditAccountInfo.borrower = onBehalfOf;
        assembly {
            let slot := add(newCreditAccountInfo.slot, 4)
            let value := shl(80, onBehalfOf)
            sstore(slot, value)
        } // U:[CM-6]

        // newCreditAccountInfo.cumulativeQuotaInterest = 1;
        // newCreditAccountInfo.quotaFees = 0;
        assembly {
            let slot := add(newCreditAccountInfo.slot, 2)
            sstore(slot, 1)
        } // U:[CM-6]

        creditAccountsSet.add(creditAccount); // U:[CM-6]
    }

    /// @notice Closes a credit account
    /// @param creditAccount Account to close
    /// @custom:expects Credit facade ensures that `creditAccount` is opened in this credit manager
    function closeCreditAccount(address creditAccount)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
    {
        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[creditAccount];
        if (currentCreditAccountInfo.debt != 0) {
            revert CloseAccountWithNonZeroDebtException(); // U:[CM-7]
        }

        // currentCreditAccountInfo.borrower = address(0);
        // currentCreditAccountInfo.lastDebtUpdate = 0;
        // currentCreditAccountInfo.flags = 0;
        assembly {
            let slot := add(currentCreditAccountInfo.slot, 4)
            sstore(slot, 0)
        } // U:[CM-7]

        currentCreditAccountInfo.enabledTokensMask = 0; // U:[CM-7]

        IAccountFactoryBase(accountFactory).returnCreditAccount({creditAccount: creditAccount}); // U:[CM-7]
        creditAccountsSet.remove(creditAccount); // U:[CM-7]
    }

    /// @notice Liquidates a credit account
    ///         - Removes account's quotas, and, if there's loss incurred on liquidation,
    ///           also zeros out limits for account's quoted tokens in the quota keeper
    ///         - Repays debt to the pool
    ///         - Ensures that the value of funds remaining on the account is sufficient
    ///         - Transfers underlying surplus (if any) to the liquidator
    ///         - Resets account's debt, quota interest and fees to zero
    /// @param creditAccount Account to liquidate
    /// @param collateralDebtData A struct with account's debt and collateral data
    /// @param to Address to transfer underlying left after liquidation
    /// @return remainingFunds Total value of assets left on the account after liquidation
    /// @return loss Loss incurred on liquidation
    /// @custom:expects Credit facade ensures that `creditAccount` is opened in this credit manager
    /// @custom:expects `collateralDebtData` is a result of `calcDebtAndCollateral` in `DEBT_COLLATERAL` mode
    function liquidateCreditAccount(
        address creditAccount,
        CollateralDebtData calldata collateralDebtData,
        address to,
        bool isExpired
    )
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 remainingFunds, uint256 loss)
    {
        uint256 amountToPool;
        uint256 minRemainingFunds;
        uint256 profit;
        (amountToPool, minRemainingFunds, profit, loss) = collateralDebtData.calcLiquidationPayments({
            liquidationDiscount: isExpired ? liquidationDiscountExpired : liquidationDiscount,
            feeLiquidation: isExpired ? feeLiquidationExpired : feeLiquidation,
            amountWithFeeFn: _amountWithFee,
            amountMinusFeeFn: _amountMinusFee
        }); // U:[CM-8]

        if (collateralDebtData.quotedTokens.length != 0) {
            IPoolQuotaKeeperV3(collateralDebtData._poolQuotaKeeper).removeQuotas({
                creditAccount: creditAccount,
                tokens: collateralDebtData.quotedTokens,
                setLimitsToZero: loss > 0
            }); // U:[CM-8]
        }

        if (amountToPool != 0) {
            ICreditAccountBase(creditAccount).transfer({token: underlying, to: pool, amount: amountToPool}); // U:[CM-8]
        }
        _poolRepayCreditAccount(collateralDebtData.debt, profit, loss); // U:[CM-8]

        uint256 underlyingBalance;
        (remainingFunds, underlyingBalance) =
            _getRemainingFunds({creditAccount: creditAccount, enabledTokensMask: collateralDebtData.enabledTokensMask}); // U:[CM-8]

        if (remainingFunds < minRemainingFunds) {
            revert InsufficientRemainingFundsException(); // U:[CM-8]
        }

        unchecked {
            uint256 amountToLiquidator = Math.min(remainingFunds - minRemainingFunds, underlyingBalance);

            if (amountToLiquidator != 0) {
                ICreditAccountBase(creditAccount).transfer({token: underlying, to: to, amount: amountToLiquidator}); // U:[CM-8]

                remainingFunds -= amountToLiquidator; // U:[CM-8]
            }
        }

        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[creditAccount];
        if (currentCreditAccountInfo.lastDebtUpdate == block.number) {
            revert DebtUpdatedTwiceInOneBlockException(); // U:[CM-9]
        }

        currentCreditAccountInfo.debt = 0; // U:[CM-8]
        currentCreditAccountInfo.lastDebtUpdate = uint64(block.number); // U:[CM-8]
        currentCreditAccountInfo.enabledTokensMask =
            collateralDebtData.enabledTokensMask.disable(collateralDebtData.quotedTokensMask); // U:[CM-8]

        // currentCreditAccountInfo.cumulativeQuotaInterest = 1;
        // currentCreditAccountInfo.quotaFees = 0;
        assembly {
            let slot := add(currentCreditAccountInfo.slot, 2)
            sstore(slot, 1)
        } // U:[CM-8]
    }

    /// @notice Increases or decreases credit account's debt
    /// @param creditAccount Account to increase/decrease debr for
    /// @param amount Amount of underlying to change the total debt by
    /// @param enabledTokensMask  Bitmask of account's enabled collateral tokens
    /// @param action Manage debt type, see `ManageDebtAction`
    /// @return newDebt Debt principal after update
    /// @return tokensToEnable Tokens that should be enabled after the operation
    ///         (underlying mask on increase, zero on decrease)
    /// @return tokensToDisable Tokens that should be disabled after the operation
    ///         (zero on increase, underlying mask on decrease if account has no underlying after repayment)
    /// @custom:expects Credit facade ensures that `creditAccount` is opened in this credit manager
    function manageDebt(address creditAccount, uint256 amount, uint256 enabledTokensMask, ManageDebtAction action)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 newDebt, uint256 tokensToEnable, uint256 tokensToDisable)
    {
        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[creditAccount];
        if (currentCreditAccountInfo.lastDebtUpdate == block.number) {
            revert DebtUpdatedTwiceInOneBlockException(); // U:[CM-12A]
        }
        if (amount == 0) return (currentCreditAccountInfo.debt, 0, 0); // U:[CM-12B]

        uint256[] memory collateralHints;
        CollateralDebtData memory collateralDebtData = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMask,
            collateralHints: collateralHints,
            minHealthFactor: PERCENTAGE_FACTOR,
            task: (action == ManageDebtAction.INCREASE_DEBT)
                ? CollateralCalcTask.GENERIC_PARAMS
                : CollateralCalcTask.DEBT_ONLY,
            useSafePrices: false
        });

        uint256 newCumulativeIndex;
        if (action == ManageDebtAction.INCREASE_DEBT) {
            (newDebt, newCumulativeIndex) = CreditLogic.calcIncrease({
                amount: amount,
                debt: collateralDebtData.debt,
                cumulativeIndexNow: collateralDebtData.cumulativeIndexNow,
                cumulativeIndexLastUpdate: collateralDebtData.cumulativeIndexLastUpdate
            }); // U:[CM-10]

            _poolLendCreditAccount(amount, creditAccount); // U:[CM-10]
            tokensToEnable = UNDERLYING_TOKEN_MASK; // U:[CM-12C]
        } else {
            uint256 maxRepayment = _amountWithFee(collateralDebtData.calcTotalDebt());
            if (amount >= maxRepayment) {
                amount = maxRepayment; // U:[CM-11]
            }

            ICreditAccountBase(creditAccount).transfer({token: underlying, to: pool, amount: amount}); // U:[CM-11]

            uint128 newCumulativeQuotaInterest;
            uint256 profit;
            if (amount == maxRepayment) {
                newDebt = 0;
                newCumulativeIndex = collateralDebtData.cumulativeIndexNow;
                profit = collateralDebtData.accruedFees;
                newCumulativeQuotaInterest = 0;
                currentCreditAccountInfo.quotaFees = 0;
            } else {
                (newDebt, newCumulativeIndex, profit, newCumulativeQuotaInterest, currentCreditAccountInfo.quotaFees) =
                CreditLogic.calcDecrease({
                    amount: _amountMinusFee(amount),
                    debt: collateralDebtData.debt,
                    cumulativeIndexNow: collateralDebtData.cumulativeIndexNow,
                    cumulativeIndexLastUpdate: collateralDebtData.cumulativeIndexLastUpdate,
                    cumulativeQuotaInterest: collateralDebtData.cumulativeQuotaInterest,
                    quotaFees: currentCreditAccountInfo.quotaFees,
                    feeInterest: feeInterest
                }); // U:[CM-11]
            }

            if (collateralDebtData.quotedTokens.length != 0) {
                // zero-debt is a special state that disables collateral checks so having quotas on
                // the account should be forbidden as they entail debt in a form of quota interest
                if (newDebt == 0) revert DebtToZeroWithActiveQuotasException(); // U:[CM-11A]

                // quota interest is accrued in credit manager regardless of whether anything has been repaid,
                // so they are also accrued in the quota keeper to keep the contracts in sync
                IPoolQuotaKeeperV3(collateralDebtData._poolQuotaKeeper).accrueQuotaInterest({
                    creditAccount: creditAccount,
                    tokens: collateralDebtData.quotedTokens
                }); // U:[CM-11A]
            }

            _poolRepayCreditAccount(collateralDebtData.debt - newDebt, profit, 0); // U:[CM-11]

            currentCreditAccountInfo.cumulativeQuotaInterest = newCumulativeQuotaInterest + 1; // U:[CM-11]

            if (IERC20(underlying).safeBalanceOf({account: creditAccount}) <= 1) {
                tokensToDisable = UNDERLYING_TOKEN_MASK; // U:[CM-12C]
            }
        }

        currentCreditAccountInfo.debt = newDebt; // U:[CM-10,11]
        currentCreditAccountInfo.lastDebtUpdate = uint64(block.number); // U:[CM-10,11]
        currentCreditAccountInfo.cumulativeIndexLastUpdate = newCumulativeIndex; // U:[CM-10,11]
    }

    /// @notice Adds `amount` of `payer`'s `token` as collateral to `creditAccount`
    /// @param payer Address to transfer token from
    /// @param creditAccount Account to add collateral to
    /// @param token Token to add as collateral
    /// @param amount Amount to add
    /// @return tokensToEnable Mask of tokens that should be enabled after the operation (always `token` mask)
    /// @dev Requires approval for `token` from `payer` to this contract
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function addCollateral(address payer, address creditAccount, address token, uint256 amount)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 tokensToEnable)
    {
        tokensToEnable = getTokenMaskOrRevert({token: token}); // U:[CM-13]
        IERC20(token).safeTransferFrom({from: payer, to: creditAccount, amount: amount}); // U:[CM-13]
    }

    /// @notice Withdraws `amount` of `token` collateral from `creditAccount` to `to`
    /// @param creditAccount Credit account to withdraw collateral from
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw
    /// @param to Address to transfer token to
    /// @return tokensToDisable Mask of tokens that should be disabled after the operation
    ///         (`token` mask if withdrawing the entire balance, zero otherwise)
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function withdrawCollateral(address creditAccount, address token, uint256 amount, address to)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 tokensToDisable)
    {
        uint256 tokenMask = getTokenMaskOrRevert({token: token}); // U:[CM-26]

        ICreditAccountBase(creditAccount).transfer({token: token, to: to, amount: amount}); // U:[CM-27]

        if (IERC20(token).safeBalanceOf({account: creditAccount}) <= 1) {
            tokensToDisable = tokenMask; // U:[CM-27]
        }
    }

    /// @notice Instructs `creditAccount` to make an external call to target with `callData`
    function externalCall(address creditAccount, address target, bytes calldata callData)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (bytes memory result)
    {
        return _execute(creditAccount, target, callData);
    }

    /// @notice Instructs `creditAccount` to approve `amount` of `token` to `spender`
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function approveToken(address creditAccount, address token, address spender, uint256 amount)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
    {
        _approveSpender({creditAccount: creditAccount, token: token, spender: spender, amount: amount});
    }

    /// @notice Revokes credit account's allowances for specified spender/token pairs
    /// @param creditAccount Account to revoke allowances for
    /// @param revocations Array of spender/token pairs
    /// @dev Exists primarily to allow users to revoke allowances on accounts from old account factory on mainnet
    /// @dev Reverts if any of provided tokens is not recognized as collateral in the credit manager
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
                _approveSpender({creditAccount: creditAccount, token: token, spender: spender, amount: 0}); // U:[CM-15]
            }
        }
    }

    // -------- //
    // ADAPTERS //
    // -------- //

    /// @notice Instructs active credit account to approve `amount` of `token` to adater's target contract
    /// @param token Token to approve
    /// @param amount Amount to approve
    /// @dev Reverts if active credit account is not set
    /// @dev Reverts if `msg.sender` is not a registered adapter
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function approveCreditAccount(address token, uint256 amount)
        external
        override
        nonReentrant // U:[CM-5]
    {
        address targetContract = _getTargetContractOrRevert(); // U:[CM-3]
        address creditAccount = getActiveCreditAccountOrRevert(); // U:[CM-14]
        _approveSpender({creditAccount: creditAccount, token: token, spender: targetContract, amount: amount}); // U:[CM-14]
    }

    /// @notice Instructs active credit account to call adapter's target contract with provided data
    /// @param data Data to call the target contract with
    /// @return result Call result
    /// @dev Reverts if active credit account is not set
    /// @dev Reverts if `msg.sender` is not a registered adapter
    function execute(bytes calldata data)
        external
        override
        nonReentrant // U:[CM-5]
        returns (bytes memory result)
    {
        address targetContract = _getTargetContractOrRevert(); // U:[CM-3]
        address creditAccount = getActiveCreditAccountOrRevert(); // U:[CM-16]
        return _execute(creditAccount, targetContract, data); // U:[CM-16]
    }

    /// @dev Returns adapter's target contract, reverts if `msg.sender` is not a registered adapter
    function _getTargetContractOrRevert() internal view returns (address targetContract) {
        targetContract = adapterToContract[msg.sender]; // U:[CM-15, 16]
        if (targetContract == address(0)) {
            revert CallerNotAdapterException(); // U:[CM-3]
        }
    }

    /// @notice Sets/unsets active credit account adapters can interact with
    /// @param creditAccount Credit account to set as active or `INACTIVE_CREDIT_ACCOUNT_ADDRESS` to unset it
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

    /// @notice Returns active credit account, reverts if it is not set
    function getActiveCreditAccountOrRevert() public view override returns (address creditAccount) {
        creditAccount = _activeCreditAccount;
        if (creditAccount == INACTIVE_CREDIT_ACCOUNT_ADDRESS) {
            revert ActiveCreditAccountNotSetException();
        }
    }

    // ----------------- //
    // COLLATERAL CHECKS //
    // ----------------- //

    /// @notice Performs full check of `creditAccount`'s collateral to ensure it is sufficiently collateralized,
    ///         might disable tokens with zero balances
    /// @param creditAccount Credit account to check
    /// @param enabledTokensMask Bitmask of account's enabled collateral tokens
    /// @param collateralHints Optional array of token masks to check first to reduce the amount of computation
    ///        when known subset of account's collateral tokens covers all the debt
    /// @param minHealthFactor Health factor threshold in bps, the check fails if `twvUSD < minHealthFactor * totalDebtUSD`
    /// @param useSafePrices Whether to use safe prices when evaluating collateral
    /// @return enabledTokensMaskAfter Bitmask of account's enabled collateral tokens after potential cleanup
    /// @dev Even when `collateralHints` are specified, quoted tokens are evaluated before non-quoted ones
    /// @custom:expects Credit facade ensures that `creditAccount` is opened in this credit manager
    function fullCollateralCheck(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256[] calldata collateralHints,
        uint16 minHealthFactor,
        bool useSafePrices
    )
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 enabledTokensMaskAfter)
    {
        CollateralDebtData memory cdd = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            minHealthFactor: minHealthFactor,
            collateralHints: collateralHints,
            enabledTokensMask: enabledTokensMask,
            task: CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY,
            useSafePrices: useSafePrices
        }); // U:[CM-18]

        if (cdd.twvUSD < cdd.totalDebtUSD * minHealthFactor / PERCENTAGE_FACTOR) {
            revert NotEnoughCollateralException(); // U:[CM-18B]
        }

        enabledTokensMaskAfter = cdd.enabledTokensMask;
        _saveEnabledTokensMask(creditAccount, enabledTokensMaskAfter); // U:[CM-18]
    }

    /// @notice Whether `creditAccount`'s health factor is below `minHealthFactor`
    /// @param creditAccount Credit account to check
    /// @param minHealthFactor Health factor threshold in bps
    /// @dev Reverts if account is not opened in this credit manager
    function isLiquidatable(address creditAccount, uint16 minHealthFactor) external view override returns (bool) {
        getBorrowerOrRevert(creditAccount); // U:[CM-17]

        uint256[] memory collateralHints;
        CollateralDebtData memory cdd = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMaskOf(creditAccount),
            collateralHints: collateralHints,
            minHealthFactor: minHealthFactor,
            task: CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY,
            useSafePrices: false
        }); // U:[CM-18]

        return cdd.twvUSD < cdd.totalDebtUSD * minHealthFactor / PERCENTAGE_FACTOR; // U:[CM-18B]
    }

    /// @notice Returns `creditAccount`'s debt and collateral data with level of detail controlled by `task`
    /// @param creditAccount Credit account to return data for
    /// @param task Calculation mode, see `CollateralCalcTask` for details, can't be `FULL_COLLATERAL_CHECK_LAZY`
    /// @return cdd A struct with debt and collateral data
    /// @dev Reverts if account is not opened in this credit manager
    function calcDebtAndCollateral(address creditAccount, CollateralCalcTask task)
        external
        view
        override
        returns (CollateralDebtData memory cdd)
    {
        if (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY) {
            revert IncorrectParameterException(); // U:[CM-19]
        }

        bool useSafePrices;
        if (task == CollateralCalcTask.DEBT_COLLATERAL_SAFE_PRICES) {
            task = CollateralCalcTask.DEBT_COLLATERAL;
            useSafePrices = true;
        }

        getBorrowerOrRevert(creditAccount); // U:[CM-17]

        uint256[] memory collateralHints;
        cdd = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMaskOf(creditAccount),
            collateralHints: collateralHints,
            minHealthFactor: PERCENTAGE_FACTOR,
            task: task,
            useSafePrices: useSafePrices
        }); // U:[CM-20]
    }

    /// @dev `calcDebtAndCollateral` implementation
    /// @param creditAccount Credit account to return data for
    /// @param enabledTokensMask Bitmask of account's enabled collateral tokens
    /// @param collateralHints Optional array of token masks specifying the order of checking collateral tokens
    /// @param minHealthFactor Health factor in bps to stop the calculations after when performing collateral check
    /// @param task Calculation mode, see `CollateralCalcTask` for details
    /// @param useSafePrices Whether to use safe prices when evaluating collateral
    /// @return cdd A struct with debt and collateral data
    function _calcDebtAndCollateral(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256[] memory collateralHints,
        uint16 minHealthFactor,
        CollateralCalcTask task,
        bool useSafePrices
    ) internal view returns (CollateralDebtData memory cdd) {
        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[creditAccount];

        cdd.debt = currentCreditAccountInfo.debt; // U:[CM-20]
        cdd.cumulativeIndexLastUpdate = currentCreditAccountInfo.cumulativeIndexLastUpdate; // U:[CM-20]
        cdd.cumulativeIndexNow = IPoolV3(pool).baseInterestIndex(); // U:[CM-20]

        if (task == CollateralCalcTask.GENERIC_PARAMS) {
            return cdd; // U:[CM-20]
        }

        cdd.enabledTokensMask = enabledTokensMask; // U:[CM-21]
        cdd._poolQuotaKeeper = poolQuotaKeeper(); // U:[CM-21]

        uint256[] memory quotasPacked;
        (cdd.quotedTokens, cdd.cumulativeQuotaInterest, quotasPacked, cdd.quotedTokensMask) = _getQuotedTokensData({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMask,
            collateralHints: collateralHints,
            _poolQuotaKeeper: cdd._poolQuotaKeeper
        }); // U:[CM-21]
        cdd.cumulativeQuotaInterest += currentCreditAccountInfo.cumulativeQuotaInterest - 1; // U:[CM-21]

        cdd.accruedInterest = CreditLogic.calcAccruedInterest({
            amount: cdd.debt,
            cumulativeIndexLastUpdate: cdd.cumulativeIndexLastUpdate,
            cumulativeIndexNow: cdd.cumulativeIndexNow
        });
        cdd.accruedFees = currentCreditAccountInfo.quotaFees + cdd.accruedInterest * feeInterest / PERCENTAGE_FACTOR;

        cdd.accruedInterest += cdd.cumulativeQuotaInterest; // U:[CM-21]
        cdd.accruedFees += cdd.cumulativeQuotaInterest * feeInterest / PERCENTAGE_FACTOR; // U:[CM-21]

        if (task == CollateralCalcTask.DEBT_ONLY) {
            return cdd; // U:[CM-21]
        }

        address _priceOracle = priceOracle;

        {
            uint256 totalDebt = _amountWithFee(cdd.calcTotalDebt());
            if (totalDebt != 0) {
                cdd.totalDebtUSD = _convertToUSD(_priceOracle, totalDebt, underlying); // U:[CM-22]
            } else if (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY) {
                return cdd; // U:[CM-18A]
            }
        }

        uint256 targetUSD = (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY)
            ? cdd.totalDebtUSD * minHealthFactor / PERCENTAGE_FACTOR
            : type(uint256).max;

        uint256 tokensToDisable;
        (cdd.totalValueUSD, cdd.twvUSD, tokensToDisable) = cdd.calcCollateral({
            creditAccount: creditAccount,
            underlying: underlying,
            twvUSDTarget: targetUSD,
            collateralHints: collateralHints,
            quotasPacked: quotasPacked,
            priceOracle: _priceOracle,
            collateralTokenByMaskFn: _collateralTokenByMask,
            convertToUSDFn: useSafePrices ? _safeConvertToUSD : _convertToUSD
        }); // U:[CM-22]
        cdd.enabledTokensMask = enabledTokensMask.disable(tokensToDisable); // U:[CM-22]

        if (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY) {
            return cdd;
        }

        cdd.totalValue = _convertFromUSD(_priceOracle, cdd.totalValueUSD, underlying); // U:[CM-22,23]
    }

    /// @dev Returns quotas data for credit manager and credit account
    /// @param creditAccount Credit account to return quotas data for
    /// @param enabledTokensMask Bitmask of account's enabled collateral tokens
    /// @param collateralHints Optional array of token masks specifying tokens order
    /// @param _poolQuotaKeeper Cached quota keeper address
    /// @return quotedTokens Array of quoted tokens enabled as collateral on the account,
    ///         sorted according to `collateralHints` if specified
    /// @return outstandingQuotaInterest Account's quota interest that has not yet been accounted for
    /// @return quotasPacked Array of quotas packed with tokens' LTs
    /// @return _quotedTokensMask The bitmask of all quoted tokens in the credit manager
    function _getQuotedTokensData(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256[] memory collateralHints,
        address _poolQuotaKeeper
    )
        internal
        view
        returns (
            address[] memory quotedTokens,
            uint128 outstandingQuotaInterest,
            uint256[] memory quotasPacked,
            uint256 _quotedTokensMask
        )
    {
        _quotedTokensMask = quotedTokensMask; // U:[CM-24]

        uint256 tokensToCheckMask = enabledTokensMask & _quotedTokensMask; // U:[CM-24]
        if (tokensToCheckMask == 0) {
            return (quotedTokens, 0, quotasPacked, _quotedTokensMask);
        }

        uint256 tokensIdx;
        uint256 tokensLen = tokensToCheckMask.calcEnabledTokens(); // U:[CM-24]
        quotedTokens = new address[](tokensLen); // U:[CM-24]
        quotasPacked = new uint256[](tokensLen); // U:[CM-24]

        uint256 hintsIdx;
        uint256 hintsLen = collateralHints.length;

        // puts credit account on top of the stack to avoid the "stack too deep" error
        address _creditAccount = creditAccount;

        unchecked {
            while (tokensToCheckMask != 0) {
                uint256 tokenMask;
                if (hintsIdx < hintsLen) {
                    tokenMask = collateralHints[hintsIdx++];
                    if (tokensToCheckMask & tokenMask == 0) continue;
                } else {
                    // mask with only the LSB of `tokensToCheckMask` enabled
                    tokenMask = tokensToCheckMask & uint256(-int256(tokensToCheckMask));
                }

                (address token, uint16 lt) = _collateralTokenByMask({tokenMask: tokenMask, calcLT: true}); // U:[CM-24]

                (uint256 quota, uint128 outstandingInterestDelta) =
                    IPoolQuotaKeeperV3(_poolQuotaKeeper).getQuotaAndOutstandingInterest(_creditAccount, token); // U:[CM-24]

                quotedTokens[tokensIdx] = token; // U:[CM-24]
                quotasPacked[tokensIdx] = CollateralLogic.packQuota(uint96(quota), lt);

                // quota interest is of roughly the same scale as quota, which is stored as `uint96`,
                // thus this addition is very unlikely to overflow and can be unchecked
                outstandingQuotaInterest += outstandingInterestDelta; // U:[CM-24]

                ++tokensIdx;
                tokensToCheckMask = tokensToCheckMask.disable(tokenMask);
            }
        }
    }

    /// @dev Returns total value of funds remaining on the credit account after liquidation, which consists of underlying
    ///      token balance and total value of other enabled tokens remaining after transferring specified tokens
    /// @param creditAccount Account to compute value for
    /// @param enabledTokensMask Bit mask of tokens enabled on the account
    /// @return remainingFunds Remaining funds denominated in underlying
    /// @return underlyingBalance Balance of underlying token
    function _getRemainingFunds(address creditAccount, uint256 enabledTokensMask)
        internal
        view
        returns (uint256 remainingFunds, uint256 underlyingBalance)
    {
        underlyingBalance = IERC20(underlying).safeBalanceOf({account: creditAccount});
        remainingFunds = underlyingBalance;

        uint256 remainingTokensMask = enabledTokensMask.disable(UNDERLYING_TOKEN_MASK);
        if (remainingTokensMask == 0) return (remainingFunds, underlyingBalance);

        address _priceOracle = priceOracle;
        uint256 totalValueUSD;
        while (remainingTokensMask != 0) {
            uint256 tokenMask = remainingTokensMask & uint256(-int256(remainingTokensMask));
            remainingTokensMask ^= tokenMask;

            address token = getTokenByMask(tokenMask);
            uint256 balance = IERC20(token).safeBalanceOf({account: creditAccount});
            if (balance > 1) {
                totalValueUSD += _convertToUSD(_priceOracle, balance, token);
            }
        }

        if (totalValueUSD != 0) {
            remainingFunds += _convertFromUSD(_priceOracle, totalValueUSD, underlying);
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
        if (currentCreditAccountInfo.debt == 0) {
            revert UpdateQuotaOnZeroDebtAccountException();
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
    /// @dev Ensures that the number of enabled tokens excluding underlying does not exceed `maxEnabledTokens`
    function _saveEnabledTokensMask(address creditAccount, uint256 enabledTokensMask) internal {
        if (enabledTokensMask.disable(UNDERLYING_TOKEN_MASK).calcEnabledTokens() > maxEnabledTokens) {
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
        uint256 resultLen = offset + limit > len ? (offset > len ? 0 : len - offset) : limit;

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
        quotedTokensMask = _quotedTokensMask.disable(UNDERLYING_TOKEN_MASK); // U:[CM-43]
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

    /// @dev Approves `amount` of `token` from `creditAccount` to `spender`
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function _approveSpender(address creditAccount, address token, address spender, uint256 amount) internal {
        getTokenMaskOrRevert({token: token}); // U:[CM-15]
        ICreditAccountBase(creditAccount).safeApprove({token: token, spender: spender, amount: amount}); // U:[CM-15]
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

    /// @dev Internal wrapper for `creditAccount.execute` call to reduce contract size
    function _execute(address creditAccount, address target, bytes calldata callData) internal returns (bytes memory) {
        return ICreditAccountBase(creditAccount).execute(target, callData);
    }

    /// @dev Internal wrapper for `pool.repayCreditAccount` call to reduce contract size
    function _poolRepayCreditAccount(uint256 debt, uint256 profit, uint256 loss) internal {
        IPoolV3(pool).repayCreditAccount(debt, profit, loss);
    }

    /// @dev Internal wrapper for `pool.lendCreditAccount` call to reduce contract size
    function _poolLendCreditAccount(uint256 amount, address creditAccount) internal {
        IPoolV3(pool).lendCreditAccount(amount, creditAccount); // F:[CM-20]
    }

    /// @dev Internal wrapper for `priceOracle.convertToUSD` call to reduce contract size
    function _convertToUSD(address _priceOracle, uint256 amountInToken, address token)
        internal
        view
        returns (uint256 amountInUSD)
    {
        amountInUSD = IPriceOracleV3(_priceOracle).convertToUSD(amountInToken, token);
    }

    /// @dev Internal wrapper for `priceOracle.convertFromUSD` call to reduce contract size
    function _convertFromUSD(address _priceOracle, uint256 amountInUSD, address token)
        internal
        view
        returns (uint256 amountInToken)
    {
        amountInToken = IPriceOracleV3(_priceOracle).convertFromUSD(amountInUSD, token);
    }

    /// @dev Internal wrapper for `priceOracle.safeConvertToUSD` call to reduce contract size
    /// @dev `underlying` is always converted with default conversion function
    function _safeConvertToUSD(address _priceOracle, uint256 amountInToken, address token)
        internal
        view
        returns (uint256 amountInUSD)
    {
        amountInUSD = (token == underlying)
            ? _convertToUSD(_priceOracle, amountInToken, token)
            : IPriceOracleV3(_priceOracle).safeConvertToUSD(amountInToken, token);
    }

    /// @dev Reverts if `msg.sender` is not the credit facade
    function _checkCreditFacade() private view {
        if (msg.sender != creditFacade) revert CallerNotCreditFacadeException();
    }

    /// @dev Reverts if `msg.sender` is not the credit configurator
    function _checkCreditConfigurator() private view {
        if (msg.sender != creditConfigurator) revert CallerNotConfiguratorException();
    }
}
