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

// INTERFACES
import {IBotListV3} from "../interfaces/IBotListV3.sol";
import {AllowanceAction} from "../interfaces/ICreditConfiguratorV3.sol";
import {
    CumulativeLossParams,
    DebtLimits,
    FullCheckParams,
    ICreditFacadeV3,
    MultiCall
} from "../interfaces/ICreditFacadeV3.sol";
import "../interfaces/ICreditFacadeV3Multicall.sol";
import {
    CollateralCalcTask,
    CollateralDebtData,
    ICreditManagerV3,
    ManageDebtAction
} from "../interfaces/ICreditManagerV3.sol";
import {IDegenNFT} from "../interfaces/IDegenNFT.sol";
import "../interfaces/IExceptions.sol";
import {IPoolV3} from "../interfaces/IPoolV3.sol";
import {IPriceOracleV3, PriceUpdate} from "../interfaces/IPriceOracleV3.sol";
import {IWETH} from "../interfaces/external/IWETH.sol";

// LIBRARIES
import {Balance, BalanceDelta, BalanceWithMask, BalancesLogic, Comparison} from "../libraries/BalancesLogic.sol";
import {BitMask} from "../libraries/BitMask.sol";
import {
    BOT_PERMISSIONS_SET_FLAG,
    INACTIVE_CREDIT_ACCOUNT_ADDRESS,
    PERCENTAGE_FACTOR,
    UNDERLYING_TOKEN_MASK,
    DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER
} from "../libraries/Constants.sol";

