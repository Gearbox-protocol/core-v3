// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

// THIRD-PARTY
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

// INTERFACES
import {IBotListV3} from "../interfaces/IBotListV3.sol";
import {AllowanceAction} from "../interfaces/ICreditConfiguratorV3.sol";
import {
    DebtLimits,
    FullCheckParams,
    ICreditFacadeV3,
    MultiCall,
    AccountOpeningParams
} from "../interfaces/ICreditFacadeV3.sol";
import "../interfaces/ICreditFacadeV3Multicall.sol";
import {
    CollateralCalcTask,
    CollateralDebtData,
    CollateralTokenData,
    ICreditManagerV3,
    ManageDebtAction
} from "../interfaces/ICreditManagerV3.sol";
import "../interfaces/IExceptions.sol";
import {IPriceOracleV3} from "../interfaces/IPriceOracleV3.sol";
import {IAddressProvider} from "../interfaces/base/IAddressProvider.sol";
import {IDegenNFT} from "../interfaces/base/IDegenNFT.sol";
import {ILossPolicy} from "../interfaces/base/ILossPolicy.sol";
import {IPhantomToken, IPhantomTokenWithdrawer} from "../interfaces/base/IPhantomToken.sol";
import {IPriceFeedStore, PriceUpdate} from "../interfaces/base/IPriceFeedStore.sol";
import {IWETH} from "../interfaces/external/IWETH.sol";

// LIBRARIES
import {Balance, BalanceDelta, BalancesLogic, Comparison} from "../libraries/BalancesLogic.sol";
import {BitMask} from "../libraries/BitMask.sol";
import {
    AP_PRICE_FEED_STORE,
    BOT_PERMISSIONS_SET_FLAG,
    INACTIVE_CREDIT_ACCOUNT_ADDRESS,
    NO_VERSION_CONTROL,
    PERCENTAGE_FACTOR,
    UNDERLYING_TOKEN_MASK,
    DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER
} from "../libraries/Constants.sol";
import {MarketHelper} from "../libraries/MarketHelper.sol";
import {OptionalCall} from "../libraries/OptionalCall.sol";

// TRAITS
import {ACLTrait} from "../traits/ACLTrait.sol";
import {ReentrancyGuardTrait} from "../traits/ReentrancyGuardTrait.sol";
import {SanityCheckTrait} from "../traits/SanityCheckTrait.sol";

/// TODO: add ability to forbid borrowing
/// TODO: add forced closure function

