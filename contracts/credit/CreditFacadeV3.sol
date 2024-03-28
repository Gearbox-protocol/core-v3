// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

// THIRD-PARTY
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

// LIBS & TRAITS
import {BalancesLogic, Balance, BalanceDelta, BalanceWithMask, Comparison} from "../libraries/BalancesLogic.sol";
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {BitMask, UNDERLYING_TOKEN_MASK} from "../libraries/BitMask.sol";

// INTERFACES
import "../interfaces/ICreditFacadeV3.sol";
import "../interfaces/IAddressProviderV3.sol";
import {
    ICreditManagerV3,
    ManageDebtAction,
    RevocationPair,
    CollateralDebtData,
    CollateralCalcTask,
    BOT_PERMISSIONS_SET_FLAG,
    INACTIVE_CREDIT_ACCOUNT_ADDRESS
} from "../interfaces/ICreditManagerV3.sol";
import {AllowanceAction} from "../interfaces/ICreditConfiguratorV3.sol";
import {IPriceOracleV3} from "../interfaces/IPriceOracleV3.sol";
import {IUpdatablePriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";

import {IPoolV3} from "../interfaces/IPoolV3.sol";
import {IDegenNFTV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IDegenNFTV2.sol";
import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {IBotListV3} from "../interfaces/IBotListV3.sol";

// CONSTANTS
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

uint256 constant OPEN_CREDIT_ACCOUNT_FLAGS = ALL_PERMISSIONS & ~DECREASE_DEBT_PERMISSION;

uint256 constant CLOSE_CREDIT_ACCOUNT_FLAGS = ALL_PERMISSIONS & ~INCREASE_DEBT_PERMISSION;

uint256 constant LIQUIDATE_CREDIT_ACCOUNT_FLAGS =
    EXTERNAL_CALLS_PERMISSION | ADD_COLLATERAL_PERMISSION | WITHDRAW_COLLATERAL_PERMISSION;

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
    using Address for address payable;
    using BitMask for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /// @notice Contract version
    uint256 public constant override version = 3_01;

    /// @notice Maximum quota size, as a multiple of `maxDebt`
    uint256 public constant override maxQuotaMultiplier = 2;

    /// @notice Credit manager connected to this credit facade
    address public immutable override creditManager;

    /// @notice Whether credit facade is expirable
    bool public immutable override expirable;

    /// @notice WETH token address
    address public immutable override weth;

    /// @notice Degen NFT address
    address public immutable override degenNFT;

    /// @notice Expiration timestamp
    uint40 public override expirationDate;

    /// @notice Maximum amount that can be borrowed by a credit manager in a single block, as a multiple of `maxDebt`
    uint8 public override maxDebtPerBlockMultiplier;

    /// @notice Last block when underlying was borrowed by a credit manager
    uint64 internal lastBlockBorrowed;

    /// @notice The total amount borrowed by a credit manager in `lastBlockBorrowed`
    uint128 internal totalBorrowedInBlock;

    /// @notice Bot list address
    address public override botList;

    /// @notice Credit account debt limits packed into a single slot
    DebtLimits public override debtLimits;

    /// @notice Bit mask encoding a set of forbidden tokens
    uint256 public override forbiddenTokenMask;

    /// @notice Info on bad debt liquidation losses packed into a single slot
    CumulativeLossParams public override lossParams;

    /// @notice Mapping account => emergency liquidator status
    mapping(address => bool) public override canLiquidateWhilePaused;

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
        require(!paused() || canLiquidateWhilePaused[msg.sender], "Pausable: paused");
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
    /// @param _creditManager Credit manager to connect this facade to
    /// @param _degenNFT Degen NFT address or `address(0)`
    /// @param _expirable Whether this facade should be expirable
    constructor(address _creditManager, address _degenNFT, bool _expirable)
        ACLNonReentrantTrait(ICreditManagerV3(_creditManager).addressProvider())
    {
        creditManager = _creditManager; // U:[FA-1]

        address addressProvider = ICreditManagerV3(_creditManager).addressProvider();
        weth = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_WETH_TOKEN, NO_VERSION_CONTROL); // U:[FA-1]
        botList = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_BOT_LIST, 3_00); // U:[FA-1]

        degenNFT = _degenNFT; // U:[FA-1]

        expirable = _expirable; // U:[FA-1]
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
            IDegenNFTV2(degenNFT).burn(onBehalfOf, 1); // U:[FA-9]
        }

        creditAccount = ICreditManagerV3(creditManager).openCreditAccount({onBehalfOf: onBehalfOf}); // U:[FA-10]

        emit OpenCreditAccount(creditAccount, onBehalfOf, msg.sender, referralCode); // U:[FA-10]

        if (calls.length != 0) {
            // same as `_multicallFullCollateralCheck` but leverages the fact that account is freshly opened to save gas
            BalanceWithMask[] memory forbiddenBalances;

            uint256 skipCalls = _applyOnDemandPriceUpdates(calls);
            FullCheckParams memory fullCheckParams = _multicall({
                creditAccount: creditAccount,
                calls: calls,
                enabledTokensMask: 0,
                flags: OPEN_CREDIT_ACCOUNT_FLAGS,
                skip: skipCalls
            }); // U:[FA-10]

            _fullCollateralCheck({
                creditAccount: creditAccount,
                enabledTokensMaskBefore: 0,
                fullCheckParams: fullCheckParams,
                forbiddenBalances: forbiddenBalances,
                forbiddenTokensMask: forbiddenTokenMask
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
    /// @dev Reverts if account has enabled tokens after executing `calls`
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
        uint256 enabledTokensMask = _enabledTokensMaskOf(creditAccount);

        if (calls.length != 0) {
            FullCheckParams memory fullCheckParams =
                _multicall(creditAccount, calls, enabledTokensMask, CLOSE_CREDIT_ACCOUNT_FLAGS, 0); // U:[FA-11]
            enabledTokensMask = fullCheckParams.enabledTokensMaskAfter;
        }

        if (enabledTokensMask != 0) revert CloseAccountWithEnabledTokensException(); // U:[FA-11]

        if (_flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG != 0) {
            IBotListV3(botList).eraseAllBotPermissions(creditManager, creditAccount); // U:[FA-11]
        }

        ICreditManagerV3(creditManager).closeCreditAccount(creditAccount); // U:[FA-11]

        emit CloseCreditAccount(creditAccount, msg.sender); // U:[FA-11]
    }

    /// @notice Liquidates a credit account
    ///         - Updates price feeds before running all computations if such calls are present in the multicall
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
    function liquidateCreditAccount(address creditAccount, address to, MultiCall[] calldata calls)
        external
        override
        whenNotPausedOrEmergency // U:[FA-2,12]
        nonReentrant // U:[FA-4]
    {
        uint256 skipCalls = _applyOnDemandPriceUpdates(calls);

        CollateralDebtData memory collateralDebtData =
            ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL); // U:[FA-16]

        bool isUnhealthy = collateralDebtData.twvUSD < collateralDebtData.totalDebtUSD;
        if (collateralDebtData.debt == 0 || !isUnhealthy && !_isExpired()) {
            revert CreditAccountNotLiquidatableException(); // U:[FA-13]
        }

        collateralDebtData.enabledTokensMask = collateralDebtData.enabledTokensMask.disable(UNDERLYING_TOKEN_MASK); // U:[FA-14]

        BalanceWithMask[] memory initialBalances = BalancesLogic.storeBalances({
            creditAccount: creditAccount,
            tokensMask: collateralDebtData.enabledTokensMask,
            getTokenByMaskFn: _getTokenByMask
        });

        FullCheckParams memory fullCheckParams = _multicall(
            creditAccount, calls, collateralDebtData.enabledTokensMask, LIQUIDATE_CREDIT_ACCOUNT_FLAGS, skipCalls
        ); // U:[FA-16]
        collateralDebtData.enabledTokensMask &= fullCheckParams.enabledTokensMaskAfter; // U:[FA-16]

        bool success = BalancesLogic.compareBalances({
            creditAccount: creditAccount,
            tokensMask: collateralDebtData.enabledTokensMask,
            balances: initialBalances,
            comparison: Comparison.LESS
        });
        if (!success) revert RemainingTokenBalanceIncreasedException(); // U:[FA-14]

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
        _multicallFullCollateralCheck(creditAccount, calls, ALL_PERMISSIONS); // U:[FA-18]
    }

    /// @notice Executes a batch of calls allowing bot to manage a credit account
    ///         - Performs a multicall (allowed calls are determined by permissions given by account's owner
    ///           or by DAO in case bot has special permissions in the credit manager)
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

        (uint256 botPermissions, bool forbidden, bool hasSpecialPermissions) = IBotListV3(botList).getBotStatus({
            bot: msg.sender,
            creditManager: creditManager,
            creditAccount: creditAccount
        });

        if (
            botPermissions == 0 || forbidden
                || (!hasSpecialPermissions && (_flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG == 0))
        ) {
            revert NotApprovedBotException(); // U:[FA-19]
        }

        _multicallFullCollateralCheck(creditAccount, calls, botPermissions); // U:[FA-19, 20]
    }

    /// @notice Sets `bot`'s permissions to manage `creditAccount`
    /// @param creditAccount Account to set permissions for
    /// @param bot Bot to set permissions for
    /// @param permissions A bit mask encoding bot permissions
    /// @dev Reverts if `creditAccount` is not opened in connected credit manager by caller
    /// @dev Reverts if `permissions` has unexpected bits enabled
    /// @dev Reverts if account has more active bots than allowed after changing permissions
    /// @dev Changes account's `BOT_PERMISSIONS_SET_FLAG` in the credit manager if needed
    function setBotPermissions(address creditAccount, address bot, uint192 permissions)
        external
        override
        creditAccountOwnerOnly(creditAccount) // U:[FA-5]
        nonReentrant // U:[FA-4]
    {
        if (permissions & ~ALL_PERMISSIONS != 0) revert UnexpectedPermissionsException(); // U:[FA-41]

        uint256 remainingBots = IBotListV3(botList).setBotPermissions({
            bot: bot,
            creditManager: creditManager,
            creditAccount: creditAccount,
            permissions: permissions
        }); // U:[FA-41]

        if (remainingBots == 0) {
            _setFlagFor({creditAccount: creditAccount, flag: BOT_PERMISSIONS_SET_FLAG, value: false}); // U:[FA-41]
        } else if (_flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG == 0) {
            _setFlagFor({creditAccount: creditAccount, flag: BOT_PERMISSIONS_SET_FLAG, value: true}); // U:[FA-41]
        }
    }

    // --------- //
    // MULTICALL //
    // --------- //

    /// @dev Batches price feed updates, multicall and collateral check into a single function
    function _multicallFullCollateralCheck(address creditAccount, MultiCall[] calldata calls, uint256 flags) internal {
        uint256 forbiddenTokensMask = forbiddenTokenMask;
        uint256 enabledTokensMaskBefore = _enabledTokensMaskOf(creditAccount); // U:[FA-18]
        BalanceWithMask[] memory forbiddenBalances = BalancesLogic.storeBalances({
            creditAccount: creditAccount,
            tokensMask: forbiddenTokensMask & enabledTokensMaskBefore,
            getTokenByMaskFn: _getTokenByMask
        });

        uint256 skipCalls = _applyOnDemandPriceUpdates(calls);
        FullCheckParams memory fullCheckParams = _multicall(
            creditAccount,
            calls,
            enabledTokensMaskBefore,
            forbiddenBalances.length != 0 ? flags.enable(FORBIDDEN_TOKENS_BEFORE_CALLS) : flags,
            skipCalls
        );

        _fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMaskBefore: enabledTokensMaskBefore,
            fullCheckParams: fullCheckParams,
            forbiddenBalances: forbiddenBalances,
            forbiddenTokensMask: forbiddenTokensMask
        }); // U:[FA-18]
    }

    /// @dev Multicall implementation
    /// @param creditAccount Account to perform actions with
    /// @param calls Array of `(target, callData)` tuples representing a sequence of calls to perform
    ///        - if `target` is this contract's address, `callData` must be an ABI-encoded calldata of a method
    ///          from `ICreditFacadeV3Multicall`, which is dispatched and handled appropriately
    ///        - otherwise, `target` must be an allowed adapter, which is called with `callData`, and is expected to
    ///          return two ABI-encoded `uint256` masks of tokens that should be enabled/disabled after the call
    /// @param enabledTokensMask Bitmask of account's enabled collateral tokens before the multicall
    /// @param flags Permissions and flags that dictate what methods can be called
    /// @param skip The number of calls that can be skipped (see `_applyOnDemandPriceUpdates`)
    /// @return fullCheckParams Collateral check parameters, see `FullCheckParams` for details
    function _multicall(
        address creditAccount,
        MultiCall[] calldata calls,
        uint256 enabledTokensMask,
        uint256 flags,
        uint256 skip
    ) internal returns (FullCheckParams memory fullCheckParams) {
        emit StartMultiCall({creditAccount: creditAccount, caller: msg.sender}); // U:[FA-18]

        uint256 quotedTokensMaskInverted;
        Balance[] memory expectedBalances;
        fullCheckParams.minHealthFactor = PERCENTAGE_FACTOR;

        unchecked {
            uint256 len = calls.length;
            for (uint256 i = skip; i < len; ++i) {
                MultiCall calldata mcall = calls[i];

                // credit facade calls
                if (mcall.target == address(this)) {
                    bytes4 method = bytes4(mcall.callData);

                    // storeExpectedBalances
                    if (method == ICreditFacadeV3Multicall.storeExpectedBalances.selector) {
                        if (expectedBalances.length != 0) revert ExpectedBalancesAlreadySetException(); // U:[FA-23]

                        BalanceDelta[] memory balanceDeltas = abi.decode(mcall.callData[4:], (BalanceDelta[])); // U:[FA-23]
                        expectedBalances = BalancesLogic.storeBalances(creditAccount, balanceDeltas); // U:[FA-23]
                    }
                    // compareBalances
                    else if (method == ICreditFacadeV3Multicall.compareBalances.selector) {
                        if (expectedBalances.length == 0) revert ExpectedBalancesNotSetException(); // U:[FA-23]

                        if (!BalancesLogic.compareBalances(creditAccount, expectedBalances, Comparison.GREATER)) {
                            revert BalanceLessThanExpectedException(); // U:[FA-23]
                        }
                        expectedBalances = new Balance[](0); // U:[FA-23]
                    }
                    // addCollateral
                    else if (method == ICreditFacadeV3Multicall.addCollateral.selector) {
                        _revertIfNoPermission(flags, ADD_COLLATERAL_PERMISSION); // U:[FA-21]

                        quotedTokensMaskInverted = _quotedTokensMaskInvertedLoE(quotedTokensMaskInverted);

                        enabledTokensMask = enabledTokensMask.enable({
                            bitsToEnable: _addCollateral(creditAccount, mcall.callData[4:]),
                            invertedSkipMask: quotedTokensMaskInverted
                        }); // U:[FA-26]
                    }
                    // addCollateralWithPermit
                    else if (method == ICreditFacadeV3Multicall.addCollateralWithPermit.selector) {
                        _revertIfNoPermission(flags, ADD_COLLATERAL_PERMISSION); // U:[FA-21]

                        quotedTokensMaskInverted = _quotedTokensMaskInvertedLoE(quotedTokensMaskInverted);

                        enabledTokensMask = enabledTokensMask.enable({
                            bitsToEnable: _addCollateralWithPermit(creditAccount, mcall.callData[4:]),
                            invertedSkipMask: quotedTokensMaskInverted
                        }); // U:[FA-26B]
                    }
                    // updateQuota
                    else if (method == ICreditFacadeV3Multicall.updateQuota.selector) {
                        _revertIfNoPermission(flags, UPDATE_QUOTA_PERMISSION); // U:[FA-21]

                        (uint256 tokensToEnable, uint256 tokensToDisable) =
                            _updateQuota(creditAccount, mcall.callData[4:], flags & FORBIDDEN_TOKENS_BEFORE_CALLS != 0); // U:[FA-34]
                        enabledTokensMask = enabledTokensMask.enableDisable(tokensToEnable, tokensToDisable); // U:[FA-34]
                    }
                    // withdrawCollateral
                    else if (method == ICreditFacadeV3Multicall.withdrawCollateral.selector) {
                        _revertIfNoPermission(flags, WITHDRAW_COLLATERAL_PERMISSION); // U:[FA-21]

                        fullCheckParams.revertOnForbiddenTokens = true; // U:[FA-30]
                        fullCheckParams.useSafePrices = true;

                        uint256 tokensToDisable = _withdrawCollateral(creditAccount, mcall.callData[4:]); // U:[FA-34]

                        quotedTokensMaskInverted = _quotedTokensMaskInvertedLoE(quotedTokensMaskInverted);

                        enabledTokensMask = enabledTokensMask.disable({
                            bitsToDisable: tokensToDisable,
                            invertedSkipMask: quotedTokensMaskInverted
                        }); // U:[FA-35]
                    }
                    // increaseDebt
                    else if (method == ICreditFacadeV3Multicall.increaseDebt.selector) {
                        _revertIfNoPermission(flags, INCREASE_DEBT_PERMISSION); // U:[FA-21]

                        fullCheckParams.revertOnForbiddenTokens = true; // U:[FA-30]

                        (uint256 tokensToEnable,) = _manageDebt(
                            creditAccount, mcall.callData[4:], enabledTokensMask, ManageDebtAction.INCREASE_DEBT
                        ); // U:[FA-27]
                        enabledTokensMask = enabledTokensMask.enable(tokensToEnable); // U:[FA-27]
                    }
                    // decreaseDebt
                    else if (method == ICreditFacadeV3Multicall.decreaseDebt.selector) {
                        _revertIfNoPermission(flags, DECREASE_DEBT_PERMISSION); // U:[FA-21]

                        (, uint256 tokensToDisable) = _manageDebt(
                            creditAccount, mcall.callData[4:], enabledTokensMask, ManageDebtAction.DECREASE_DEBT
                        ); // U:[FA-31]
                        enabledTokensMask = enabledTokensMask.disable(tokensToDisable); // U:[FA-31]
                    }
                    // setFullCheckParams
                    else if (method == ICreditFacadeV3Multicall.setFullCheckParams.selector) {
                        (fullCheckParams.collateralHints, fullCheckParams.minHealthFactor) =
                            abi.decode(mcall.callData[4:], (uint256[], uint16)); // U:[FA-24]

                        if (fullCheckParams.minHealthFactor < PERCENTAGE_FACTOR) {
                            revert CustomHealthFactorTooLowException(); // U:[FA-24]
                        }

                        uint256 hintsLen = fullCheckParams.collateralHints.length;
                        for (uint256 j; j < hintsLen; ++j) {
                            uint256 mask = fullCheckParams.collateralHints[j];
                            if (mask == 0 || mask & mask - 1 != 0) revert InvalidCollateralHintException(); // U:[FA-24]
                        }
                    }
                    // enableToken
                    else if (method == ICreditFacadeV3Multicall.enableToken.selector) {
                        _revertIfNoPermission(flags, ENABLE_TOKEN_PERMISSION); // U:[FA-21]
                        address token = abi.decode(mcall.callData[4:], (address)); // U:[FA-33]

                        quotedTokensMaskInverted = _quotedTokensMaskInvertedLoE(quotedTokensMaskInverted);

                        enabledTokensMask = enabledTokensMask.enable({
                            bitsToEnable: _getTokenMaskOrRevert(token),
                            invertedSkipMask: quotedTokensMaskInverted
                        }); // U:[FA-33]
                    }
                    // disableToken
                    else if (method == ICreditFacadeV3Multicall.disableToken.selector) {
                        _revertIfNoPermission(flags, DISABLE_TOKEN_PERMISSION); // U:[FA-21]
                        address token = abi.decode(mcall.callData[4:], (address)); // U:[FA-33]

                        quotedTokensMaskInverted = _quotedTokensMaskInvertedLoE(quotedTokensMaskInverted);

                        enabledTokensMask = enabledTokensMask.disable({
                            bitsToDisable: _getTokenMaskOrRevert(token),
                            invertedSkipMask: quotedTokensMaskInverted
                        }); // U:[FA-33]
                    }
                    // revokeAdapterAllowances
                    else if (method == ICreditFacadeV3Multicall.revokeAdapterAllowances.selector) {
                        _revertIfNoPermission(flags, REVOKE_ALLOWANCES_PERMISSION); // U:[FA-21]
                        _revokeAdapterAllowances(creditAccount, mcall.callData[4:]); // U:[FA-36]
                    }
                    // unknown method
                    else {
                        revert UnknownMethodException(); // U:[FA-22]
                    }
                }
                // adapter calls
                else {
                    _revertIfNoPermission(flags, EXTERNAL_CALLS_PERMISSION); // U:[FA-21]

                    bytes memory result;
                    {
                        address targetContract = ICreditManagerV3(creditManager).adapterToContract(mcall.target);
                        if (targetContract == address(0)) {
                            revert TargetContractNotAllowedException();
                        }

                        if (flags & EXTERNAL_CONTRACT_WAS_CALLED == 0) {
                            flags = flags.enable(EXTERNAL_CONTRACT_WAS_CALLED);
                            _setActiveCreditAccount(creditAccount); // U:[FA-38]
                        }

                        result = mcall.target.functionCall(mcall.callData); // U:[FA-38]

                        emit Execute({creditAccount: creditAccount, targetContract: targetContract});
                    }

                    (uint256 tokensToEnable, uint256 tokensToDisable) = abi.decode(result, (uint256, uint256)); // U:[FA-38]

                    quotedTokensMaskInverted = _quotedTokensMaskInvertedLoE(quotedTokensMaskInverted);

                    enabledTokensMask = enabledTokensMask.enableDisable({
                        bitsToEnable: tokensToEnable,
                        bitsToDisable: tokensToDisable,
                        invertedSkipMask: quotedTokensMaskInverted
                    }); // U:[FA-38]
                }
            }
        }

        if (expectedBalances.length != 0) {
            if (!BalancesLogic.compareBalances(creditAccount, expectedBalances, Comparison.GREATER)) {
                revert BalanceLessThanExpectedException(); // U:[FA-23]
            }
        }

        if (enabledTokensMask & forbiddenTokenMask != 0) {
            fullCheckParams.useSafePrices = true;
        }

        if (flags & EXTERNAL_CONTRACT_WAS_CALLED != 0) {
            _unsetActiveCreditAccount(); // U:[FA-38]
        }

        fullCheckParams.enabledTokensMaskAfter = enabledTokensMask; // U:[FA-38]

        emit FinishMultiCall(); // U:[FA-18]
    }

    /// @dev Applies on-demand price feed updates placed at the beginning of the multicall (if there are any)
    /// @return skipCalls Number of update calls made that can be skiped later in the `_multicall`
    function _applyOnDemandPriceUpdates(MultiCall[] calldata calls) internal returns (uint256 skipCalls) {
        address priceOracle;
        unchecked {
            uint256 len = calls.length;
            for (uint256 i; i < len; ++i) {
                MultiCall calldata mcall = calls[i];
                if (
                    mcall.target == address(this)
                        && bytes4(mcall.callData) == ICreditFacadeV3Multicall.onDemandPriceUpdate.selector
                ) {
                    (address token, bool reserve, bytes memory data) =
                        abi.decode(mcall.callData[4:], (address, bool, bytes)); // U:[FA-25]

                    priceOracle = _priceOracleLoE(priceOracle); // U:[FA-25]
                    address priceFeed = IPriceOracleV3(priceOracle).priceFeedsRaw(token, reserve); // U:[FA-25]

                    if (priceFeed == address(0)) {
                        revert PriceFeedDoesNotExistException(); // U:[FA-25]
                    }

                    IUpdatablePriceFeed(priceFeed).updatePrice(data); // U:[FA-25]
                } else {
                    return i;
                }
            }
            return len;
        }
    }

    /// @dev Performs collateral check to ensure that
    ///      - account is sufficiently collateralized
    ///      - account has no forbidden tokens after risky operations
    ///      - no forbidden tokens have been enabled during the multicall
    ///      - no enabled forbidden token balance has increased during the multicall
    function _fullCollateralCheck(
        address creditAccount,
        uint256 enabledTokensMaskBefore,
        FullCheckParams memory fullCheckParams,
        BalanceWithMask[] memory forbiddenBalances,
        uint256 forbiddenTokensMask
    ) internal {
        uint256 enabledTokensMask = ICreditManagerV3(creditManager).fullCollateralCheck(
            creditAccount,
            fullCheckParams.enabledTokensMaskAfter,
            fullCheckParams.collateralHints,
            fullCheckParams.minHealthFactor,
            fullCheckParams.useSafePrices
        ); // U:[FA-45]

        uint256 enabledForbiddenTokensMask = enabledTokensMask & forbiddenTokensMask;
        if (enabledForbiddenTokensMask != 0) {
            if (fullCheckParams.revertOnForbiddenTokens) revert ForbiddenTokensException(); // U:[FA-45]

            uint256 enabledForbiddenTokensMaskBefore = enabledTokensMaskBefore & forbiddenTokensMask;
            if (enabledForbiddenTokensMask & ~enabledForbiddenTokensMaskBefore != 0) {
                revert ForbiddenTokenEnabledException(); // U:[FA-45]
            }

            bool success = BalancesLogic.compareBalances({
                creditAccount: creditAccount,
                tokensMask: enabledForbiddenTokensMask,
                balances: forbiddenBalances,
                comparison: Comparison.LESS
            });

            if (!success) revert ForbiddenTokenBalanceIncreasedException(); // U:[FA-45]
        }
    }

    /// @dev `ICreditFacadeV3Multicall.addCollateral` implementation
    function _addCollateral(address creditAccount, bytes calldata callData) internal returns (uint256 tokensToEnable) {
        (address token, uint256 amount) = abi.decode(callData, (address, uint256)); // U:[FA-26]

        tokensToEnable = _addCollateral({payer: msg.sender, creditAccount: creditAccount, token: token, amount: amount}); // U:[FA-26]

        emit AddCollateral(creditAccount, token, amount); // U:[FA-26]
    }

    /// @dev `ICreditFacadeV3Multicall.addCollateralWithPermit` implementation
    function _addCollateralWithPermit(address creditAccount, bytes calldata callData)
        internal
        returns (uint256 tokensToEnable)
    {
        (address token, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(callData, (address, uint256, uint256, uint8, bytes32, bytes32)); // U:[FA-26B]

        // `token` is only validated later in `addCollateral`, but to benefit off of it the attacker would have to make
        // it recognizable as collateral in the credit manager, which requires gaining configurator access rights
        try IERC20Permit(token).permit(msg.sender, creditManager, amount, deadline, v, r, s) {} catch {} // U:[FA-26B]

        tokensToEnable = _addCollateral({payer: msg.sender, creditAccount: creditAccount, token: token, amount: amount}); // U:[FA-26B]

        emit AddCollateral(creditAccount, token, amount); // U:[FA-26B]
    }

    /// @dev `ICreditFacadeV3Multicall.{increase|decrease}Debt` implementation
    function _manageDebt(
        address creditAccount,
        bytes calldata callData,
        uint256 enabledTokensMask,
        ManageDebtAction action
    ) internal returns (uint256 tokensToEnable, uint256 tokensToDisable) {
        uint256 amount = abi.decode(callData, (uint256)); // U:[FA-27,31]

        if (action == ManageDebtAction.INCREASE_DEBT) {
            _revertIfOutOfBorrowingLimit(amount); // U:[FA-28]
        }

        uint256 newDebt;
        (newDebt, tokensToEnable, tokensToDisable) =
            ICreditManagerV3(creditManager).manageDebt(creditAccount, amount, enabledTokensMask, action); // U:[FA-27,31]

        _revertIfOutOfDebtLimits(newDebt); // U:[FA-28, 32, 33, 33A]

        if (action == ManageDebtAction.INCREASE_DEBT) {
            emit IncreaseDebt({creditAccount: creditAccount, amount: amount}); // U:[FA-27]
        } else {
            emit DecreaseDebt({creditAccount: creditAccount, amount: amount}); // U:[FA-31]
        }
    }

    /// @dev `ICreditFacadeV3Multicall.updateQuota` implementation
    function _updateQuota(address creditAccount, bytes calldata callData, bool hasForbiddenTokens)
        internal
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        (address token, int96 quotaChange, uint96 minQuota) = abi.decode(callData, (address, int96, uint96)); // U:[FA-34]

        // Ensures that user is not trying to increase quota for a forbidden token. This happens implicitly when user
        // has no enabled forbidden tokens because quota increase would try to enable the token, which is prohibited.
        // Thus some gas is saved in this case by not querying token's mask.
        if (hasForbiddenTokens && quotaChange > 0) {
            if (_getTokenMaskOrRevert(token) & forbiddenTokenMask != 0) {
                revert ForbiddenTokensException();
            }
        }

        (tokensToEnable, tokensToDisable) = ICreditManagerV3(creditManager).updateQuota({
            creditAccount: creditAccount,
            token: token,
            quotaChange: quotaChange != type(int96).min
                ? quotaChange / int96(uint96(PERCENTAGE_FACTOR)) * int96(uint96(PERCENTAGE_FACTOR))
                : quotaChange,
            minQuota: minQuota,
            maxQuota: uint96(Math.min(type(uint96).max, maxQuotaMultiplier * debtLimits.maxDebt))
        }); // U:[FA-34]
    }

    /// @dev `ICreditFacadeV3Multicall.withdrawCollateral` implementation
    function _withdrawCollateral(address creditAccount, bytes calldata callData)
        internal
        returns (uint256 tokensToDisable)
    {
        (address token, uint256 amount, address to) = abi.decode(callData, (address, uint256, address)); // U:[FA-35]

        if (amount == type(uint256).max) {
            amount = IERC20(token).balanceOf(creditAccount);
            if (amount <= 1) return 0;
            unchecked {
                --amount;
            }
        }
        tokensToDisable = ICreditManagerV3(creditManager).withdrawCollateral(creditAccount, token, amount, to); // U:[FA-35]

        emit WithdrawCollateral(creditAccount, token, amount, to); // U:[FA-35]
    }

    /// @dev `ICreditFacadeV3Multicall.revokeAdapterAllowances` implementation
    function _revokeAdapterAllowances(address creditAccount, bytes calldata callData) internal {
        RevocationPair[] memory revocations = abi.decode(callData, (RevocationPair[])); // U:[FA-36]

        ICreditManagerV3(creditManager).revokeAdapterAllowances(creditAccount, revocations); // U:[FA-36]
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
    function setDebtLimits(uint128 newMinDebt, uint128 newMaxDebt, uint8 newMaxDebtPerBlockMultiplier)
        external
        override
        creditConfiguratorOnly // U:[FA-6]
    {
        if ((uint256(newMaxDebtPerBlockMultiplier) * newMaxDebt) >= type(uint128).max) {
            revert IncorrectParameterException(); // U:[FA-49]
        }

        debtLimits.minDebt = newMinDebt; // U:[FA-49]
        debtLimits.maxDebt = newMaxDebt; // U:[FA-49]
        maxDebtPerBlockMultiplier = newMaxDebtPerBlockMultiplier; // U:[FA-49]
    }

    /// @notice Sets the new bot list
    /// @param newBotList New bot list address
    /// @dev Reverts if caller is not credit configurator
    function setBotList(address newBotList)
        external
        override
        creditConfiguratorOnly // U:[FA-6]
    {
        botList = newBotList; // U:[FA-50]
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
        canLiquidateWhilePaused[liquidator] = allowance == AllowanceAction.ALLOW; // U:[FA-53]
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Ensures that amount borrowed by credit manager in the current block does not exceed the limit
    /// @dev Skipped when `maxDebtPerBlockMultiplier == type(uint8).max`
    function _revertIfOutOfBorrowingLimit(uint256 amount) internal {
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

    /// @dev Ensures that account's debt principal is within allowed range or is zero
    function _revertIfOutOfDebtLimits(uint256 debt) internal view {
        uint256 minDebt;
        uint256 maxDebt;

        // minDebt = debtLimits.minDebt;
        // maxDebt = debtLimits.maxDebt;
        assembly {
            let data := sload(debtLimits.slot)
            maxDebt := shr(128, data)
            minDebt := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }

        if (debt != 0 && ((debt < minDebt) || (debt > maxDebt))) {
            revert BorrowAmountOutOfLimitsException(); // U:[FA-44]
        }
    }

    /// @dev Ensures that `flags` has the `permission` bit enabled
    function _revertIfNoPermission(uint256 flags, uint256 permission) internal pure {
        if (flags & permission == 0) {
            revert NoPermissionException(permission); // U:[FA-39]
        }
    }

    /// @dev Load-on-empty function to read inverted quoted tokens mask at most once if it's needed,
    ///      returns its argument if it's not empty or inverted `quotedTokensMask` from credit manager otherwise
    /// @dev Non-empty inverted quoted tokens mask always has it's LSB set to 1 since underlying can't be quoted
    function _quotedTokensMaskInvertedLoE(uint256 quotedTokensMaskInvertedOrEmpty) internal view returns (uint256) {
        return quotedTokensMaskInvertedOrEmpty == 0
            ? ~ICreditManagerV3(creditManager).quotedTokensMask()
            : quotedTokensMaskInvertedOrEmpty;
    }

    /// @dev Load-on-empty function to read price oracle at most once if it's needed,
    ///      returns its argument if it's not empty or `priceOracle` from credit manager otherwise
    /// @dev Non-empty price oracle always has non-zero address
    function _priceOracleLoE(address priceOracleOrEmpty) internal view returns (address) {
        return priceOracleOrEmpty == address(0) ? ICreditManagerV3(creditManager).priceOracle() : priceOracleOrEmpty;
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

    /// @dev Internal wrapper for `creditManager.addCollateral` call to reduce contract size
    function _addCollateral(address payer, address creditAccount, address token, uint256 amount)
        internal
        returns (uint256 tokenMask)
    {
        tokenMask = ICreditManagerV3(creditManager).addCollateral({
            payer: payer,
            creditAccount: creditAccount,
            token: token,
            amount: amount
        });
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
