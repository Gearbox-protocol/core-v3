// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

// THIRD-PARTY
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// LIBS & TRAITS
import {BitMask} from "../libraries/BitMask.sol";
import {CreditLogic} from "../libraries/CreditLogic.sol";
import {CollateralLogic} from "../libraries/CollateralLogic.sol";
import {CreditAccountHelper} from "../libraries/CreditAccountHelper.sol";

import {ReentrancyGuardTrait} from "../traits/ReentrancyGuardTrait.sol";
import {SanityCheckTrait} from "../traits/SanityCheckTrait.sol";

// INTERFACES
import {IAccountFactory} from "../interfaces/base/IAccountFactory.sol";
import {ICreditAccountV3} from "../interfaces/ICreditAccountV3.sol";
import {IMatchingEngineV3} from "../interfaces/IMatchingEngineV3.sol";
import {IInterestRateModel} from "../interfaces/base/IInterestRateModel.sol";
import {
    ICreditManagerV3,
    CollateralTokenData,
    ManageDebtAction,
    CreditAccountInfo,
    CollateralDebtData,
    CollateralCalcTask
} from "../interfaces/ICreditManagerV3.sol";
import {IPriceOracleV3} from "../interfaces/IPriceOracleV3.sol";

// LIBRARIES
import {
    INACTIVE_CREDIT_ACCOUNT_ADDRESS,
    MAX_SANE_ENABLED_TOKENS,
    PERCENTAGE_FACTOR,
    UNDERLYING_TOKEN_MASK,
    FORCE_CLOSURE_GRACE_PERIOD
} from "../libraries/Constants.sol";

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
    using SafeERC20 for IERC20;

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Account factory contract address
    address public immutable override accountFactory;

    /// @notice Underlying token address
    address public immutable override underlying;

    address public immutable override matchingEngine;

    /// @notice Address of the connected credit facade
    address public override creditFacade;

    /// @notice Address of the connected credit configurator
    address public override creditConfigurator;

    /// @notice Maximum number of tokens that a credit account can have enabled as collateral
    uint8 public immutable override maxEnabledTokens;

    /// @notice Number of known collateral tokens
    uint8 public override collateralTokensCount;

    /// @dev Liquidation threshold for the underlying token in bps
    uint16 public immutable override ltUnderlying;

    /// @dev Percentage of accrued interest in bps taken by the protocol as profit
    uint16 internal immutable feeInterest;

    /// @dev Percentage of liquidated account value in bps taken by the protocol as profit
    uint16 internal feeLiquidation;

    /// @dev Percentage of liquidated account value in bps that is used to repay debt
    uint16 internal liquidationDiscount;

    /// @dev Percentage of liquidated expired account value in bps taken by the protocol as profit
    uint16 internal feeLiquidationExpired;

    /// @dev Percentage of liquidated expired account value in bps that is used to repay debt
    uint16 internal liquidationDiscountExpired;

    /// @dev Eearly exit penalty in bps
    uint16 internal maxEarlyClosurePenalty;

    /// @dev Active credit account which is an account adapters can interfact with
    address internal _activeCreditAccount = INACTIVE_CREDIT_ACCOUNT_ADDRESS;

    /// @notice Mapping adapter => target contract
    mapping(address => address) public override adapterToContract;

    /// @notice Mapping target contract => adapter
    mapping(address => address) public override contractToAdapter;

    /// @notice Mapping credit account => account info (owner, debt amount, etc.)
    mapping(address => CreditAccountInfo) public creditAccountInfo;

    /// @dev Set of all credit accounts opened in this credit manager
    EnumerableSet.AddressSet internal creditAccountsSet;

    /// @dev Set of all allowed collateral tokens in this credit manager
    EnumerableSet.AddressSet internal allowedCollateralSet;

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

    constructor(
        address _matchingEngine,
        address _underlying,
        address _accountFactory,
        uint8 _maxEnabledTokens,
        uint16 _feeInterest,
        uint16 _feeLiquidation,
        uint16 _liquidationPremium,
        uint16 _maxEarlyClosurePenalty,
        string memory _name
    ) {
        if (bytes(_name).length == 0 || _maxEnabledTokens == 0 || _maxEnabledTokens > MAX_SANE_ENABLED_TOKENS) {
            revert IncorrectParameterException();
        }
        if (
            _feeLiquidation > _liquidationPremium
                || _liquidationPremium + _feeLiquidation + _maxEarlyClosurePenalty >= PERCENTAGE_FACTOR
        ) revert IncorrectParameterException();

        matchingEngine = _matchingEngine;
        underlying = _underlying;
        accountFactory = _accountFactory;
        maxEnabledTokens = _maxEnabledTokens;
        ltUnderlying = PERCENTAGE_FACTOR - _liquidationPremium - _feeLiquidation - _maxEarlyClosurePenalty;
        feeInterest = _feeInterest;
        feeLiquidation = _feeLiquidation;
        liquidationDiscount = PERCENTAGE_FACTOR - _liquidationPremium;
        name = _name;

        _addToken(underlying);

        creditConfigurator = msg.sender;
    }

    /// @notice Contract type
    function contractType() external view virtual override returns (bytes32) {
        return "CREDIT_MANAGER";
    }

    // ------------------ //
    // ACCOUNT MANAGEMENT //
    // ------------------ //

    /// @notice Opens a new credit account
    /// @param onBehalfOf Owner of a newly opened credit account
    /// @return creditAccount Address of the newly opened credit account
    function openCreditAccount(
        address onBehalfOf,
        address interestRateModel,
        address priceOracle,
        uint40 maturityTimestamp,
        CollateralTokenData[] calldata collateralTokens
    ) external override nonZeroAddress(onBehalfOf) nonReentrant creditFacadeOnly returns (address creditAccount) {
        creditAccount = IAccountFactory(accountFactory).takeCreditAccount(0, 0);

        CreditAccountInfo storage newCreditAccountInfo = creditAccountInfo[creditAccount];

        newCreditAccountInfo.flags = 0;
        newCreditAccountInfo.lastDebtUpdate = 0;
        newCreditAccountInfo.borrower = onBehalfOf;
        newCreditAccountInfo.interestRateModel = interestRateModel;
        newCreditAccountInfo.priceOracle = priceOracle;
        newCreditAccountInfo.openingTimestamp = uint40(block.timestamp);
        newCreditAccountInfo.maturityTimestamp = maturityTimestamp;
        newCreditAccountInfo.forcedClosureTimestamp = type(uint40).max;

        for (uint256 i = 0; i < collateralTokens.length; ++i) {
            newCreditAccountInfo.collateralTokens.push(collateralTokens[i]);
        }

        creditAccountsSet.add(creditAccount);
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

        currentCreditAccountInfo.borrower = address(0);
        currentCreditAccountInfo.lastDebtUpdate = 0;
        currentCreditAccountInfo.flags = 0;
        currentCreditAccountInfo.interestRateModel = address(0);
        delete currentCreditAccountInfo.collateralTokens;
        currentCreditAccountInfo.openingTimestamp = 0;
        currentCreditAccountInfo.maturityTimestamp = 0;
        currentCreditAccountInfo.forcedClosureTimestamp = 0;

        currentCreditAccountInfo.cumulativeIndexLastUpdate = 0;

        IAccountFactory(accountFactory).returnCreditAccount({creditAccount: creditAccount});
        creditAccountsSet.remove(creditAccount);
    }

    /// @notice Liquidates a credit account
    ///         - Repays debt to the lender
    ///         - Ensures that the value of funds remaining on the account is sufficient
    ///         - Transfers underlying surplus (if any) to the liquidator
    ///         - Resets account's debt to zero
    /// @param creditAccount Account to liquidate
    /// @param collateralDebtData A struct with account's debt and collateral data
    /// @param to Address to transfer underlying left after liquidation
    /// @return remainingFunds Total value of assets left on the account after liquidation
    /// @return loss Loss incurred on liquidation
    /// @custom:expects Credit facade ensures that `creditAccount` is opened in this credit manager
    /// @custom:expects `collateralDebtData` is a result of `calcDebtAndCollateral` in `DEBT_COLLATERAL` mode
    function liquidateCreditAccount(address creditAccount, CollateralDebtData calldata collateralDebtData, address to)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 remainingFunds, uint256 loss)
    {
        uint256 amountToLender;
        uint256 minRemainingFunds;
        uint256 profit;
        (amountToLender, minRemainingFunds, profit, loss) = collateralDebtData.calcLiquidationPayments({
            liquidationDiscount: liquidationDiscount,
            feeLiquidation: feeLiquidation,
            amountWithFeeFn: _amountWithFee,
            amountMinusFeeFn: _amountMinusFee
        });

        if (amountToLender != 0) {
            _safeTransfer({creditAccount: creditAccount, token: underlying, to: matchingEngine, amount: amountToLender});
        }
        _repayCreditAccount(creditAccount, amountToLender, profit, loss);

        uint256 underlyingBalance;
        (remainingFunds, underlyingBalance) = _getRemainingFunds(creditAccount);

        if (remainingFunds < minRemainingFunds) {
            revert InsufficientRemainingFundsException();
        }

        unchecked {
            uint256 amountToLiquidator = Math.min(remainingFunds - minRemainingFunds, underlyingBalance);

            if (amountToLiquidator != 0) {
                _safeTransfer({creditAccount: creditAccount, token: underlying, to: to, amount: amountToLiquidator});

                remainingFunds -= amountToLiquidator;
            }
        }

        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[creditAccount];
        if (currentCreditAccountInfo.lastDebtUpdate == block.number) {
            revert DebtUpdatedTwiceInOneBlockException(); // U:[CM-9]
        }

        currentCreditAccountInfo.debt = 0;
        currentCreditAccountInfo.lastDebtUpdate = uint64(block.number);
    }

    function forceClosure(address creditAccount) external override nonReentrant creditFacadeOnly {
        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[creditAccount];

        if (block.timestamp < currentCreditAccountInfo.maturityTimestamp) {
            CollateralDebtData memory collateralDebtData = _calcDebtAndCollateral({
                creditAccount: creditAccount,
                minHealthFactor: PERCENTAGE_FACTOR,
                task: CollateralCalcTask.DEBT_ONLY,
                useSafePrices: false
            });

            uint256 earlyClosureAmount =
                collateralDebtData.calcTotalDebt() * collateralDebtData.earlyClosurePenalty / PERCENTAGE_FACTOR;

            (uint256 newDebt, uint256 newCumulativeIndex,) = CreditLogic.calcDecrease({
                amount: earlyClosureAmount,
                debt: collateralDebtData.debt,
                cumulativeIndexNow: collateralDebtData.cumulativeIndexNow,
                cumulativeIndexLastUpdate: collateralDebtData.cumulativeIndexLastUpdate,
                feeInterest: feeInterest
            });

            currentCreditAccountInfo.debt = newDebt;
            currentCreditAccountInfo.lastDebtUpdate = uint64(block.number);
            currentCreditAccountInfo.cumulativeIndexLastUpdate = newCumulativeIndex;
        }

        currentCreditAccountInfo.maturityTimestamp = uint40(block.timestamp);
        currentCreditAccountInfo.forcedClosureTimestamp = uint40(block.timestamp + FORCE_CLOSURE_GRACE_PERIOD);
    }

    /// @notice Increases or decreases credit account's debt
    /// @param creditAccount Account to increase/decrease debt for
    /// @param amount Amount of underlying to change the total debt by
    /// @param action Manage debt type, see `ManageDebtAction`
    /// @return newDebt Debt principal after update
    /// @return tokensToEnable Always 0, exists for backward compatibility
    /// @return tokensToDisable Always 0, exists for backward compatibility
    /// @custom:expects Credit facade ensures that `creditAccount` is opened in this credit manager
    function manageDebt(address creditAccount, uint256 amount, ManageDebtAction action)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256 newDebt, uint256, uint256)
    {
        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[creditAccount];
        if (currentCreditAccountInfo.lastDebtUpdate == block.number) {
            revert DebtUpdatedTwiceInOneBlockException();
        }
        if (amount == 0) return (currentCreditAccountInfo.debt, 0, 0);

        CollateralDebtData memory collateralDebtData = _calcDebtAndCollateral({
            creditAccount: creditAccount,
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

            _lendCreditAccount(amount, creditAccount); // U:[CM-10]
        } else {
            uint256 maxRepayment = _amountWithFee(collateralDebtData.calcTotalDebt());
            if (amount >= maxRepayment) {
                amount = maxRepayment; // U:[CM-11]
            }

            uint256 profit;
            if (amount == maxRepayment) {
                newDebt = 0;
                newCumulativeIndex = collateralDebtData.cumulativeIndexNow;
                profit = collateralDebtData.accruedFees;
            } else {
                (newDebt, newCumulativeIndex, profit) = CreditLogic.calcDecrease({
                    amount: _amountMinusFee(amount),
                    debt: collateralDebtData.debt,
                    cumulativeIndexNow: collateralDebtData.cumulativeIndexNow,
                    cumulativeIndexLastUpdate: collateralDebtData.cumulativeIndexLastUpdate,
                    feeInterest: feeInterest
                });
            }

            uint256 earlyClosureAmount = collateralDebtData.earlyClosurePenalty * amount / PERCENTAGE_FACTOR;
            uint256 earlyClosureProfit = earlyClosureAmount * profit / amount;

            amount += earlyClosureAmount;
            profit += earlyClosureProfit;

            _safeTransfer({creditAccount: creditAccount, token: underlying, to: matchingEngine, amount: amount});

            _repayCreditAccount(creditAccount, amount - profit, profit, 0);
        }

        currentCreditAccountInfo.debt = newDebt;
        currentCreditAccountInfo.lastDebtUpdate = uint64(block.number);
        currentCreditAccountInfo.cumulativeIndexLastUpdate = newCumulativeIndex;
        return (newDebt, 0, 0);
    }

    /// @notice Adds `amount` of `payer`'s `token` as collateral to `creditAccount`
    /// @param payer Address to transfer token from
    /// @param creditAccount Account to add collateral to
    /// @param token Token to add as collateral
    /// @param amount Amount to add
    /// @return tokensToEnable Always 0, exists for backward compatibility
    /// @dev Requires approval for `token` from `payer` to this contract
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function addCollateral(address payer, address creditAccount, address token, uint256 amount)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256)
    {
        revertIfNotAllowedCollateral(token);
        IERC20(token).safeTransferFrom({from: payer, to: creditAccount, amount: amount}); // U:[CM-13]
        return 0;
    }

    /// @notice Withdraws `amount` of `token` collateral from `creditAccount` to `to`
    /// @param creditAccount Credit account to withdraw collateral from
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw
    /// @param to Address to transfer token to
    /// @return tokensToDisable Always 0, exists for backward compatibility
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function withdrawCollateral(address creditAccount, address token, uint256 amount, address to)
        external
        override
        nonReentrant // U:[CM-5]
        creditFacadeOnly // U:[CM-2]
        returns (uint256)
    {
        revertIfNotAllowedCollateral(token);
        _safeTransfer({creditAccount: creditAccount, token: token, to: to, amount: amount}); // U:[CM-27]
        return 0;
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
    /// @param minHealthFactor Health factor threshold in bps, the check fails if `twvUSD < minHealthFactor * totalDebtUSD`
    /// @param useSafePrices Whether to use safe prices when evaluating collateral
    /// @custom:expects Credit facade ensures that `creditAccount` is opened in this credit manager
    function fullCollateralCheck(address creditAccount, uint16 minHealthFactor, bool useSafePrices)
        external
        override
        nonReentrant
        creditFacadeOnly
    {
        CollateralDebtData memory cdd = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            minHealthFactor: minHealthFactor,
            task: CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY,
            useSafePrices: useSafePrices
        }); // U:[CM-18]

        if (cdd.twvUSD < cdd.totalDebtUSD * minHealthFactor / PERCENTAGE_FACTOR) {
            revert NotEnoughCollateralException(); // U:[CM-18B]
        }
    }

    /// @notice Whether `creditAccount`'s health factor is below `minHealthFactor`
    /// @param creditAccount Credit account to check
    /// @param minHealthFactor Health factor threshold in bps
    /// @dev Reverts if account is not opened in this credit manager
    function isLiquidatable(address creditAccount, uint16 minHealthFactor) external view override returns (bool) {
        getBorrowerOrRevert(creditAccount); // U:[CM-17]

        CollateralDebtData memory cdd = _calcDebtAndCollateral({
            creditAccount: creditAccount,
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
            revert IncorrectParameterException();
        }

        bool useSafePrices;
        if (task == CollateralCalcTask.DEBT_COLLATERAL_SAFE_PRICES) {
            task = CollateralCalcTask.DEBT_COLLATERAL;
            useSafePrices = true;
        }

        getBorrowerOrRevert(creditAccount);

        cdd = _calcDebtAndCollateral({
            creditAccount: creditAccount, minHealthFactor: PERCENTAGE_FACTOR, task: task, useSafePrices: useSafePrices
        });
    }

    /// @dev `calcDebtAndCollateral` implementation
    /// @param creditAccount Credit account to return data for
    /// @param minHealthFactor Health factor in bps to stop the calculations after when performing collateral check
    /// @param task Calculation mode, see `CollateralCalcTask` for details
    /// @param useSafePrices Whether to use safe prices when evaluating collateral
    /// @return cdd A struct with debt and collateral data
    function _calcDebtAndCollateral(
        address creditAccount,
        uint16 minHealthFactor,
        CollateralCalcTask task,
        bool useSafePrices
    ) internal view returns (CollateralDebtData memory cdd) {
        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[creditAccount];

        cdd.debt = currentCreditAccountInfo.debt;
        // interest index is meaningless when account has no debt
        cdd.cumulativeIndexLastUpdate = cdd.debt == 0 ? 0 : currentCreditAccountInfo.cumulativeIndexLastUpdate;
        cdd.cumulativeIndexNow = IInterestRateModel(currentCreditAccountInfo.interestRateModel).getCurrentIndex();

        cdd.earlyClosurePenalty = earlyClosurePenaltyOf(creditAccount);

        if (task == CollateralCalcTask.GENERIC_PARAMS) {
            return cdd;
        }

        cdd.accruedInterest = CreditLogic.calcAccruedInterest({
            amount: cdd.debt,
            cumulativeIndexLastUpdate: cdd.cumulativeIndexLastUpdate,
            cumulativeIndexNow: cdd.cumulativeIndexNow
        });
        cdd.accruedFees = cdd.accruedInterest * feeInterest / PERCENTAGE_FACTOR;

        if (task == CollateralCalcTask.DEBT_ONLY) {
            return cdd;
        }

        address _priceOracle = currentCreditAccountInfo.priceOracle;

        {
            uint256 totalDebt = _amountWithFee(cdd.calcTotalDebt());
            if (totalDebt != 0) {
                cdd.totalDebtUSD = _convertToUSD(_priceOracle, totalDebt, underlying);
            } else if (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY) {
                return cdd;
            }
        }

        uint256 targetUSD = (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY)
            ? cdd.totalDebtUSD * minHealthFactor / PERCENTAGE_FACTOR
            : type(uint256).max;

        (cdd.totalValueUSD, cdd.twvUSD) = CollateralLogic.calcCollateral({
            creditAccount: creditAccount,
            underlying: underlying,
            ltUnderlying: ltUnderlying,
            twvUSDTarget: targetUSD,
            collateralTokens: currentCreditAccountInfo.collateralTokens,
            priceOracle: _priceOracle,
            convertToUSDFn: useSafePrices ? _safeConvertToUSD : _convertToUSD
        });

        if (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY) {
            return cdd;
        }

        cdd.totalValue = _convertFromUSD(_priceOracle, cdd.totalValueUSD, underlying);
    }

    /// @dev Returns total value of funds remaining on the credit account after liquidation, which consists of underlying
    ///      token balance and total value of other enabled tokens remaining after transferring specified tokens
    /// @param creditAccount Account to compute value for
    /// @return remainingFunds Remaining funds denominated in underlying
    /// @return underlyingBalance Balance of underlying token
    function _getRemainingFunds(address creditAccount)
        internal
        view
        returns (uint256 remainingFunds, uint256 underlyingBalance)
    {
        underlyingBalance = IERC20(underlying).safeBalanceOf({account: creditAccount});
        remainingFunds = underlyingBalance;

        CollateralTokenData[] memory collateralTokens = creditAccountInfo[creditAccount].collateralTokens;
        address priceOracle = creditAccountInfo[creditAccount].priceOracle;

        uint256 totalValueUSD;
        for (uint256 i = 0; i < collateralTokens.length; ++i) {
            address token = collateralTokens[i].token;
            uint256 balance = IERC20(token).safeBalanceOf({account: creditAccount});
            if (balance > 1) {
                totalValueUSD += _convertToUSD(priceOracle, balance, token);
            }
        }

        if (totalValueUSD != 0) {
            remainingFunds += _convertFromUSD(creditAccountInfo[creditAccount].priceOracle, totalValueUSD, underlying);
        }
    }

    /// ----------------- ///
    /// COLLATERAL PARAMS ///
    /// ----------------- ///

    /// @notice Returns 2 if the token is allowed collateral, reverts if not
    /// @dev Kept for backward compatibility
    /// @param token Token address
    function getTokenMaskOrRevert(address token) public view override returns (uint256) {
        if (isAllowedCollateral(token)) {
            return 2;
        }
        revert TokenNotAllowedException();
    }

    function revertIfNotAllowedCollateral(address token) public view {
        if (!isAllowedCollateral(token)) {
            revert TokenNotAllowedException();
        }
    }

    function isAllowedCollateral(address token) public view override returns (bool) {
        return allowedCollateralSet.contains(token);
    }

    // --------------------- //
    // CREDIT MANAGER PARAMS //
    // --------------------- //

    /// @notice Returns credit manager's fee parameters (all fields in bps)
    /// @return _feeInterest Percentage of accrued interest taken by the protocol as profit
    /// @return _feeLiquidation Percentage of liquidated account value taken by the protocol as profit
    /// @return _liquidationDiscount Percentage of liquidated account value that is used to repay debt
    /// @return _maxEarlyClosurePenalty Maximal early closure penalty in bps
    function fees()
        external
        view
        override
        returns (
            uint16 _feeInterest,
            uint16 _feeLiquidation,
            uint16 _liquidationDiscount,
            uint16 _maxEarlyClosurePenalty
        )
    {
        _feeInterest = feeInterest; // U:[CM-41]
        _feeLiquidation = feeLiquidation; // U:[CM-41]
        _liquidationDiscount = liquidationDiscount; // U:[CM-41]
        _maxEarlyClosurePenalty = maxEarlyClosurePenalty; // U:[CM-41]
    }

    // ------------ //
    // ACCOUNT INFO //
    // ------------ //

    /// @notice Returns `creditAccount`'s owner or reverts if account is not opened in this credit manager
    function getBorrowerOrRevert(address creditAccount) public view override returns (address borrower) {
        borrower = creditAccountInfo[creditAccount].borrower;
        if (borrower == address(0)) revert CreditAccountDoesNotExistException();
    }

    /// @notice Returns `creditAccount`'s flags as a bit mask
    /// @dev Does not revert if `creditAccount` is not opened in this credit manager
    function flagsOf(address creditAccount) public view override returns (uint16) {
        return creditAccountInfo[creditAccount].flags;
    }

    /// @notice Sets `creditAccount`'s flag to a given value
    /// @param creditAccount Account to set a flag for
    /// @param flag Flag to set
    /// @param value The new flag value
    /// @custom:expects Credit facade ensures that `creditAccount` is opened in this credit manager
    function setFlagFor(address creditAccount, uint16 flag, bool value)
        external
        override
        nonReentrant
        creditFacadeOnly
    {
        if (value) {
            _enableFlag(creditAccount, flag);
        } else {
            _disableFlag(creditAccount, flag);
        }
    }

    /// @dev Enables `creditAccount`'s flag
    function _enableFlag(address creditAccount, uint16 flag) internal {
        creditAccountInfo[creditAccount].flags |= flag;
    }

    /// @dev Disables `creditAccount`'s flag
    function _disableFlag(address creditAccount, uint16 flag) internal {
        creditAccountInfo[creditAccount].flags &= ~flag;
    }

    function isAccountForceClosable(address creditAccount) public view override returns (bool) {
        return block.timestamp >= creditAccountInfo[creditAccount].forcedClosureTimestamp;
    }

    function isAccountMature(address creditAccount) public view override returns (bool) {
        return block.timestamp >= creditAccountInfo[creditAccount].maturityTimestamp;
    }

    function maturityTimestamps(address creditAccount)
        public
        view
        override
        returns (uint40 maturityTimestamp, uint40 forcedClosureTimestamp)
    {
        return (
            creditAccountInfo[creditAccount].maturityTimestamp, creditAccountInfo[creditAccount].forcedClosureTimestamp
        );
    }

    function borrowerOf(address creditAccount) public view override returns (address borrower) {
        return creditAccountInfo[creditAccount].borrower;
    }

    function collateralTokensOf(address creditAccount) public view override returns (CollateralTokenData[] memory) {
        return creditAccountInfo[creditAccount].collateralTokens;
    }

    function priceOracleOf(address creditAccount) public view override returns (address priceOracle) {
        return creditAccountInfo[creditAccount].priceOracle;
    }

    /// @notice Returns collateral token's liquidation threshold
    /// @param token Token address
    /// @return lt Token's liquidation threshold in bps
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function liquidationThresholds(address creditAccount, address token) public view override returns (uint16 lt) {
        revertIfNotAllowedCollateral(token);

        CollateralTokenData[] memory collateralTokens = creditAccountInfo[creditAccount].collateralTokens;
        for (uint256 i = 0; i < collateralTokens.length; ++i) {
            if (collateralTokens[i].token == token) {
                return collateralTokens[i].lt;
            }
        }
    }

    function earlyClosurePenaltyOf(address creditAccount) public view override returns (uint16 earlyClosurePenalty) {
        uint40 openingTimestamp = creditAccountInfo[creditAccount].openingTimestamp;
        uint40 maturityTimestamp = creditAccountInfo[creditAccount].maturityTimestamp;

        if (block.timestamp >= openingTimestamp && block.timestamp < maturityTimestamp) {
            return uint16(
                maxEarlyClosurePenalty * (maturityTimestamp - uint40(block.timestamp))
                    / (maturityTimestamp - openingTimestamp)
            );
        }
        return 0;
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
    function addToken(address token) external override creditConfiguratorOnly {
        _addToken(token);
    }

    /// @dev `addToken` implementation:
    ///      - Ensures that token is not already added
    /// @param token Address of the token to add
    function _addToken(address token) internal {
        if (allowedCollateralSet.contains(token)) {
            revert TokenAlreadyAddedException();
        }
        allowedCollateralSet.add(token);
    }

    /// @notice Sets credit manager's fee parameters (all fields in bps)
    /// @param _feeLiquidation Percentage of liquidated account value taken by the protocol as profit
    /// @param _liquidationDiscount Percentage of liquidated account value that is used to repay debt
    /// @dev First parameter exists for backward compatibility and is ignored
    function setFees(uint16, uint16 _feeLiquidation, uint16 _liquidationDiscount, uint16 _maxEarlyClosurePenalty)
        external
        override
        creditConfiguratorOnly
    {
        feeLiquidation = _feeLiquidation;
        liquidationDiscount = _liquidationDiscount;
        maxEarlyClosurePenalty = _maxEarlyClosurePenalty;
    }

    /// @notice Sets the link between the adapter and the target contract
    /// @param adapter Address of the adapter contract to use to access the third-party contract,
    ///        passing `address(0)` will forbid accessing `targetContract`
    /// @param targetContract Address of the third-pary contract for which the adapter is set,
    ///        passing `address(0)` will forbid using `adapter`
    /// @dev Reverts if `targetContract` or `adapter` is this contract's address
    function setContractAllowance(address adapter, address targetContract) external override creditConfiguratorOnly {
        if (targetContract == address(this) || adapter == address(this)) {
            revert TargetContractNotAllowedException();
        }

        if (adapter != address(0)) {
            adapterToContract[adapter] = targetContract;
        }
        if (targetContract != address(0)) {
            contractToAdapter[targetContract] = adapter;
        }
    }

    /// @notice Sets a new credit facade
    /// @param _creditFacade Address of the new credit facade
    function setCreditFacade(address _creditFacade) external override creditConfiguratorOnly {
        creditFacade = _creditFacade;
    }

    /// @notice Sets a new credit configurator
    /// @param _creditConfigurator Address of the new credit configurator
    function setCreditConfigurator(address _creditConfigurator) external override creditConfiguratorOnly {
        _setCreditConfigurator(_creditConfigurator);
    }

    /// @dev Same as above, added for compatibility with `BytecodeRepository` which only works with `Ownable` contracts
    function transferOwnership(address newOwner) external creditConfiguratorOnly {
        _setCreditConfigurator(newOwner);
    }

    /// @dev `setCreditConfigurator` implementation
    function _setCreditConfigurator(address _creditConfigurator) internal {
        creditConfigurator = _creditConfigurator;
        emit SetCreditConfigurator(_creditConfigurator);
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Approves `amount` of `token` from `creditAccount` to `spender`
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function _approveSpender(address creditAccount, address token, address spender, uint256 amount) internal {
        revertIfNotAllowedCollateral(token);
        CreditAccountHelper.safeApprove({creditAccount: creditAccount, token: token, spender: spender, amount: amount});
    }

    /// @dev Returns amount of token that should be transferred to receive `amount`
    function _amountWithFee(uint256 amount) internal view virtual returns (uint256) {
        return amount;
    }

    /// @dev Returns amount of token that will be received if `amount` is transferred
    function _amountMinusFee(uint256 amount) internal view virtual returns (uint256) {
        return amount;
    }

    /// @dev Internal wrapper for `creditAccount.safeTransfer` call to reduce contract size
    function _safeTransfer(address creditAccount, address token, address to, uint256 amount) internal {
        ICreditAccountV3(creditAccount).safeTransfer(token, to, amount);
    }

    /// @dev Internal wrapper for `creditAccount.execute` call to reduce contract size
    function _execute(address creditAccount, address target, bytes calldata callData) internal returns (bytes memory) {
        return ICreditAccountV3(creditAccount).execute(target, callData);
    }

    /// @dev Internal wrapper for `matchingEngine.repayCreditAccount` call to reduce contract size
    function _repayCreditAccount(address creditAccount, uint256 debt, uint256 profit, uint256 loss) internal {
        IMatchingEngineV3(matchingEngine).repayCreditAccount(creditAccount, debt, profit, loss);
    }

    /// @dev Internal wrapper for `matchingEngine.lendCreditAccount` call to reduce contract size
    function _lendCreditAccount(uint256 amount, address creditAccount) internal {
        IMatchingEngineV3(matchingEngine).lendCreditAccount(amount, creditAccount);
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