/// @title Credit facade V3
/// @notice Provides a user interface to open, close and liquidate leveraged positions in the credit manager,
///         and implements the main entry-point for credit accounts management: multicall.
/// @notice Multicall allows account owners to batch all the desired operations (adding or withdrawing collateral,
///         changing debt size, interacting with external protocols via adapters or increasing quotas) into one call,
///         followed by the collateral check that ensures that account is sufficiently collateralized.
///         For more details on what one can achieve with multicalls, see `_multicall` and  `ICreditFacadeV3Multicall`.
/// @notice Users can also let external bots manage their accounts via `botMulticall`. Bots can be relatively general,
///         the facade only ensures that they can do no harm to the protocol by running the collateral check after the
///         multicall and checking the permissions given to them by users. See `BotListV3` for additional details.
/// @notice Credit facade implements a few safeguards on top of those present in the credit manager, including
///         - debt and quota size validation
///         - degen NFT whitelist mode
///         - policies on how liquidations with loss are performed
///         - forbidden tokens (they count towards account value, but having them enabled as collateral restricts allowed
///         actions and triggers a safer version of collateral check, incentivizing users to decrease exposure to them).
contract CreditFacadeV3 is ICreditFacadeV3, Pausable, ACLTrait, ReentrancyGuardTrait, SanityCheckTrait {
    using Address for address;
    using BitMask for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using MarketHelper for ICreditManagerV3;

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Contract type
    bytes32 public constant override contractType = "CREDIT_FACADE";

    /// @notice Credit manager connected to this credit facade
    address public immutable override creditManager;

    /// @notice Credit manager's underlying token
    address public immutable override underlying;

    /// @notice Pool's treasury to pay fees to
    address public immutable override treasury;

    /// @notice Price feed store to update price feeds on-demand
    address public immutable override priceFeedStore;

    /// @notice WETH token address
    address public immutable override weth;

    /// @notice Bot list address
    address public immutable override botList;

    /// @notice Credit account debt limits packed into a single slot
    DebtLimits public override debtLimits;

    /// @notice Contract that enforces a policy on how liquidations with loss are performed
    address public override lossPolicy;

    /// @dev Ensures that function caller is credit configurator
    modifier creditConfiguratorOnly() {
        _checkCreditConfigurator();
        _;
    }

    /// @dev Ensures that function caller is `creditAccount`'s owner
    modifier creditAccountOwnerOnly(address creditAccount) {
        _checkCreditAccountOwner(creditAccount);
        _;
    }

    modifier matchingEngineOnly() {
        _checkMatchingEngine();
        _;
    }

    /// @dev Ensures that function can't be called when the contract is paused, unless
    ///      caller is an approved emergency liquidator
    modifier whenNotPausedOrEmergency() {
        require(!paused() || _hasRole("EMERGENCY_LIQUIDATOR", msg.sender), "Pausable: paused");
        _;
    }

    /// @dev Wraps any ETH sent in a function call and sends it back to the caller
    modifier wrapETH() {
        _wrapETH();
        _;
    }

    /// @notice Constructor
    /// @param _addressProvider Address provider contract address
    /// @param _creditManager Credit manager to connect this facade to
    /// @param _lossPolicy Loss policy address
    /// @param _botList Bot list address
    /// @param _weth WETH token address
    constructor(address _addressProvider, address _creditManager, address _lossPolicy, address _botList, address _weth)
        ACLTrait(ICreditManagerV3(_creditManager).getACL())
        nonZeroAddress(_lossPolicy)
        nonZeroAddress(_botList)
    {
        creditManager = _creditManager;
        lossPolicy = _lossPolicy;
        botList = _botList;
        weth = _weth;

        underlying = ICreditManagerV3(_creditManager).underlying();
        treasury = ICreditManagerV3(_creditManager).getTreasury();
        priceFeedStore = IAddressProvider(_addressProvider).getAddressOrRevert(AP_PRICE_FEED_STORE, NO_VERSION_CONTROL);
    }

    // ------------------ //
    // ACCOUNT MANAGEMENT //
    // ------------------ //

    function openCreditAccount(AccountOpeningParams calldata params)
        external
        payable
        whenNotPaused
        matchingEngineOnly
        nonReentrant
        wrapETH
        returns (address creditAccount)
    {
        creditAccount = ICreditManagerV3(creditManager)
            .openCreditAccount(
                params.onBehalfOf,
                params.interestRateModel,
                params.priceOracle,
                params.maturityTimestamp,
                params.collateralTokens
            );

        emit OpenCreditAccount(creditAccount, params.onBehalfOf);

        _manageDebt(creditAccount, params.debt, ManageDebtAction.INCREASE_DEBT);

        _addInitialCollaterals(creditAccount, params.inititalCollaterals);

        if (params.calls.length != 0) {
            _multicall({creditAccount: creditAccount, calls: params.calls, flags: OPEN_CREDIT_ACCOUNT_PERMISSIONS});
        }
    }

    /// @notice Closes a credit account
    ///         - Wraps any ETH sent in the function call and sends it back to the caller
    ///         - Performs a multicall (all calls are allowed except debt increase)
    ///         - Closes a credit account in the credit manager
    ///         - Erases all bots permissions
    /// @param creditAccount Account to close
    /// @param calls List of calls to perform before closing the account
    /// @dev Reverts if `creditAccount` is not opened in connected credit manager by caller
    /// @dev Reverts if facade is paused
    /// @dev Reverts if account's debt is not zero after executing `calls`
    function closeCreditAccount(address creditAccount, MultiCall[] calldata calls)
        external
        payable
        override
        creditAccountOwnerOnly(creditAccount)
        whenNotPaused
        nonReentrant
        wrapETH
    {
        if (calls.length != 0) {
            _multicall({
                creditAccount: creditAccount,
                calls: calls,
                flags: CLOSE_CREDIT_ACCOUNT_PERMISSIONS | SKIP_COLLATERAL_CHECK_FLAG
            });
        }

        if (_flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG != 0) {
            IBotListV3(botList).eraseAllBotPermissions(creditAccount);
        }

        ICreditManagerV3(creditManager).closeCreditAccount(creditAccount);

        emit CloseCreditAccount(creditAccount, msg.sender);
    }

    /// @notice Liquidates a credit account
    ///         - Updates price feeds before running all computations if such call is present in the multicall
    ///         - Evaluates account's collateral and debt to determine whether liquidated account is unhealthy or expired
    ///         - If account has bad debt, liquidation is only allowed when it doesn't violate the loss policy,
    ///           further borrowing through the facade is forbidden in this case
    ///         - Performs a multicall (only `addCollateral`, `withdrawCollateral` and adapter calls are allowed)
    ///         - Liquidates a credit account in the credit manager, which repays debt to the pool, removes quotas, and
    ///           transfers underlying to the liquidator
    /// @notice The function computes account’s total value (oracle value of enabled tokens), discounts it by liquidator’s
    ///         premium, and uses this value to compute funds due to the pool and owner.
    ///         Debt to the pool must be repaid in underlying, while funds due to owner might be covered by underlying
    ///         as well as by tokens that counted towards total value calculation, with the only condition that balance
    ///         of such tokens can’t be increased in the multicall.
    ///         Typically, a liquidator would swap all holdings on the account to underlying via multicall and receive
    ///         the premium in underlying.
    ///         An alternative strategy would be to add underlying collateral to repay debt and withdraw desired tokens
    ///         to handle them in another way, while remaining tokens would cover funds due to owner.
    /// @param creditAccount Account to liquidate
    /// @param to Address to transfer underlying left after liquidation
    /// @param calls List of calls to perform before liquidating the account
    /// @param lossPolicyData Additional data to pass to the loss policy contract
    /// @dev If facade is paused, reverts if caller is not an approved emergency liquidator
    /// @dev Reverts if `creditAccount` is not opened in connected credit manager
    /// @dev Reverts if account has no debt or is neither unhealthy nor expired
    /// @dev Reverts if remaining token balances increase during the multicall
    /// @dev Liquidator can fully seize non-enabled tokens so it's highly recommended to avoid holding them.
    ///      Since adapter calls are allowed, unclaimed rewards from integrated protocols are also at risk;
    ///      bots can be used to claim and withdraw them.
    function liquidateCreditAccount(
        address creditAccount,
        address to,
        MultiCall[] calldata calls,
        bytes memory lossPolicyData
    ) public override whenNotPausedOrEmergency nonReentrant {
        uint256 flags = LIQUIDATE_CREDIT_ACCOUNT_PERMISSIONS | SKIP_COLLATERAL_CHECK_FLAG;
        if (
            calls.length != 0 && calls[0].target == address(this)
                && bytes4(calls[0].callData) == ICreditFacadeV3Multicall.onDemandPriceUpdates.selector
        ) {
            _onDemandPriceUpdates(calls[0].callData[4:]);
            flags |= SKIP_PRICE_UPDATES_CALL_FLAG;
        }

        CollateralDebtData memory collateralDebtData = _revertIfNotLiquidatable(creditAccount);
        if (_hasBadDebt(collateralDebtData)) {
            ILossPolicy.Params memory params = ILossPolicy.Params({
                totalDebtUSD: collateralDebtData.totalDebtUSD,
                twvUSD: collateralDebtData.twvUSD,
                extraData: lossPolicyData
            });
            if (!ILossPolicy(lossPolicy).isLiquidatableWithLoss(creditAccount, msg.sender, params)) {
                revert CreditAccountNotLiquidatableWithLossException();
            }
        }

        Balance[] memory initialBalances = BalancesLogic.storeBalances({
            creditAccount: creditAccount, getTokensByCreditAccountFn: _getTokensByCreditAccount
        });

        _multicall(creditAccount, calls, flags);

        address failedToken = BalancesLogic.compareBalances({
            creditAccount: creditAccount, balances: initialBalances, comparison: Comparison.LESS_OR_EQUAL
        });
        if (failedToken != address(0)) revert RemainingTokenBalanceIncreasedException(failedToken); // U:[FA-14A]

        (uint256 remainingFunds,) = ICreditManagerV3(creditManager)
            .liquidateCreditAccount({creditAccount: creditAccount, collateralDebtData: collateralDebtData, to: to}); // U:[FA-14]

        emit LiquidateCreditAccount(creditAccount, msg.sender, to, remainingFunds); // U:[FA-14]
    }

    /// @dev Deprecated method that preserves liquidation signature from v3.0.x by using empty loss policy data
    function liquidateCreditAccount(address creditAccount, address to, MultiCall[] calldata calls) external override {
        liquidateCreditAccount(creditAccount, to, calls, "");
    }

    /// @notice Partially liquidates credit account's debt in exchange for discounted collateral
    ///         - Updates price feeds before running all computations
    ///         - Evaluates account's collateral and debt to determine whether liquidated account is unhealthy or expired
    ///         - Transfers underlying from the caller (requires approval to the credit manager) and uses it to repay
    ///           account's debt and pay fees to the treasury
    ///         - Transfers chosen collateral token at discounted oracle price to the liquidator (liquidation discount
    ///         and fee are the same as for full liquidations, though fees are not deposited into the pool)
    ///         - Runs the collateral check
    /// @param creditAccount Credit account to liquidate
    /// @param token Collateral token to seize
    /// @param repaidAmount Amount of underlying token to repay
    /// @param minSeizedAmount Minimum amount of `token` to seize from `creditAccount`
    /// @param to Account to withdraw seized `token` to
    /// @param priceUpdates On-demand price feed updates to apply before calculations, see `PriceUpdate` for details
    /// @return seizedAmount Amount of `token` seized
    /// @dev If facade is paused, reverts if caller is not an approved emergency liquidator
    /// @dev Reverts if `creditAccount` is not opened in connected credit manager
    /// @dev Reverts if account has no debt or is neither unhealthy nor expired
    /// @dev Reverts if `token` is underlying or if `token` is a phantom token and its `depositedToken` is underlying
    /// @dev If `token` is a phantom token, it's withdrawn first, and its `depositedToken` is then sent to the liquidator.
    ///      Both `seizedAmount` and `minSeizedAmount` refer to `depositedToken` in this case.
    /// @dev Like in full liquidations, liquidator can seize non-enabled tokens from the credit account, although here
    ///      they are actually used to repay debt. Unclaimed rewards are safe since adapter calls are not allowed.
    function partiallyLiquidateCreditAccount(
        address creditAccount,
        address token,
        uint256 repaidAmount,
        uint256 minSeizedAmount,
        address to,
        PriceUpdate[] calldata priceUpdates
    ) external override whenNotPausedOrEmergency nonReentrant returns (uint256 seizedAmount) {
        if (priceUpdates.length != 0) _updatePrices(priceUpdates);

        CollateralDebtData memory cdd = _revertIfNotLiquidatable(creditAccount);

        uint256 balanceBefore = IERC20(underlying).safeBalanceOf(creditAccount);
        _addCollateral(creditAccount, underlying, repaidAmount);
        repaidAmount = IERC20(underlying).safeBalanceOf(creditAccount) - balanceBefore;

        uint256 feeAmount;
        (repaidAmount, feeAmount, seizedAmount) =
            _calcPartialLiquidationPayments(creditAccount, repaidAmount, token, cdd.earlyClosurePenalty);

        uint256 flags;
        (token, seizedAmount, flags) = _tryWithdrawPhantomToken(creditAccount, token, seizedAmount, 0);
        if (token == underlying) revert UnderlyingIsNotLiquidatableException();
        if (seizedAmount < minSeizedAmount) revert SeizedLessThanRequiredException(seizedAmount);
        if (flags & EXTERNAL_CONTRACT_WAS_CALLED_FLAG != 0) _unsetActiveCreditAccount();

        _manageDebt(creditAccount, repaidAmount, ManageDebtAction.DECREASE_DEBT);
        _withdrawCollateral(creditAccount, underlying, feeAmount, treasury);
        _withdrawCollateral(creditAccount, token, seizedAmount, to);
        _fullCollateralCheck({creditAccount: creditAccount, minHealthFactor: PERCENTAGE_FACTOR, useSafePrices: false}); // U:[FA-16]

        emit PartiallyLiquidateCreditAccount(creditAccount, token, msg.sender, repaidAmount, seizedAmount, feeAmount); // U:[FA-16]
    }

    /// @notice Executes a batch of calls allowing user to manage their credit account
    ///         - Wraps any ETH sent in the function call and sends it back to the caller
    ///         - Performs a multicall (all calls are allowed)
    ///         - Runs the collateral check
    /// @param creditAccount Account to perform the calls on
    /// @param calls List of calls to perform
    /// @dev Reverts if `creditAccount` is not opened in connected credit manager by caller
    /// @dev Reverts if credit facade is paused or expired
    function multicall(address creditAccount, MultiCall[] calldata calls)
        external
        payable
        override
        creditAccountOwnerOnly(creditAccount)
        whenNotPaused
        nonReentrant
        wrapETH
    {
        _multicall(creditAccount, calls, ALL_PERMISSIONS);
    }

    /// @notice Executes a batch of calls allowing bot to manage a credit account
    ///         - Performs a multicall (allowed calls are determined by permissions given by account's owner)
    ///         - Runs the collateral check
    /// @param creditAccount Account to perform the calls on
    /// @param calls List of calls to perform
    /// @dev Reverts if credit facade is paused or expired
    /// @dev Reverts if `creditAccount` is not opened in connected credit manager
    /// @dev Reverts if calling bot is forbidden or has no permissions to manage `creditAccount`
    function botMulticall(address creditAccount, MultiCall[] calldata calls)
        external
        override
        whenNotPaused
        nonReentrant
    {
        _getBorrowerOrRevert(creditAccount);

        (uint256 botPermissions, bool forbidden) =
            IBotListV3(botList).getBotStatus({bot: msg.sender, creditAccount: creditAccount});

        if (forbidden || botPermissions == 0 || _flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG == 0) {
            revert NotApprovedBotException(msg.sender);
        }

        _multicall(creditAccount, calls, botPermissions);
    }

    /// TODO: consider debt limits

    function forceClosure(address creditAccount) external override matchingEngineOnly nonReentrant {
        ICreditManagerV3(creditManager).forceClosure(creditAccount);

        emit ForceClosure(creditAccount);
    }

    // --------- //
    // MULTICALL //
    // --------- //

    /// @dev Multicall implementation
    /// @param creditAccount Account to perform actions with
    /// @param calls Array of `(target, callData)` tuples representing a sequence of calls to perform
    ///        - if `target` is this contract's address, `callData` must be an ABI-encoded calldata of a method
    ///          from `ICreditFacadeV3Multicall`, which is dispatched and handled appropriately
    ///        - otherwise, `target` must be an allowed adapter, which is called with `callData`, and returns a flag
    ///          that indicates whether safety measures should apply (which include safe pricing in collateral check
    ///          and a check that there are no enabled forbidden tokens by the end of the multicall)
    /// @param flags Flags that dictate multicall behaviour, including what methods are allowed to be called and
    ///        whether to execute collateral check after calls
    function _multicall(address creditAccount, MultiCall[] calldata calls, uint256 flags) internal {
        FullCheckParams memory fullCheckParams;
        if (flags & SKIP_COLLATERAL_CHECK_FLAG == 0) {
            fullCheckParams.minHealthFactor = PERCENTAGE_FACTOR;
        }

        emit StartMultiCall({creditAccount: creditAccount, caller: msg.sender}); // U:[FA-18]

        Balance[] memory expectedBalances;
        unchecked {
            uint256 len = calls.length;
            for (uint256 i; i < len; ++i) {
                MultiCall calldata mcall = calls[i];

                // credit facade calls
                if (mcall.target == address(this)) {
                    bytes4 method = bytes4(mcall.callData);

                    // onDemandPriceUpdates
                    if (method == ICreditFacadeV3Multicall.onDemandPriceUpdates.selector) {
                        if (i != 0) revert UnknownMethodException(method); // U:[FA-22]
                        if (flags & SKIP_PRICE_UPDATES_CALL_FLAG == 0) _onDemandPriceUpdates(mcall.callData[4:]); // U:[FA-25]
                    }
                    // storeExpectedBalances
                    else if (method == ICreditFacadeV3Multicall.storeExpectedBalances.selector) {
                        if (expectedBalances.length != 0) revert ExpectedBalancesAlreadySetException(); // U:[FA-23]
                        BalanceDelta[] memory balanceDeltas = abi.decode(mcall.callData[4:], (BalanceDelta[])); // U:[FA-23]
                        expectedBalances = BalancesLogic.storeBalances(creditAccount, balanceDeltas); // U:[FA-23]
                    }
                    // compareBalances
                    else if (method == ICreditFacadeV3Multicall.compareBalances.selector) {
                        if (expectedBalances.length == 0) revert ExpectedBalancesNotSetException(); // U:[FA-23]
                        address failedToken =
                            BalancesLogic.compareBalances(creditAccount, expectedBalances, Comparison.GREATER_OR_EQUAL);
                        if (failedToken != address(0)) revert BalanceLessThanExpectedException(failedToken); // U:[FA-23]
                        expectedBalances = new Balance[](0); // U:[FA-23]
                    }
                    // addCollateral
                    else if (method == ICreditFacadeV3Multicall.addCollateral.selector) {
                        _revertIfNoPermission(flags, ADD_COLLATERAL_PERMISSION); // U:[FA-21]
                        _addCollateral(creditAccount, mcall.callData[4:]); // U:[FA-26A]
                    }
                    // addCollateralWithPermit
                    else if (method == ICreditFacadeV3Multicall.addCollateralWithPermit.selector) {
                        _revertIfNoPermission(flags, ADD_COLLATERAL_PERMISSION); // U:[FA-21]
                        _addCollateralWithPermit(creditAccount, mcall.callData[4:]); // U:[FA-26B]
                    }
                    // withdrawCollateral
                    else if (method == ICreditFacadeV3Multicall.withdrawCollateral.selector) {
                        _revertIfNoPermission(flags, WITHDRAW_COLLATERAL_PERMISSION); // U:[FA-21]
                        flags = _withdrawCollateral(creditAccount, mcall.callData[4:], flags); // U:[FA-36]
                    }
                    // decreaseDebt
                    else if (method == ICreditFacadeV3Multicall.decreaseDebt.selector) {
                        _revertIfNoPermission(flags, DECREASE_DEBT_PERMISSION); // U:[FA-21]
                        uint256 amount = abi.decode(mcall.callData[4:], (uint256)); // U:[FA-31]
                        _manageDebt(creditAccount, amount, ManageDebtAction.DECREASE_DEBT); // U:[FA-31]
                    }
                    // setBotPermissions
                    else if (method == ICreditFacadeV3Multicall.setBotPermissions.selector) {
                        _revertIfNoPermission(flags, SET_BOT_PERMISSIONS_PERMISSION); // U:[FA-21]
                        _setBotPermissions(creditAccount, mcall.callData[4:]); // U:[FA-37]
                    }
                    // setFullCheckParams
                    else if (method == ICreditFacadeV3Multicall.setFullCheckParams.selector) {
                        if (flags & SKIP_COLLATERAL_CHECK_FLAG != 0) revert UnknownMethodException(method); // U:[FA-22]
                        _setFullCheckParams(fullCheckParams, mcall.callData[4:]); // U:[FA-24]
                    }
                    // unknown method
                    else {
                        revert UnknownMethodException(method);
                    }
                }
                // adapter calls
                else {
                    _revertIfNoPermission(flags, EXTERNAL_CALLS_PERMISSION);
                    flags = _externalCall({
                        creditAccount: creditAccount,
                        target: ICreditManagerV3(creditManager).adapterToContract(mcall.target),
                        adapter: mcall.target,
                        callData: mcall.callData,
                        flags: flags
                    });
                }
            }
        }
        if (expectedBalances.length != 0) {
            address failedToken =
                BalancesLogic.compareBalances(creditAccount, expectedBalances, Comparison.GREATER_OR_EQUAL);
            if (failedToken != address(0)) revert BalanceLessThanExpectedException(failedToken);
        }

        if (flags & EXTERNAL_CONTRACT_WAS_CALLED_FLAG != 0) _unsetActiveCreditAccount();

        emit FinishMultiCall();
        if (flags & SKIP_COLLATERAL_CHECK_FLAG != 0) return;

        _fullCollateralCheck({
            creditAccount: creditAccount,
            minHealthFactor: fullCheckParams.minHealthFactor,
            useSafePrices: flags & USE_SAFE_PRICES_FLAG != 0
        });
    }

    /// @dev `ICreditFacadeV3Multicall.setFullCheckParams` implementation
    function _setFullCheckParams(FullCheckParams memory fullCheckParams, bytes calldata callData) internal pure {
        (fullCheckParams.minHealthFactor) = abi.decode(callData, (uint16)); // U:[FA-24]

        if (fullCheckParams.minHealthFactor < PERCENTAGE_FACTOR) {
            revert CustomHealthFactorTooLowException(); // U:[FA-24]
        }
    }

    /// @dev `ICreditFacadeV3Multicall.onDemandPriceUpdates` implementation
    function _onDemandPriceUpdates(bytes calldata callData) internal {
        PriceUpdate[] memory updates = abi.decode(callData, (PriceUpdate[]));

        _updatePrices(updates);
    }

    /// @dev `ICreditFacadeV3Multicall.addCollateral` implementation
    function _addCollateral(address creditAccount, bytes calldata callData) internal {
        (address token, uint256 amount) = abi.decode(callData, (address, uint256));
        if (amount == 0) revert AmountCantBeZeroException();

        _addCollateral(creditAccount, token, amount);
    }

    function _addInitialCollaterals(address creditAccount, Balance[] memory balances) internal {
        for (uint256 i = 0; i < balances.length; ++i) {
            if (balances[i].balance == 0) revert AmountCantBeZeroException();

            _addCollateral(creditAccount, balances[i].token, balances[i].balance);
        }
    }

    /// @dev `ICreditFacadeV3Multicall.addCollateralWithPermit` implementation
    function _addCollateralWithPermit(address creditAccount, bytes calldata callData) internal {
        (address token, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(callData, (address, uint256, uint256, uint8, bytes32, bytes32)); // U:[FA-26B]
        if (amount == 0) revert AmountCantBeZeroException(); // U:[FA-26B]

        // `token` is only validated later in `addCollateral`, but to benefit off of it the attacker would have to make
        // it recognizable as collateral in the credit manager, which requires gaining configurator access rights
        try IERC20Permit(token).permit(msg.sender, creditManager, amount, deadline, v, r, s) {} catch {} // U:[FA-26B]

        _addCollateral(creditAccount, token, amount); // U:[FA-26B]
    }

    /// @dev `ICreditFacadeV3Multicall.{increase|decrease}Debt` implementation
    function _manageDebt(address creditAccount, uint256 amount, ManageDebtAction action) internal {
        if (amount == 0) revert AmountCantBeZeroException(); // U:[FA-27,31]

        (uint256 newDebt,,) = ICreditManagerV3(creditManager).manageDebt(creditAccount, amount, action);

        _revertIfOutOfDebtLimits(newDebt, action);
    }

    /// @dev `ICreditFacadeV3Multicall.withdrawCollateral` implementation
    function _withdrawCollateral(address creditAccount, bytes calldata callData, uint256 flags)
        internal
        returns (uint256)
    {
        (address token, uint256 amount, address to) = abi.decode(callData, (address, uint256, address));

        if (amount == type(uint256).max) {
            amount = IERC20(token).safeBalanceOf(creditAccount);
            if (amount >= 1) {
                unchecked {
                    --amount;
                }
            }
        }
        if (amount == 0) revert AmountCantBeZeroException();

        (token, amount, flags) = _tryWithdrawPhantomToken(creditAccount, token, amount, flags);
        _withdrawCollateral(creditAccount, token, amount, to);
        return flags | USE_SAFE_PRICES_FLAG;
    }

    /// @dev `ICreditFacadeV3Multicall.setBotPermissions` implementation
    function _setBotPermissions(address creditAccount, bytes calldata callData) internal {
        (address bot, uint192 permissions) = abi.decode(callData, (address, uint192));

        uint192 allowedPermissions = ALL_PERMISSIONS & ~SET_BOT_PERMISSIONS_PERMISSION;
        uint192 unexpectedPermissions = permissions & ~allowedPermissions;
        if (unexpectedPermissions != 0) revert UnexpectedPermissionsException(unexpectedPermissions);

        uint256 remainingBots =
            IBotListV3(botList).setBotPermissions({bot: bot, creditAccount: creditAccount, permissions: permissions});

        if (remainingBots == 0) {
            _setFlagFor({creditAccount: creditAccount, flag: BOT_PERMISSIONS_SET_FLAG, value: false});
        } else if (_flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG == 0) {
            _setFlagFor({creditAccount: creditAccount, flag: BOT_PERMISSIONS_SET_FLAG, value: true});
        }
    }

    /// @dev Phantom token withdrawal implementation
    function _tryWithdrawPhantomToken(address creditAccount, address token, uint256 amount, uint256 flags)
        internal
        returns (address, uint256, uint256)
    {
        // NOTE: Some external tokens without `getPhantomTokenInfo` may have a fallback function that changes state,
        // which can cause a `THROW` that burns all gas, or does not change state and instead returns empty data.
        // To handle these cases, we use a special call construction with a strict gas limit.
        (bool success, bytes memory returnData) = OptionalCall.staticCallOptionalSafe({
            target: token,
            data: abi.encodeWithSelector(IPhantomToken.getPhantomTokenInfo.selector),
            gasAllowance: 30_000
        });
        if (!success) return (token, amount, flags);

        (address target, address depositedToken) = abi.decode(returnData, (address, address));

        // ensure that `token` is recognized by the credit manager
        _revertIfNotAllowedCollateral(token);

        uint256 balanceBefore = IERC20(depositedToken).safeBalanceOf(creditAccount);
        flags = _externalCall({
            creditAccount: creditAccount,
            target: target,
            adapter: ICreditManagerV3(creditManager).contractToAdapter(target),
            callData: abi.encodeCall(IPhantomTokenWithdrawer.withdrawPhantomToken, (token, amount)),
            flags: flags
        });

        emit WithdrawPhantomToken(creditAccount, token, amount);
        return (depositedToken, IERC20(depositedToken).safeBalanceOf(creditAccount) - balanceBefore, flags);
    }

    /// @dev Adapter call implementation
    function _externalCall(address creditAccount, address target, address adapter, bytes memory callData, uint256 flags)
        internal
        returns (uint256)
    {
        if (adapter == address(0) || target == address(0)) revert TargetContractNotAllowedException();

        if (flags & EXTERNAL_CONTRACT_WAS_CALLED_FLAG == 0) {
            _setActiveCreditAccount(creditAccount);
            flags |= EXTERNAL_CONTRACT_WAS_CALLED_FLAG;
        }

        bool useSafePrices = abi.decode(adapter.functionCall(callData), (bool));
        if (useSafePrices) flags |= USE_SAFE_PRICES_FLAG;

        emit Execute({creditAccount: creditAccount, targetContract: target});
        return flags;
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets debt limits per credit account
    /// @param newMinDebt New minimum debt amount per credit account
    /// @param newMaxDebt New maximum debt amount per credit account
    /// @dev Reverts if caller is not credit configurator
    /// @dev Reverts if `maxDebt * maxDebtPerBlockMultiplier` doesn't fit into `uint128`
    /// @dev Prevents further borrowing in the current block unless this check is disabled
    function setDebtLimits(uint128 newMinDebt, uint128 newMaxDebt) external override creditConfiguratorOnly {
        debtLimits.minDebt = newMinDebt;
        debtLimits.maxDebt = newMaxDebt;
    }

    /// @notice Sets the new loss policy
    /// @param newLossPolicy New loss policy
    /// @dev Reverts if caller is not credit configurator
    function setLossPolicy(address newLossPolicy)
        external
        override
        creditConfiguratorOnly // U:[FA-6]

    {
        lossPolicy = newLossPolicy; // U:[FA-51]
    }

    /// @notice Pauses contract, can only be called by an account with pausable admin role
    /// @dev Pause blocks all user entrypoints to the contract.
    ///      Liquidations remain open only to emergency liquidators.
    /// @dev Reverts if contract is already paused
    function pause() external override pausableAdminsOnly {
        _pause();
    }

    /// @notice Unpauses contract, can only be called by an account with unpausable admin role
    /// @dev Reverts if contract is already unpaused
    function unpause() external override unpausableAdminsOnly {
        _unpause();
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Ensures that account's debt principal takes allowed values:
    ///      - for borrowing, new debt must be within allowed limits
    ///      - for repayment, new debt must be above allowed minimum or zero
    function _revertIfOutOfDebtLimits(uint256 debt, ManageDebtAction action) internal view {
        if (debt == 0 && action == ManageDebtAction.DECREASE_DEBT) return;
        uint256 minDebt;
        uint256 maxDebt;

        // minDebt = debtLimits.minDebt;
        // maxDebt = debtLimits.maxDebt;
        assembly {
            let data := sload(debtLimits.slot)
            maxDebt := shr(128, data)
            minDebt := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }

        if (debt < minDebt || debt > maxDebt && action == ManageDebtAction.INCREASE_DEBT) {
            revert BorrowAmountOutOfLimitsException(); // U:[FA-44]
        }
    }

    /// @dev Ensures that `flags` has the `permission` bit enabled
    function _revertIfNoPermission(uint256 flags, uint256 permission) internal pure {
        if (flags & permission == 0) {
            revert NoPermissionException(permission); // U:[FA-39]
        }
    }

    /// @dev Ensures that `creditAccount` is liquidatable
    function _revertIfNotLiquidatable(address creditAccount) internal view returns (CollateralDebtData memory cdd) {
        cdd = ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);
        bool isForceClosable = ICreditManagerV3(creditManager).isAccountForceClosable(creditAccount);
        if (cdd.debt == 0 || (cdd.twvUSD >= cdd.totalDebtUSD && !isForceClosable)) {
            revert CreditAccountNotLiquidatableException();
        }
    }

    /// @dev Whether account's total value (minus liquidator's premium) is below its outstanding debt
    function _hasBadDebt(CollateralDebtData memory cdd) internal view returns (bool) {
        (,, uint16 liquidationDiscount,) = ICreditManagerV3(creditManager).fees();

        // NOTE: this formula does not account for transfer fees for simplicity, so there might be edge
        // cases when liquidation bypasses the loss policy, however loss size is bounded by the fee
        return cdd.totalValue * liquidationDiscount
            < (cdd.debt + cdd.accruedInterest) * (PERCENTAGE_FACTOR + cdd.earlyClosurePenalty);
    }

    /// @dev Calculates and returns partial liquidation payment amounts:
    ///      - amount of underlying that should go towards repaying debt
    ///      - amount of underlying that should go towards liquidation fees
    ///      - amount of collateral that should be sent to the liquidator
    function _calcPartialLiquidationPayments(
        address creditAccount,
        uint256 amount,
        address token,
        uint16 earlyClosurePenalty
    ) internal view returns (uint256 repaidAmount, uint256 feeAmount, uint256 seizedAmount) {
        address priceOracle = ICreditManagerV3(creditManager).priceOracleOf(creditAccount);
        (, uint16 feeLiquidation, uint16 liquidationDiscount,) = ICreditManagerV3(creditManager).fees();

        seizedAmount =
            IPriceOracleV3(priceOracle).convert(amount, underlying, token) * PERCENTAGE_FACTOR / liquidationDiscount;

        // the early exit amount is subtracted from the repaid amount,
        // so that repaid amount + fees + early exit penalty = amount charged
        uint256 earlyClosureAmount = amount * earlyClosurePenalty / PERCENTAGE_FACTOR;
        feeAmount = amount * feeLiquidation / PERCENTAGE_FACTOR;
        unchecked {
            // unchecked subtraction is safe because credit configurator ensures that liquidation fee is below 100%
            repaidAmount = amount - feeAmount - earlyClosureAmount;
        }
    }

    /// @dev Wraps any ETH sent in the function call and sends it back to `msg.sender`
    function _wrapETH() internal {
        if (msg.value != 0) {
            IWETH(weth).deposit{value: msg.value}(); // U:[FA-7]
            IERC20(weth).safeTransfer(msg.sender, msg.value); // U:[FA-7]
        }
    }

    /// @dev Internal wrapper for `priceFeedStore.updatePrices` call to reduce contract size
    function _updatePrices(PriceUpdate[] memory updates) internal {
        IPriceFeedStore(priceFeedStore).updatePrices(updates);
    }

    /// @dev Internal wrapper for `creditManager.addCollateral` call to reduce contract size
    function _addCollateral(address creditAccount, address token, uint256 amount) internal {
        ICreditManagerV3(creditManager)
            .addCollateral({payer: msg.sender, creditAccount: creditAccount, token: token, amount: amount});
        emit AddCollateral(creditAccount, token, amount);
    }

    /// @dev Internal wrapper for `creditManager.withdrawCollateral` call to reduce contract size
    function _withdrawCollateral(address creditAccount, address token, uint256 amount, address to) internal {
        ICreditManagerV3(creditManager)
            .withdrawCollateral({creditAccount: creditAccount, token: token, amount: amount, to: to});
        emit WithdrawCollateral(creditAccount, token, amount, to);
    }

    /// @dev Internal wrapper for `creditManager.fullCollateralCheck` call to reduce contract size
    function _fullCollateralCheck(address creditAccount, uint16 minHealthFactor, bool useSafePrices) internal {
        ICreditManagerV3(creditManager)
            .fullCollateralCheck({
            creditAccount: creditAccount, minHealthFactor: minHealthFactor, useSafePrices: useSafePrices
        });
    }

    /// @dev Internal wrapper for `creditManager.getBorrowerOrRevert` call to reduce contract size
    function _getBorrowerOrRevert(address creditAccount) internal view returns (address) {
        return ICreditManagerV3(creditManager).getBorrowerOrRevert({creditAccount: creditAccount});
    }

    /// @dev Internal wrapper for `creditManager.revertIfNotAllowedCollateral` call to reduce contract size
    function _revertIfNotAllowedCollateral(address token) internal view {
        ICreditManagerV3(creditManager).revertIfNotAllowedCollateral(token);
    }

    function _getTokensByCreditAccount(address creditAccount) internal view returns (address[] memory) {
        CollateralTokenData[] memory collateralTokens =
            ICreditManagerV3(creditManager).collateralTokensOf(creditAccount);
        address[] memory tokens = new address[](collateralTokens.length);
        for (uint256 i = 0; i < collateralTokens.length; ++i) {
            tokens[i] = collateralTokens[i].token;
        }
        return tokens;
    }

    /// @dev Internal wrapper for `creditManager.flagsOf` call to reduce contract size
    function _flagsOf(address creditAccount) internal view returns (uint16) {
        return ICreditManagerV3(creditManager).flagsOf(creditAccount);
    }

    /// @dev Internal wrapper for `creditManager.setFlagFor` call to reduce contract size
    function _setFlagFor(address creditAccount, uint16 flag, bool value) internal {
        ICreditManagerV3(creditManager).setFlagFor(creditAccount, flag, value);
    }

    /// @dev Internal wrapper for `creditManager.setActiveCreditAccount` call to reduce contract size
    function _setActiveCreditAccount(address creditAccount) internal {
        ICreditManagerV3(creditManager).setActiveCreditAccount(creditAccount);
    }

    /// @dev Same as above but unsets active credit account
    function _unsetActiveCreditAccount() internal {
        _setActiveCreditAccount(INACTIVE_CREDIT_ACCOUNT_ADDRESS);
    }

    /// @dev Reverts if `msg.sender` is not credit configurator
    function _checkCreditConfigurator() internal view {
        if (msg.sender != ICreditManagerV3(creditManager).creditConfigurator()) {
            revert CallerNotConfiguratorException();
        }
    }

    /// @dev Reverts if `msg.sender` is not `creditAccount` owner
    function _checkCreditAccountOwner(address creditAccount) internal view {
        if (msg.sender != _getBorrowerOrRevert(creditAccount)) {
            revert CallerNotCreditAccountOwnerException();
        }
    }

    function _checkMatchingEngine() internal view {
        if (msg.sender != ICreditManagerV3(creditManager).matchingEngine()) {
            revert CallerNotMatchingEngineException();
        }
    }
}