// TRAITS
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";

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
/// @notice Credit facade implements a few safeguards on top of those present in the credit manager, including debt and
///         quota size validation, pausing on large protocol losses, Degen NFT whitelist mode, and forbidden tokens
///         (they count towards account value, but having them enabled as collateral restricts available actions and
///         activates a safer version of collateral check).
contract CreditFacadeV3 is ICreditFacadeV3, ACLNonReentrantTrait {
    using Address for address;
    using BitMask for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Maximum quota size, as a multiple of `maxDebt`
    uint256 public constant override maxQuotaMultiplier = 2;

    /// @notice Credit manager connected to this credit facade
    address public immutable override creditManager;

    /// @notice Credit manager's underlying token
    address public immutable override underlying;

    /// @notice Pool's treasury to pay fees to
    address public immutable override treasury;

    /// @notice Whether credit facade is expirable
    bool public immutable override expirable;

    /// @notice WETH token address
    address public immutable override weth;

    /// @notice Degen NFT address
    address public immutable override degenNFT;

    /// @notice Expiration timestamp
    uint40 public override expirationDate;

    /// @notice Maximum amount that can be borrowed by a credit manager in a single block, as a multiple of `maxDebt`
    uint8 public override maxDebtPerBlockMultiplier = DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER;

    /// @notice Last block when underlying was borrowed by a credit manager
    uint64 internal lastBlockBorrowed;

    /// @notice The total amount borrowed by a credit manager in `lastBlockBorrowed`
    uint128 internal totalBorrowedInBlock;

    /// @notice Bot list address
    address public immutable override botList;

    /// @notice Credit account debt limits packed into a single slot
    DebtLimits public override debtLimits;

    /// @notice Bit mask encoding a set of forbidden tokens
    uint256 public override forbiddenTokenMask;

    /// @notice Info on bad debt liquidation losses packed into a single slot
    CumulativeLossParams public override lossParams;

    /// @dev Set of emergency liquidators
    EnumerableSet.AddressSet internal _emergencyLiquidatorsSet;

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

    /// @dev Ensures that function can't be called when the contract is paused, unless caller is an emergency liquidator
    modifier whenNotPausedOrEmergency() {
        require(!paused() || canLiquidateWhilePaused(msg.sender), "Pausable: paused");
        _;
    }

    /// @dev Ensures that function can't be called when the contract is expired
    modifier whenNotExpired() {
        _checkExpired();
        _;
    }

    /// @dev Wraps any ETH sent in a function call and sends it back to the caller
    modifier wrapETH() {
        _wrapETH();
        _;
    }

    /// @notice Constructor
    /// @param _acl ACL contract address
    /// @param _creditManager Credit manager to connect this facade to
    /// @param _botList Bot list address
    /// @param _weth WETH token address
    /// @param _degenNFT Degen NFT address or `address(0)`
    /// @param _expirable Whether this facade should be expirable
    constructor(
        address _acl,
        address _creditManager,
        address _botList,
        address _weth,
        address _degenNFT,
        bool _expirable
    ) ACLNonReentrantTrait(_acl) nonZeroAddress(_botList) {
        creditManager = _creditManager; // U:[FA-1]
        botList = _botList; // U:[FA-1]
        weth = _weth; // U:[FA-1]
        degenNFT = _degenNFT; // U:[FA-1]
        expirable = _expirable; // U:[FA-1]

        underlying = ICreditManagerV3(_creditManager).underlying(); // U:[FA-1]
        treasury = IPoolV3(ICreditManagerV3(_creditManager).pool()).treasury(); // U:[FA-1]
    }

    /// @notice Whether `addr` is an approved emergency liquidator
    function canLiquidateWhilePaused(address addr) public view override returns (bool) {
        return _emergencyLiquidatorsSet.contains(addr);
    }

    /// @notice Returns emergency liquidators
    function emergencyLiquidators() external view override returns (address[] memory) {
        return _emergencyLiquidatorsSet.values();
    }

    // ------------------ //
    // ACCOUNT MANAGEMENT //
    // ------------------ //

    /// @notice Opens a new credit account
    ///         - Wraps any ETH sent in the function call and sends it back to the caller
    ///         - If Degen NFT is enabled, burns one from the caller
    ///         - Opens an account in the credit manager
    ///         - Performs a multicall (all calls allowed except debt decrease and withdrawals)
    ///         - Runs the collateral check
    /// @param onBehalfOf Address on whose behalf to open the account
    /// @param calls List of calls to perform after opening the account
    /// @param referralCode Referral code to use for potential rewards, 0 if no referral code is provided
    /// @return creditAccount Address of the newly opened account
    /// @dev Reverts if credit facade is paused or expired
    /// @dev Reverts if `onBehalfOf` is not caller while Degen NFT is enabled
    function openCreditAccount(address onBehalfOf, MultiCall[] calldata calls, uint256 referralCode)
        external
        payable
        override
        whenNotPaused // U:[FA-2]
        whenNotExpired // U:[FA-3]
        nonReentrant // U:[FA-4]
        wrapETH // U:[FA-7]
        returns (address creditAccount)
    {
        if (degenNFT != address(0)) {
            if (msg.sender != onBehalfOf) {
                revert ForbiddenInWhitelistedModeException(); // U:[FA-9]
            }
            IDegenNFT(degenNFT).burn(onBehalfOf, 1); // U:[FA-9]
        }

        creditAccount = ICreditManagerV3(creditManager).openCreditAccount({onBehalfOf: onBehalfOf}); // U:[FA-10]

        emit OpenCreditAccount(creditAccount, onBehalfOf, msg.sender, referralCode); // U:[FA-10]

        if (calls.length != 0) {
            _multicall({
                creditAccount: creditAccount,
                calls: calls,
                enabledTokensMask: UNDERLYING_TOKEN_MASK,
                flags: OPEN_CREDIT_ACCOUNT_PERMISSIONS
            }); // U:[FA-10]
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
        creditAccountOwnerOnly(creditAccount) // U:[FA-5]
        whenNotPaused // U:[FA-2]
        nonReentrant // U:[FA-4]
        wrapETH // U:[FA-7]
    {
        if (calls.length != 0) {
            _multicall({
                creditAccount: creditAccount,
                calls: calls,
                enabledTokensMask: _enabledTokensMaskOf(creditAccount),
                flags: CLOSE_CREDIT_ACCOUNT_PERMISSIONS | SKIP_COLLATERAL_CHECK_FLAG
            }); // U:[FA-11]
        }

        if (_flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG != 0) {
            IBotListV3(botList).eraseAllBotPermissions(creditAccount); // U:[FA-11]
        }

        ICreditManagerV3(creditManager).closeCreditAccount(creditAccount); // U:[FA-11]

        emit CloseCreditAccount(creditAccount, msg.sender); // U:[FA-11]
    }

    /// @notice Liquidates a credit account
    ///         - Updates price feeds before running all computations if such call is present in the multicall
    ///         - Evaluates account's collateral and debt to determine whether liquidated account is unhealthy or expired
    ///         - Performs a multicall (only `addCollateral`, `withdrawCollateral` and adapter calls are allowed)
    ///         - Liquidates a credit account in the credit manager, which repays debt to the pool, removes quotas, and
    ///           transfers underlying to the liquidator
    ///         - If pool incurs a loss on liquidation, further borrowing through the facade is forbidden
    ///         - If cumulative loss from bad debt liquidations exceeds the threshold, the facade is paused
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
    /// @dev When the credit facade is paused, reverts if caller is not an approved emergency liquidator
    /// @dev Reverts if `creditAccount` is not opened in connected credit manager
    /// @dev Reverts if account has no debt or is neither unhealthy nor expired
    /// @dev Reverts if remaining token balances increase during the multicall
    /// @dev Liquidator can fully seize non-enabled tokens so it's highly recommended to avoid holding them.
    ///      Since adapter calls are allowed, unclaimed rewards from integrated protocols are also at risk;
    ///      bots can be used to claim and withdraw them.
    function liquidateCreditAccount(address creditAccount, address to, MultiCall[] calldata calls)
        external
        override
        whenNotPausedOrEmergency // U:[FA-2,12]
        nonReentrant // U:[FA-4]
    {
        uint256 flags = LIQUIDATE_CREDIT_ACCOUNT_PERMISSIONS | SKIP_COLLATERAL_CHECK_FLAG;
        if (
            calls.length != 0 && calls[0].target == address(this)
                && bytes4(calls[0].callData) == ICreditFacadeV3Multicall.onDemandPriceUpdates.selector
        ) {
            _onDemandPriceUpdates(calls[0].callData[4:]);
            flags |= SKIP_PRICE_UPDATES_CALL_FLAG;
        }

        (CollateralDebtData memory collateralDebtData, bool isUnhealthy) = _revertIfNotLiquidatable(creditAccount); // U:[FA-13,16]

        BalanceWithMask[] memory initialBalances = BalancesLogic.storeBalances({
            creditAccount: creditAccount,
            tokensMask: collateralDebtData.enabledTokensMask.disable(UNDERLYING_TOKEN_MASK),
            getTokenByMaskFn: _getTokenByMask
        });

        _multicall(creditAccount, calls, collateralDebtData.enabledTokensMask, flags); // U:[FA-16]

        address failedToken = BalancesLogic.compareBalances({
            creditAccount: creditAccount,
            tokensMask: collateralDebtData.enabledTokensMask.disable(UNDERLYING_TOKEN_MASK),
            balances: initialBalances,
            comparison: Comparison.LESS_OR_EQUAL
        });
        if (failedToken != address(0)) revert RemainingTokenBalanceIncreasedException(failedToken); // U:[FA-14]

        collateralDebtData.enabledTokensMask = collateralDebtData.enabledTokensMask.enable(UNDERLYING_TOKEN_MASK); // U:[FA-16]

        (uint256 remainingFunds, uint256 reportedLoss) = ICreditManagerV3(creditManager).liquidateCreditAccount({
            creditAccount: creditAccount,
            collateralDebtData: collateralDebtData,
            to: to,
            isExpired: !isUnhealthy
        }); // U:[FA-15,16]

        emit LiquidateCreditAccount(creditAccount, msg.sender, to, remainingFunds); // U:[FA-16]

        if (reportedLoss != 0) {
            maxDebtPerBlockMultiplier = 0; // U:[FA-17]

            // both cast and addition are safe because amounts are of much smaller scale
            lossParams.currentCumulativeLoss += uint128(reportedLoss); // U:[FA-17]

            // can't pause an already paused contract
            if (!paused() && lossParams.currentCumulativeLoss > lossParams.maxCumulativeLoss) {
                _pause(); // U:[FA-17]
            }
        }
    }

    /// @notice Partially liquidates credit account's debt in exchange for discounted collateral
    ///         - Updates price feeds before running all computations
    ///         - Evaluates account's collateral and debt to determine whether liquidated account is unhealthy or expired
    ///         - Transfers underlying from the caller and uses it to repay account's debt and pay fees to the treasury
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
    /// @dev When the credit facade is paused, reverts if caller is not an approved emergency liquidator
    /// @dev Reverts if `creditAccount` is not opened in connected credit manager
    /// @dev Reverts if account has no debt or is neither unhealthy nor expired
    /// @dev Reverts if `token` is underlying
    /// @dev Like in full liquidations, liquidator can seize non-enabled tokens from the credit account, altough
    ///      here they are actually used to repay debt; unclaimed rewards are also safe in this case
    function partiallyLiquidateCreditAccount(
        address creditAccount,
        address token,
        uint256 repaidAmount,
        uint256 minSeizedAmount,
        address to,
        PriceUpdate[] calldata priceUpdates
    )
        external
        override
        whenNotPausedOrEmergency // U:[FA-2]
        nonReentrant // U:[FA-4]
        returns (uint256 seizedAmount)
    {
        address priceOracle = _priceOracle();
        IPriceOracleV3(priceOracle).updatePrices(priceUpdates);

        if (token == underlying) revert UnderlyingIsNotLiquidatableException();
        (CollateralDebtData memory cdd, bool isUnhealthy) = _revertIfNotLiquidatable(creditAccount);

        uint256 balanceBefore = IERC20(underlying).safeBalanceOf(creditAccount);
        _addCollateral(creditAccount, underlying, repaidAmount);
        repaidAmount = IERC20(underlying).safeBalanceOf(creditAccount) - balanceBefore;

        uint256 feeAmount;
        (repaidAmount, feeAmount, seizedAmount) =
            _calcPartialLiquidationPayments(repaidAmount, token, priceOracle, !isUnhealthy);
        if (seizedAmount < minSeizedAmount) revert SeizedLessThanRequiredException(seizedAmount);

        _manageDebt(creditAccount, repaidAmount, cdd.enabledTokensMask, ManageDebtAction.DECREASE_DEBT);
        _withdrawCollateral(creditAccount, underlying, feeAmount, treasury);
        _withdrawCollateral(creditAccount, token, seizedAmount, to);
        _fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMask: cdd.enabledTokensMask,
            collateralHints: new uint256[](0),
            minHealthFactor: PERCENTAGE_FACTOR,
            useSafePrices: false
        });

        emit PartiallyLiquidateCreditAccount(creditAccount, token, msg.sender, repaidAmount, seizedAmount, feeAmount);
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
        creditAccountOwnerOnly(creditAccount) // U:[FA-5]
        whenNotPaused // U:[FA-2]
        whenNotExpired // U:[FA-3]
        nonReentrant // U:[FA-4]
        wrapETH // U:[FA-7]
    {
        _multicall(creditAccount, calls, _enabledTokensMaskOf(creditAccount), ALL_PERMISSIONS); // U:[FA-18]
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
        whenNotPaused // U:[FA-2]
        whenNotExpired // U:[FA-3]
        nonReentrant // U:[FA-4]
    {
        _getBorrowerOrRevert(creditAccount); // U:[FA-5]

        (uint256 botPermissions, bool forbidden) =
            IBotListV3(botList).getBotStatus({bot: msg.sender, creditAccount: creditAccount});

        if (forbidden || botPermissions == 0 || _flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG == 0) {
            revert NotApprovedBotException(msg.sender); // U:[FA-19]
        }

        _multicall(creditAccount, calls, _enabledTokensMaskOf(creditAccount), botPermissions); // U:[FA-19, 20]
    }

    // --------- //
    // MULTICALL //
    // --------- //

    /// @dev Multicall implementation
    /// @param creditAccount Account to perform actions with
    /// @param calls Array of `(target, callData)` tuples representing a sequence of calls to perform
    ///        - if `target` is this contract's address, `callData` must be an ABI-encoded calldata of a method
    ///          from `ICreditFacadeV3Multicall`, which is dispatched and handled appropriately
    ///        - otherwise, `target` must be an allowed adapter, which is called with `callData`
    /// @param enabledTokensMask Bitmask of account's enabled collateral tokens before the multicall
    /// @param flags Flags that dictate multicall behaviour, including what methods are allowed to be called and
    ///        whether to execute collateral check after calls
    function _multicall(address creditAccount, MultiCall[] calldata calls, uint256 enabledTokensMask, uint256 flags)
        internal
    {
        // impossible value of forbidden tokens mask to indicate emptiness, see `_forbiddenTokensMaskRoE`
        uint256 forbiddenTokensMask = type(uint256).max;

        FullCheckParams memory fullCheckParams;
        BalanceWithMask[] memory forbiddenBalances;
        if (flags & SKIP_COLLATERAL_CHECK_FLAG == 0) {
            fullCheckParams.minHealthFactor = PERCENTAGE_FACTOR;
            forbiddenTokensMask = _forbiddenTokensMaskRoE(forbiddenTokensMask);
            forbiddenBalances = BalancesLogic.storeBalances({
                creditAccount: creditAccount,
                tokensMask: forbiddenTokensMask & enabledTokensMask,
                getTokenByMaskFn: _getTokenByMask
            });
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
                        (address token, uint256 amount) = abi.decode(mcall.callData[4:], (address, uint256)); // U:[FA-26A]
                        _addCollateral(creditAccount, token, amount); // U:[FA-26A]
                    }
                    // addCollateralWithPermit
                    else if (method == ICreditFacadeV3Multicall.addCollateralWithPermit.selector) {
                        _revertIfNoPermission(flags, ADD_COLLATERAL_PERMISSION); // U:[FA-21]
                        _addCollateralWithPermit(creditAccount, mcall.callData[4:]); // U:[FA-26B]
                    }
                    // updateQuota
                    else if (method == ICreditFacadeV3Multicall.updateQuota.selector) {
                        _revertIfNoPermission(flags, UPDATE_QUOTA_PERMISSION); // U:[FA-21]
                        (enabledTokensMask, forbiddenTokensMask) =
                            _updateQuota(creditAccount, mcall.callData[4:], enabledTokensMask, forbiddenTokensMask); // U:[FA-34]
                    }
                    // withdrawCollateral
                    else if (method == ICreditFacadeV3Multicall.withdrawCollateral.selector) {
                        _revertIfNoPermission(flags, WITHDRAW_COLLATERAL_PERMISSION); // U:[FA-21]
                        // pulls credit account on top of the stack
                        address creditAccount_ = creditAccount;
                        (address token, uint256 amount, address to) =
                            abi.decode(mcall.callData[4:], (address, uint256, address)); // U:[FA-36]
                        _withdrawCollateral(creditAccount_, token, amount, to); // U:[FA-36]
                        flags |= REVERT_ON_FORBIDDEN_TOKENS_FLAG | USE_SAFE_PRICES_FLAG; // U:[FA-36,45]
                    }
                    // increaseDebt
                    else if (method == ICreditFacadeV3Multicall.increaseDebt.selector) {
                        _revertIfNoPermission(flags, INCREASE_DEBT_PERMISSION); // U:[FA-21]
                        uint256 amount = abi.decode(mcall.callData[4:], (uint256)); // U:[FA-27]
                        _manageDebt(creditAccount, amount, enabledTokensMask, ManageDebtAction.INCREASE_DEBT); // U:[FA-27]
                        flags |= REVERT_ON_FORBIDDEN_TOKENS_FLAG; // U:[FA-45]
                    }
                    // decreaseDebt
                    else if (method == ICreditFacadeV3Multicall.decreaseDebt.selector) {
                        _revertIfNoPermission(flags, DECREASE_DEBT_PERMISSION); // U:[FA-21]
                        uint256 amount = abi.decode(mcall.callData[4:], (uint256)); // U:[FA-31]
                        _manageDebt(creditAccount, amount, enabledTokensMask, ManageDebtAction.DECREASE_DEBT); // U:[FA-31]
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
                        revert UnknownMethodException(method); // U:[FA-22]
                    }
                }
                // adapter calls
                else {
                    _revertIfNoPermission(flags, EXTERNAL_CALLS_PERMISSION); // U:[FA-21]
                    address targetContract = ICreditManagerV3(creditManager).adapterToContract(mcall.target);
                    if (targetContract == address(0)) {
                        revert TargetContractNotAllowedException();
                    }
                    if (flags & EXTERNAL_CONTRACT_WAS_CALLED_FLAG == 0) {
                        flags |= EXTERNAL_CONTRACT_WAS_CALLED_FLAG;
                        _setActiveCreditAccount(creditAccount); // U:[FA-38]
                    }
                    bool useSafePrices = abi.decode(mcall.target.functionCall(mcall.callData), (bool)); // U:[FA-38]
                    if (useSafePrices) flags |= REVERT_ON_FORBIDDEN_TOKENS_FLAG | USE_SAFE_PRICES_FLAG; // U:[FA-38,45]
                    emit Execute({creditAccount: creditAccount, targetContract: targetContract});
                }
            }
        }
        if (expectedBalances.length != 0) {
            address failedToken =
                BalancesLogic.compareBalances(creditAccount, expectedBalances, Comparison.GREATER_OR_EQUAL);
            if (failedToken != address(0)) revert BalanceLessThanExpectedException(failedToken); // U:[FA-23]
        }

        if (flags & EXTERNAL_CONTRACT_WAS_CALLED_FLAG != 0) _unsetActiveCreditAccount(); // U:[FA-38]

        emit FinishMultiCall(); // U:[FA-18]
        if (flags & SKIP_COLLATERAL_CHECK_FLAG != 0) return;

        // `forbiddenTokensMask` is non-empty at this point, so no need for `_forbiddenTokensMaskRoE`
        uint256 enabledForbiddenTokensMask = enabledTokensMask & forbiddenTokensMask;
        if (enabledForbiddenTokensMask != 0) {
            if (flags & REVERT_ON_FORBIDDEN_TOKENS_FLAG != 0) {
                revert ForbiddenTokensException(enabledForbiddenTokensMask);
            } // U:[FA-45]

            address failedToken = BalancesLogic.compareBalances({
                creditAccount: creditAccount,
                tokensMask: enabledForbiddenTokensMask,
                balances: forbiddenBalances,
                comparison: Comparison.LESS_OR_EQUAL
            });
            if (failedToken != address(0)) revert ForbiddenTokenBalanceIncreasedException(failedToken); // U:[FA-45]

            flags |= USE_SAFE_PRICES_FLAG; // U:[FA-45]
        }

        _fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMask,
            collateralHints: fullCheckParams.collateralHints,
            minHealthFactor: fullCheckParams.minHealthFactor,
            useSafePrices: flags & USE_SAFE_PRICES_FLAG != 0
        }); // U:[FA-24,34,45]
    }

    /// @dev `ICreditFacadeV3Multicall.setFullCheckParams` implementation
    function _setFullCheckParams(FullCheckParams memory fullCheckParams, bytes calldata callData) internal pure {
        (fullCheckParams.collateralHints, fullCheckParams.minHealthFactor) = abi.decode(callData, (uint256[], uint16)); // U:[FA-24]

        if (fullCheckParams.minHealthFactor < PERCENTAGE_FACTOR) {
            revert CustomHealthFactorTooLowException(); // U:[FA-24]
        }

        uint256 hintsLen = fullCheckParams.collateralHints.length;
        unchecked {
            for (uint256 j; j < hintsLen; ++j) {
                uint256 mask = fullCheckParams.collateralHints[j];
                if (mask <= UNDERLYING_TOKEN_MASK || mask & mask - 1 != 0) {
                    revert InvalidCollateralHintException(mask); // U:[FA-24]
                }
            }
        }
    }

    /// @dev `ICreditFacadeV3Multicall.onDemandPriceUpdates` implementation
    function _onDemandPriceUpdates(bytes calldata callData) internal {
        PriceUpdate[] memory updates = abi.decode(callData, (PriceUpdate[])); // U:[FA-25]

        IPriceOracleV3(_priceOracle()).updatePrices(updates); // U:[FA-25]
    }

    /// @dev `ICreditFacadeV3Multicall.addCollateral` implementation
    function _addCollateral(address creditAccount, address token, uint256 amount) internal {
        ICreditManagerV3(creditManager).addCollateral({
            payer: msg.sender,
            creditAccount: creditAccount,
            token: token,
            amount: amount
        }); // U:[FA-26A]

        emit AddCollateral(creditAccount, token, amount); // U:[FA-26A]
    }

    /// @dev `ICreditFacadeV3Multicall.addCollateralWithPermit` implementation
    function _addCollateralWithPermit(address creditAccount, bytes calldata callData) internal {
        (address token, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(callData, (address, uint256, uint256, uint8, bytes32, bytes32)); // U:[FA-26B]

        // `token` is only validated later in `addCollateral`, but to benefit off of it the attacker would have to make
        // it recognizable as collateral in the credit manager, which requires gaining configurator access rights
        try IERC20Permit(token).permit(msg.sender, creditManager, amount, deadline, v, r, s) {} catch {} // U:[FA-26B]

        _addCollateral(creditAccount, token, amount); // U:[FA-26B]
    }

    /// @dev `ICreditFacadeV3Multicall.{increase|decrease}Debt` implementation
    function _manageDebt(address creditAccount, uint256 amount, uint256 enabledTokensMask, ManageDebtAction action)
        internal
    {
        if (action == ManageDebtAction.INCREASE_DEBT) {
            _revertIfOutOfDebtPerBlockLimit(amount); // U:[FA-28]
        }

        (uint256 newDebt,,) =
            ICreditManagerV3(creditManager).manageDebt(creditAccount, amount, enabledTokensMask, action); // U:[FA-27,31]

        _revertIfOutOfDebtLimits(newDebt, action); // U:[FA-28,32,33]
    }

    /// @dev `ICreditFacadeV3Multicall.updateQuota` implementation
    function _updateQuota(
        address creditAccount,
        bytes calldata callData,
        uint256 enabledTokensMask,
        uint256 forbiddenTokensMask
    ) internal returns (uint256, uint256) {
        (address token, int96 quotaChange, uint96 minQuota) = abi.decode(callData, (address, int96, uint96)); // U:[FA-34]

        if (quotaChange > 0) {
            forbiddenTokensMask = _forbiddenTokensMaskRoE(forbiddenTokensMask);
            if (forbiddenTokensMask != 0 && _getTokenMaskOrRevert(token) & forbiddenTokensMask != 0) {
                revert ForbiddenTokenQuotaIncreasedException(token); // U:[FA-45]
            }
        }

        (uint256 tokensToEnable, uint256 tokensToDisable) = ICreditManagerV3(creditManager).updateQuota({
            creditAccount: creditAccount,
            token: token,
            quotaChange: quotaChange != type(int96).min
                ? quotaChange / int96(uint96(PERCENTAGE_FACTOR)) * int96(uint96(PERCENTAGE_FACTOR))
                : quotaChange,
            minQuota: minQuota,
            maxQuota: uint96(Math.min(type(uint96).max, maxQuotaMultiplier * debtLimits.maxDebt))
        }); // U:[FA-34]
        enabledTokensMask = enabledTokensMask.enableDisable(tokensToEnable, tokensToDisable); // U:[FA-34]
        return (enabledTokensMask, forbiddenTokensMask);
    }

    /// @dev `ICreditFacadeV3Multicall.withdrawCollateral` implementation
    function _withdrawCollateral(address creditAccount, address token, uint256 amount, address to) internal {
        if (amount == type(uint256).max) {
            amount = IERC20(token).safeBalanceOf(creditAccount);
            if (amount <= 1) return;
            unchecked {
                --amount;
            }
        }
        ICreditManagerV3(creditManager).withdrawCollateral(creditAccount, token, amount, to); // U:[FA-36]

        emit WithdrawCollateral(creditAccount, token, amount, to); // U:[FA-36]
    }

    /// @dev `ICreditFacadeV3Multicall.setBotPermissions` implementation
    function _setBotPermissions(address creditAccount, bytes calldata callData) internal {
        (address bot, uint192 permissions) = abi.decode(callData, (address, uint192));

        uint192 allowedPermissions = ALL_PERMISSIONS & ~SET_BOT_PERMISSIONS_PERMISSION;
        uint192 unexpectedPermissions = permissions & ~allowedPermissions;
        if (unexpectedPermissions != 0) revert UnexpectedPermissionsException(unexpectedPermissions); // U:[FA-37]

        uint256 remainingBots =
            IBotListV3(botList).setBotPermissions({bot: bot, creditAccount: creditAccount, permissions: permissions}); // U:[FA-37]

        if (remainingBots == 0) {
            _setFlagFor({creditAccount: creditAccount, flag: BOT_PERMISSIONS_SET_FLAG, value: false}); // U:[FA-37]
        } else if (_flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG == 0) {
            _setFlagFor({creditAccount: creditAccount, flag: BOT_PERMISSIONS_SET_FLAG, value: true}); // U:[FA-37]
        }
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets the credit facade expiration timestamp
    /// @param newExpirationDate New expiration timestamp
    /// @dev Reverts if caller is not credit configurator
    /// @dev Reverts if credit facade is not expirable
    function setExpirationDate(uint40 newExpirationDate)
        external
        override
        creditConfiguratorOnly // U:[FA-6]
    {
        if (!expirable) {
            revert NotAllowedWhenNotExpirableException(); // U:[FA-48]
        }
        expirationDate = newExpirationDate; // U:[FA-48]
    }

    /// @notice Sets debt limits per credit account
    /// @param newMinDebt New minimum debt amount per credit account
    /// @param newMaxDebt New maximum debt amount per credit account
    /// @param newMaxDebtPerBlockMultiplier New max debt per block multiplier, `type(uint8).max` to disable the check
    /// @dev Reverts if caller is not credit configurator
    /// @dev Reverts if `maxDebt * maxDebtPerBlockMultiplier` doesn't fit into `uint128`
    /// @dev Prevents further borrowing in the current block unless this check is disabled
    function setDebtLimits(uint128 newMinDebt, uint128 newMaxDebt, uint8 newMaxDebtPerBlockMultiplier)
        external
        override
        creditConfiguratorOnly // U:[FA-6]
    {
        if ((uint256(newMaxDebtPerBlockMultiplier) * newMaxDebt) > type(uint128).max) {
            revert IncorrectParameterException(); // U:[FA-49]
        }

        debtLimits.minDebt = newMinDebt; // U:[FA-49]
        debtLimits.maxDebt = newMaxDebt; // U:[FA-49]
        maxDebtPerBlockMultiplier = newMaxDebtPerBlockMultiplier; // U:[FA-49]
        lastBlockBorrowed = uint64(block.number); // U:[FA-49]
        totalBorrowedInBlock = type(uint128).max; // U:[FA-49]
    }

    /// @notice Sets the new max cumulative loss
    /// @param newMaxCumulativeLoss New max cumulative loss
    /// @param resetCumulativeLoss Whether to reset the current cumulative loss to zero
    /// @dev Reverts if caller is not credit configurator
    function setCumulativeLossParams(uint128 newMaxCumulativeLoss, bool resetCumulativeLoss)
        external
        override
        creditConfiguratorOnly // U:[FA-6]
    {
        lossParams.maxCumulativeLoss = newMaxCumulativeLoss; // U:[FA-51]
        if (resetCumulativeLoss) {
            lossParams.currentCumulativeLoss = 0; // U:[FA-51]
        }
    }

    /// @notice Changes token's forbidden status
    /// @param token Token to change the status for
    /// @param allowance Status to set
    /// @dev Reverts if caller is not credit configurator
    function setTokenAllowance(address token, AllowanceAction allowance)
        external
        override
        creditConfiguratorOnly // U:[FA-6]
    {
        uint256 tokenMask = _getTokenMaskOrRevert(token); // U:[FA-52]

        forbiddenTokenMask = (allowance == AllowanceAction.ALLOW)
            ? forbiddenTokenMask.disable(tokenMask)
            : forbiddenTokenMask.enable(tokenMask); // U:[FA-52]
    }

    /// @notice Changes account's status as emergency liquidator
    /// @param liquidator Account to change the status for
    /// @param allowance Status to set
    /// @dev Reverts if caller is not credit configurator
    function setEmergencyLiquidator(address liquidator, AllowanceAction allowance)
        external
        override
        creditConfiguratorOnly // U:[FA-6]
    {
        if (allowance == AllowanceAction.ALLOW) {
            _emergencyLiquidatorsSet.add(liquidator);
        } else {
            _emergencyLiquidatorsSet.remove(liquidator);
        } // U:[FA-53]
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Ensures that amount borrowed by credit manager in the current block does not exceed the limit
    /// @dev Skipped when `maxDebtPerBlockMultiplier == type(uint8).max`
    function _revertIfOutOfDebtPerBlockLimit(uint256 amount) internal {
        uint8 _maxDebtPerBlockMultiplier = maxDebtPerBlockMultiplier; // U:[FA-43]
        if (_maxDebtPerBlockMultiplier == type(uint8).max) return; // U:[FA-43]

        uint256 newDebtInCurrentBlock;
        if (lastBlockBorrowed == block.number) {
            newDebtInCurrentBlock = amount + totalBorrowedInBlock; // U:[FA-43]
        } else {
            newDebtInCurrentBlock = amount;
            lastBlockBorrowed = uint64(block.number); // U:[FA-43]
        }

        if (newDebtInCurrentBlock > uint256(_maxDebtPerBlockMultiplier) * debtLimits.maxDebt) {
            revert BorrowedBlockLimitException(); // U:[FA-43]
        }

        // the conversion is safe because of the check in `setDebtLimits`
        totalBorrowedInBlock = uint128(newDebtInCurrentBlock); // U:[FA-43]
    }

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
    function _revertIfNotLiquidatable(address creditAccount)
        internal
        view
        returns (CollateralDebtData memory cdd, bool isUnhealthy)
    {
        cdd = ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);
        isUnhealthy = cdd.twvUSD < cdd.totalDebtUSD;
        if (cdd.debt == 0 || !isUnhealthy && !_isExpired()) revert CreditAccountNotLiquidatableException();
    }

    /// @dev Calculates and returns partial liquidation payment amounts:
    ///      - amount of underlying that should go towards repaying debt
    ///      - amount of underlying that should go towards liquidation fees
    ///      - amount of collateral that should be sent to the liquidator
    function _calcPartialLiquidationPayments(uint256 repaidAmount, address token, address priceOracle, bool isExpired)
        internal
        view
        returns (uint256 repaidAmount_, uint256 feeAmount, uint256 seizedAmount)
    {
        (
            ,
            uint16 feeLiquidation,
            uint16 liquidationDiscount,
            uint16 feeLiquidationExpired,
            uint16 liquidationDiscountExpired
        ) = ICreditManagerV3(creditManager).fees();
        seizedAmount = IPriceOracleV3(priceOracle).convert(repaidAmount, underlying, token) * PERCENTAGE_FACTOR
            / (isExpired ? liquidationDiscountExpired : liquidationDiscount);
        feeAmount = repaidAmount * (isExpired ? feeLiquidationExpired : feeLiquidation) / PERCENTAGE_FACTOR;
        unchecked {
            repaidAmount_ = repaidAmount - feeAmount;
        }
    }

    /// @dev Read-on-empty function to read forbidden tokens mask at most once if it's needed, returns its argument
    ///      if it's not empty or `forbiddenTokenMask` otherwise
    /// @dev Non-empty forbidden tokens mask always has its LSB set to 0 since underlying can't be forbidden,
    ///      so we can use `type(uint256).max` as indicator that value is not yet initialized
    function _forbiddenTokensMaskRoE(uint256 forbiddenTokensMaskOrEmpty) internal view returns (uint256) {
        return forbiddenTokensMaskOrEmpty == type(uint256).max ? forbiddenTokenMask : forbiddenTokensMaskOrEmpty;
    }

    /// @dev Wraps any ETH sent in the function call and sends it back to `msg.sender`
    function _wrapETH() internal {
        if (msg.value != 0) {
            IWETH(weth).deposit{value: msg.value}(); // U:[FA-7]
            IERC20(weth).safeTransfer(msg.sender, msg.value); // U:[FA-7]
        }
    }

    /// @dev Whether credit facade has expired (`false` if it's not expirable or expiration timestamp is not set)
    function _isExpired() internal view returns (bool) {
        if (!expirable) return false; // U:[FA-46]
        uint40 _expirationDate = expirationDate;
        return _expirationDate != 0 && block.timestamp >= _expirationDate; // U:[FA-46]
    }

    /// @dev Internal wrapper for `creditManager.priceOracle` call to reduce contract size
    function _priceOracle() internal view returns (address) {
        return ICreditManagerV3(creditManager).priceOracle();
    }

    /// @dev Internal wrapper for `creditManager.fullCollateralCheck` call to reduce contract size
    function _fullCollateralCheck(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256[] memory collateralHints,
        uint16 minHealthFactor,
        bool useSafePrices
    ) internal {
        // older credit managers do not enable underlying token upon opening an account so it is done here
        ICreditManagerV3(creditManager).fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMask.enable(UNDERLYING_TOKEN_MASK),
            collateralHints: collateralHints,
            minHealthFactor: minHealthFactor,
            useSafePrices: useSafePrices
        });
    }

    /// @dev Internal wrapper for `creditManager.getBorrowerOrRevert` call to reduce contract size
    function _getBorrowerOrRevert(address creditAccount) internal view returns (address) {
        return ICreditManagerV3(creditManager).getBorrowerOrRevert({creditAccount: creditAccount});
    }

    /// @dev Internal wrapper for `creditManager.getTokenMaskOrRevert` call to reduce contract size
    function _getTokenMaskOrRevert(address token) internal view returns (uint256) {
        return ICreditManagerV3(creditManager).getTokenMaskOrRevert(token);
    }

    /// @dev Internal wrapper for `creditManager.getTokenByMask` call to reduce contract size
    function _getTokenByMask(uint256 mask) internal view returns (address) {
        return ICreditManagerV3(creditManager).getTokenByMask(mask);
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

    /// @dev Internal wrapper for `creditManager.enabledTokensMaskOf` call to reduce contract size
    function _enabledTokensMaskOf(address creditAccount) internal view returns (uint256) {
        return ICreditManagerV3(creditManager).enabledTokensMaskOf(creditAccount);
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

    /// @dev Reverts if credit facade is expired
    function _checkExpired() internal view {
        if (_isExpired()) {
            revert NotAllowedAfterExpirationException();
        }
    }
}
