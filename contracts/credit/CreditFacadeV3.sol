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
import {BalancesLogic, Balance, BalanceWithMask} from "../libraries/BalancesLogic.sol";
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {BitMask, UNDERLYING_TOKEN_MASK} from "../libraries/BitMask.sol";

// INTERFACES
import "../interfaces/ICreditFacadeV3.sol";
import "../interfaces/IAddressProviderV3.sol";
import {
    ICreditManagerV3,
    ClosureAction,
    ManageDebtAction,
    RevocationPair,
    CollateralDebtData,
    CollateralCalcTask,
    BOT_PERMISSIONS_SET_FLAG,
    INACTIVE_CREDIT_ACCOUNT_ADDRESS
} from "../interfaces/ICreditManagerV3.sol";
import {AllowanceAction} from "../interfaces/ICreditConfiguratorV3.sol";
import {ClaimAction, ETH_ADDRESS, IWithdrawalManagerV3} from "../interfaces/IWithdrawalManagerV3.sol";
import {IPriceOracleBase} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracleBase.sol";
import {IUpdatablePriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";

import {IPoolV3} from "../interfaces/IPoolV3.sol";
import {IDegenNFTV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IDegenNFTV2.sol";
import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {IBotListV3} from "../interfaces/IBotListV3.sol";

// CONSTANTS
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

uint256 constant OPEN_CREDIT_ACCOUNT_FLAGS =
    ALL_PERMISSIONS & ~(INCREASE_DEBT_PERMISSION | DECREASE_DEBT_PERMISSION | WITHDRAW_PERMISSION);

uint256 constant CLOSE_CREDIT_ACCOUNT_FLAGS = EXTERNAL_CALLS_PERMISSION;

/// @title Credit facade V3
/// @notice Provides a user interface to open, close and liquidate leveraged positions in the credit manager,
///         and implements the main entry-point for credit accounts management: multicall.
/// @notice Multicall allows account owners to batch all the desired operations (changing debt size, interacting with
///         external protocols via adapters, increasing quotas or scheduling withdrawals) into one call, followed by
///         the collateral check that ensures that account is sufficiently collateralized.
///         For more details on what one can achieve with multicalls, see `_multicall` and  `ICreditFacadeV3Multicall`.
/// @notice Users can also let external bots manage their accounts via `botMulticall`. Bots can be relatively general,
///         the facade only ensures that they can do no harm to the protocol by running the collateral check after the
///         multicall and checking the permissions given to them by users. See `BotListV3` for additional details.
/// @notice Credit facade implements a few safeguards on top of those present in the credit manager, including debt and
///         quota size validation, pausing on large protocol losses, Degen NFT whitelist mode, and forbidden tokens
///         (they count towards account value, but having them enabled as collateral restricts available actions).
contract CreditFacadeV3 is ICreditFacadeV3, ACLNonReentrantTrait {
    using Address for address;
    using BitMask for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice Maximum quota size, as a multiple of `maxDebt`
    uint256 public constant override maxQuotaMultiplier = 8;

    /// @notice Maximum number of approved bots for a credit account
    uint256 public constant override maxApprovedBots = 5;

    /// @notice Credit manager connected to this credit facade
    address public immutable override creditManager;

    /// @notice Whether credit facade is expirable
    bool public immutable override expirable;

    /// @notice WETH token address
    address public immutable override weth;

    /// @notice Withdrawal manager address
    address public immutable override withdrawalManager;

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

        weth = ICreditManagerV3(_creditManager).weth(); // U:[FA-1]
        withdrawalManager = ICreditManagerV3(_creditManager).withdrawalManager(); // U:[FA-1]
        botList =
            IAddressProviderV3(ICreditManagerV3(_creditManager).addressProvider()).getAddressOrRevert(AP_BOT_LIST, 3_00);

        degenNFT = _degenNFT; // U:[FA-1]

        expirable = _expirable; // U:[FA-1]
    }

    // ------------------ //
    // ACCOUNT MANAGEMENT //
    // ------------------ //

    /// @notice Opens a new credit account
    ///         - Wraps any ETH sent in the function call and sends it back to the caller
    ///         - If Degen NFT is enabled, burns one from the caller
    ///         - Opens an account in the credit manager and optionally borrows funds from the pool
    ///         - Performs a multicall (all calls allowed except debt size manipulation and withdrawals)
    ///         - Runs the collateral check
    /// @param debt Initial amount of underlying to borrow, can be 0
    /// @param onBehalfOf Address on whose behalf to open the account
    /// @param calls List of calls to perform after opening the account
    /// @param referralCode Referral code to use for potential rewards, 0 if no referral code is provided
    /// @return creditAccount Address of the newly opened account
    /// @dev Reverts if credit facade is paused or expired
    /// @dev If `debt` is non-zero, reverts if it is not within allowed range
    /// @dev Reverts if the total amount borrowed by the credit manager exceeds the limit
    /// @dev Reverts if `onBehalfOf` is not caller while Degen NFT is enabled
    function openCreditAccount(uint256 debt, address onBehalfOf, MultiCall[] calldata calls, uint16 referralCode)
        external
        payable
        override
        whenNotPaused // U:[FA-2]
        whenNotExpired // U:[FA-3]
        nonReentrant // U:[FA-4]
        wrapETH // U:[FA-7]
        returns (address creditAccount)
    {
        _revertIfOutOfDebtLimits(debt); // U:[FA-8]
        _revertIfOutOfBorrowingLimit(debt); // U:[FA-11]
        if (degenNFT != address(0)) {
            if (msg.sender != onBehalfOf) {
                revert ForbiddenInWhitelistedModeException(); // U:[FA-9]
            }
            IDegenNFTV2(degenNFT).burn(onBehalfOf, 1); // U:[FA-9]
        }

        creditAccount = ICreditManagerV3(creditManager).openCreditAccount({debt: debt, onBehalfOf: onBehalfOf}); // U:[FA-10]

        emit OpenCreditAccount(creditAccount, onBehalfOf, msg.sender, debt, referralCode); // U:[FA-10]

        // same as `_multicallFullCollateralCheck` but leverages the fact that account is freshly opened to save gas
        BalanceWithMask[] memory forbiddenBalances;

        uint256 skipCalls = _applyOnDemandPriceUpdates(calls);
        FullCheckParams memory fullCheckParams = _multicall({
            creditAccount: creditAccount,
            calls: calls,
            enabledTokensMask: debt == 0 ? 0 : UNDERLYING_TOKEN_MASK,
            flags: OPEN_CREDIT_ACCOUNT_FLAGS,
            skip: skipCalls
        }); // U:[FA-10]

        _fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMaskBefore: UNDERLYING_TOKEN_MASK,
            fullCheckParams: fullCheckParams,
            forbiddenBalances: forbiddenBalances,
            _forbiddenTokenMask: forbiddenTokenMask
        }); // U:[FA-10]
    }

    /// @notice Closes a credit account
    ///         - Wraps any ETH sent in the function call and sends it back to the caller
    ///         - Claims all scheduled withdrawals
    ///         - Erases all bots permissions
    ///         - Performs a multicall (only adapter calls allowed)
    ///         - Closes a credit account in the credit manager (all debt must be repaid for this step to succeed)
    /// @param creditAccount Account to close
    /// @param to Address to send withdrawals and any tokens left on the account after closure
    /// @param skipTokenMask Bit mask of tokens that should be skipped
    /// @param convertToETH Whether to unwrap WETH before sending to `to`
    /// @param calls List of calls to perform before closing the account
    /// @dev Reverts if caller is not `creditAccount`'s owner
    /// @dev Reverts if facade is paused
    function closeCreditAccount(
        address creditAccount,
        address to,
        uint256 skipTokenMask,
        bool convertToETH,
        MultiCall[] calldata calls
    )
        external
        payable
        override
        creditAccountOwnerOnly(creditAccount) // U:[FA-5]
        whenNotPaused // U:[FA-2]
        nonReentrant // U:[FA-4]
        wrapETH // U:[FA-7]
    {
        CollateralDebtData memory debtData = _calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY); // U:[FA-11]

        _claimWithdrawals(creditAccount, to, ClaimAction.FORCE_CLAIM); // U:[FA-11]

        if (calls.length != 0) {
            uint256 skipCalls = _applyOnDemandPriceUpdates(calls);

            FullCheckParams memory fullCheckParams =
                _multicall(creditAccount, calls, debtData.enabledTokensMask, CLOSE_CREDIT_ACCOUNT_FLAGS, skipCalls); // U:[FA-11]
            debtData.enabledTokensMask = fullCheckParams.enabledTokensMaskAfter; // U:[FA-11]
        }

        _eraseAllBotPermissions({creditAccount: creditAccount}); // U:[FA-11]

        _closeCreditAccount({
            creditAccount: creditAccount,
            closureAction: ClosureAction.CLOSE_ACCOUNT,
            collateralDebtData: debtData,
            payer: msg.sender,
            to: to,
            skipTokensMask: skipTokenMask,
            convertToETH: convertToETH
        }); // U:[FA-11]

        if (convertToETH) {
            _wethWithdrawTo(to); // U:[FA-11]
        }

        emit CloseCreditAccount(creditAccount, msg.sender, to); // U:[FA-11]
    }

    /// @notice Liquidates a credit account
    ///         - Updates price feeds before running all computations if such calls are present in the multicall
    ///         - Evaluates account's collateral and debt to determine whether liquidated account is unhealthy or expired
    ///         - Cancels immature scheduled withdrawals and returns tokens to the account (on emergency, even mature
    ///           withdrawals are returned)
    ///         - Performs a multicall (only adapter calls allowed)
    ///         - Erases all bots permissions
    ///         - Closes a credit account in the credit manager, distributing the funds between pool, owner and liquidator
    ///         - If pool incurs a loss on liquidation, further borrowing through the facade is forbidden
    ///         - If cumulative loss from bad debt liquidations exceeds the threshold, the facade is paused
    /// @notice Typically, a liquidator would swap all holdings on the account to underlying via multicall and receive
    ///         the premium. An alternative strategy would be to allow credit manager to take underlying shortfall from
    ///         the caller and receive all account's holdings directly to handle them in another way.
    /// @param creditAccount Account to liquidate
    /// @param to Address to send tokens left on the account after closure and funds distribution
    /// @param skipTokenMask Bit mask of tokens that should be skipped
    /// @param convertToETH Whether to unwrap WETH before sending to `to`
    /// @param calls List of calls to perform before liquidating the account
    /// @dev When the credit facade is paused, reverts if caller is not an approved emergency liquidator
    /// @dev Reverts if `creditAccount` is not opened in connected credit manager
    /// @dev Reverts if account is not liquidatable
    function liquidateCreditAccount(
        address creditAccount,
        address to,
        uint256 skipTokenMask,
        bool convertToETH,
        MultiCall[] calldata calls
    )
        external
        override
        whenNotPausedOrEmergency // U:[FA-2,12]
        nonReentrant // U:[FA-4]
    {
        // saves gas for late liquidations
        address borrower = _getBorrowerOrRevert(creditAccount); // U:[FA-5]

        uint256 skipCalls = _applyOnDemandPriceUpdates(calls);

        ClosureAction closeAction;
        CollateralDebtData memory collateralDebtData;
        {
            bool isEmergency = paused();

            collateralDebtData = _calcDebtAndCollateral(
                creditAccount,
                isEmergency
                    ? CollateralCalcTask.DEBT_COLLATERAL_FORCE_CANCEL_WITHDRAWALS
                    : CollateralCalcTask.DEBT_COLLATERAL_CANCEL_WITHDRAWALS
            ); // U:[FA-15]

            closeAction = ClosureAction.LIQUIDATE_ACCOUNT; // U:[FA-14]

            bool isLiquidatable = collateralDebtData.twvUSD < collateralDebtData.totalDebtUSD; // U:[FA-13]

            if (!isLiquidatable && _isExpired()) {
                isLiquidatable = true; // U:[FA-13]
                closeAction = ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT; // U:[FA-14]
            }

            if (!isLiquidatable) revert CreditAccountNotLiquidatableException(); // U:[FA-13]

            uint256 tokensToEnable = _claimWithdrawals({
                action: isEmergency ? ClaimAction.FORCE_CANCEL : ClaimAction.CANCEL,
                creditAccount: creditAccount,
                to: borrower
            }); // U:[FA-15]

            collateralDebtData.enabledTokensMask = collateralDebtData.enabledTokensMask.enable(tokensToEnable); // U:[FA-15]
        }

        if (skipCalls < calls.length) {
            FullCheckParams memory fullCheckParams = _multicall(
                creditAccount, calls, collateralDebtData.enabledTokensMask, CLOSE_CREDIT_ACCOUNT_FLAGS, skipCalls
            ); // U:[FA-16]
            collateralDebtData.enabledTokensMask = fullCheckParams.enabledTokensMaskAfter; // U:[FA-16]
        }

        _eraseAllBotPermissions({creditAccount: creditAccount}); // U:[FA-16]

        (uint256 remainingFunds, uint256 reportedLoss) = _closeCreditAccount({
            creditAccount: creditAccount,
            closureAction: closeAction,
            collateralDebtData: collateralDebtData,
            payer: msg.sender,
            to: to,
            skipTokensMask: skipTokenMask,
            convertToETH: convertToETH
        }); // U:[FA-16]

        if (reportedLoss > 0) {
            maxDebtPerBlockMultiplier = 0; // U:[FA-17]

            // both cast and addition are safe because amounts are of much smaller scale
            lossParams.currentCumulativeLoss += uint128(reportedLoss); // U:[FA-17]

            // can't pause an already paused contract
            if (!paused() && lossParams.currentCumulativeLoss > lossParams.maxCumulativeLoss) {
                _pause(); // U:[FA-17]
            }
        }

        if (convertToETH) {
            _wethWithdrawTo(to); // U:[FA-16]
        }

        emit LiquidateCreditAccount(creditAccount, borrower, msg.sender, to, closeAction, remainingFunds); // U:[FA-14,16,17]
    }

    /// @notice Executes a batch of calls allowing user to manage their credit account
    ///         - Wraps any ETH sent in the function call and sends it back to the caller
    ///         - Performs a multicall (all calls are allowed)
    ///         - Runs the collateral check
    /// @param creditAccount Account to perform the calls on
    /// @param calls List of calls to perform
    /// @dev Reverts if caller is not `creditAccount`'s owner
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
    ///         - Performs a multicall (allowed calls are determined by permissions given by account's owner; also,
    ///           unless caller is a special DAO-approved bot, it is allowed to call `payBot` to receive a payment)
    ///         - Runs the collateral check
    /// @param creditAccount Account to perform the calls on
    /// @param calls List of calls to perform
    /// @dev Reverts if credit facade is paused or expired
    /// @dev Reverts if calling bot is forbidden or has no permissions to manage `creditAccount`
    function botMulticall(address creditAccount, MultiCall[] calldata calls)
        external
        override
        whenNotPaused // U:[FA-2]
        whenNotExpired // U:[FA-3]
        nonReentrant // U:[FA-4]
    {
        (uint256 botPermissions, bool forbidden, bool hasSpecialPermissions) = IBotListV3(botList).getBotStatus({
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: msg.sender
        });

        if (
            botPermissions == 0 || forbidden
                || (!hasSpecialPermissions && (_flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG == 0))
        ) {
            revert NotApprovedBotException(); // U:[FA-19]
        }

        if (!hasSpecialPermissions) {
            botPermissions = botPermissions.enable(PAY_BOT_CAN_BE_CALLED);
        }

        _multicallFullCollateralCheck(creditAccount, calls, botPermissions); // U:[FA-19, 20]
    }

    /// @notice Claims all mature delayed withdrawals from `creditAccount` to `to`
    /// @param creditAccount Account to claim withdrawals from
    /// @param to Address to send the tokens to
    /// @dev Reverts if credit facade is paused
    /// @dev Reverts if caller is not `creditAccount`'s owner
    function claimWithdrawals(address creditAccount, address to)
        external
        override
        creditAccountOwnerOnly(creditAccount) // U:[FA-5]
        whenNotPaused // U:[FA-2]
        nonReentrant // U:[FA-4]
    {
        _claimWithdrawals(creditAccount, to, ClaimAction.CLAIM); // U:[FA-40]
    }

    /// @notice Sets bot permissions to manage `creditAccount` as well as funding parameters
    /// @param creditAccount Account to set permissions for
    /// @param bot Bot to set permissions for
    /// @param permissions A bit mask encoding bot permissions
    /// @param totalFundingAllowance Total amount of WETH available to bot for payments
    /// @param weeklyFundingAllowance Amount of WETH available to bot for payments weekly
    /// @dev Reverts if caller is not `creditAccount`'s owner
    /// @dev Reverts if account has more active bots than allowed after changing permissions
    //       to prevent users from inflating liquidation gas costs
    /// @dev Changes account's `BOT_PERMISSIONS_SET_FLAG` in the credit manager if needed
    function setBotPermissions(
        address creditAccount,
        address bot,
        uint192 permissions,
        uint72 totalFundingAllowance,
        uint72 weeklyFundingAllowance
    )
        external
        override
        creditAccountOwnerOnly(creditAccount) // U:[FA-5]
        nonReentrant // U:[FA-4]
    {
        uint256 remainingBots = IBotListV3(botList).setBotPermissions({
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: bot,
            permissions: permissions,
            totalFundingAllowance: totalFundingAllowance,
            weeklyFundingAllowance: weeklyFundingAllowance
        }); // U:[FA-41]

        if (remainingBots > maxApprovedBots) {
            revert TooManyApprovedBotsException(); // U:[FA-41]
        }

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
        uint256 _forbiddenTokenMask = forbiddenTokenMask;
        uint256 enabledTokensMaskBefore = ICreditManagerV3(creditManager).enabledTokensMaskOf(creditAccount); // U:[FA-18]
        BalanceWithMask[] memory forbiddenBalances = BalancesLogic.storeForbiddenBalances({
            creditAccount: creditAccount,
            forbiddenTokenMask: _forbiddenTokenMask,
            enabledTokensMask: enabledTokensMaskBefore,
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
            _forbiddenTokenMask: _forbiddenTokenMask
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

                    // revertIfReceivedLessThan
                    if (method == ICreditFacadeV3Multicall.revertIfReceivedLessThan.selector) {
                        if (expectedBalances.length != 0) {
                            revert ExpectedBalancesAlreadySetException(); // U:[FA-23]
                        }

                        Balance[] memory balanceDeltas = abi.decode(mcall.callData[4:], (Balance[])); // U:[FA-23]
                        expectedBalances = BalancesLogic.storeBalances(creditAccount, balanceDeltas); // U:[FA-23]
                    }
                    // addCollateral
                    else if (method == ICreditFacadeV3Multicall.addCollateral.selector) {
                        _revertIfNoPermission(flags, ADD_COLLATERAL_PERMISSION); // U:[FA-21]

                        quotedTokensMaskInverted = _getInvertedQuotedTokensMask(quotedTokensMaskInverted);

                        enabledTokensMask = enabledTokensMask.enable({
                            bitsToEnable: _addCollateral(creditAccount, mcall.callData[4:]),
                            invertedSkipMask: quotedTokensMaskInverted
                        }); // U:[FA-26]
                    }
                    // addCollateralWithPermit
                    else if (method == ICreditFacadeV3Multicall.addCollateralWithPermit.selector) {
                        _revertIfNoPermission(flags, ADD_COLLATERAL_PERMISSION); // U:[FA-21]

                        quotedTokensMaskInverted = _getInvertedQuotedTokensMask(quotedTokensMaskInverted);

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
                    // scheduleWithdrawal
                    else if (method == ICreditFacadeV3Multicall.scheduleWithdrawal.selector) {
                        _revertIfNoPermission(flags, WITHDRAW_PERMISSION); // U:[FA-21]

                        flags = flags.enable(REVERT_ON_FORBIDDEN_TOKENS_AFTER_CALLS);

                        uint256 tokensToDisable = _scheduleWithdrawal(creditAccount, mcall.callData[4:]); // U:[FA-34]

                        quotedTokensMaskInverted = _getInvertedQuotedTokensMask(quotedTokensMaskInverted);

                        enabledTokensMask = enabledTokensMask.disable({
                            bitsToDisable: tokensToDisable,
                            invertedSkipMask: quotedTokensMaskInverted
                        }); // U:[FA-35]
                    }
                    // increaseDebt
                    else if (method == ICreditFacadeV3Multicall.increaseDebt.selector) {
                        _revertIfNoPermission(flags, INCREASE_DEBT_PERMISSION); // U:[FA-21]

                        flags = flags.enable(REVERT_ON_FORBIDDEN_TOKENS_AFTER_CALLS).disable(DECREASE_DEBT_PERMISSION); // U:[FA-29]

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
                    // payBot
                    else if (method == ICreditFacadeV3Multicall.payBot.selector) {
                        _revertIfNoPermission(flags, PAY_BOT_CAN_BE_CALLED); // U:[FA-21]
                        flags = flags.disable(PAY_BOT_CAN_BE_CALLED); // U:[FA-37]
                        _payBot(creditAccount, mcall.callData[4:]); // U:[FA-37]
                    }
                    // setFullCheckParams
                    else if (method == ICreditFacadeV3Multicall.setFullCheckParams.selector) {
                        (fullCheckParams.collateralHints, fullCheckParams.minHealthFactor) =
                            abi.decode(mcall.callData[4:], (uint256[], uint16)); // U:[FA-24]
                    }
                    // enableToken
                    else if (method == ICreditFacadeV3Multicall.enableToken.selector) {
                        _revertIfNoPermission(flags, ENABLE_TOKEN_PERMISSION); // U:[FA-21]
                        address token = abi.decode(mcall.callData[4:], (address)); // U:[FA-33]

                        quotedTokensMaskInverted = _getInvertedQuotedTokensMask(quotedTokensMaskInverted);

                        enabledTokensMask = enabledTokensMask.enable({
                            bitsToEnable: _getTokenMaskOrRevert(token),
                            invertedSkipMask: quotedTokensMaskInverted
                        }); // U:[FA-33]
                    }
                    // disableToken
                    else if (method == ICreditFacadeV3Multicall.disableToken.selector) {
                        _revertIfNoPermission(flags, DISABLE_TOKEN_PERMISSION); // U:[FA-21]
                        address token = abi.decode(mcall.callData[4:], (address)); // U:[FA-33]

                        quotedTokensMaskInverted = _getInvertedQuotedTokensMask(quotedTokensMaskInverted);

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

                    quotedTokensMaskInverted = _getInvertedQuotedTokensMask(quotedTokensMaskInverted);

                    enabledTokensMask = enabledTokensMask.enableDisable({
                        bitsToEnable: tokensToEnable,
                        bitsToDisable: tokensToDisable,
                        invertedSkipMask: quotedTokensMaskInverted
                    }); // U:[FA-38]
                }
            }
        }

        if (expectedBalances.length != 0) {
            bool success = BalancesLogic.compareBalances(creditAccount, expectedBalances);
            if (!success) revert BalanceLessThanMinimumDesiredException(); // U:[FA-23]
        }

        if ((flags & REVERT_ON_FORBIDDEN_TOKENS_AFTER_CALLS != 0) && (enabledTokensMask & forbiddenTokenMask != 0)) {
            revert ForbiddenTokensException(); // U:[FA-27]
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
                    (address token, bytes memory data) = abi.decode(mcall.callData[4:], (address, bytes)); // U:[FA-25]

                    priceOracle = _getPriceOracle(priceOracle); // U:[FA-25]
                    address priceFeed = IPriceOracleBase(priceOracle).priceFeeds(token); // U:[FA-25]
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
    ///      - no forbidden tokens have been enabled during the multicall
    ///      - no enabled forbidden token balance has increased during the multicall
    function _fullCollateralCheck(
        address creditAccount,
        uint256 enabledTokensMaskBefore,
        FullCheckParams memory fullCheckParams,
        BalanceWithMask[] memory forbiddenBalances,
        uint256 _forbiddenTokenMask
    ) internal {
        uint256 enabledTokensMaskUpdated = ICreditManagerV3(creditManager).fullCollateralCheck(
            creditAccount,
            fullCheckParams.enabledTokensMaskAfter,
            fullCheckParams.collateralHints,
            fullCheckParams.minHealthFactor
        );

        bool success = BalancesLogic.checkForbiddenBalances({
            creditAccount: creditAccount,
            enabledTokensMaskBefore: enabledTokensMaskBefore,
            enabledTokensMaskAfter: enabledTokensMaskUpdated,
            forbiddenBalances: forbiddenBalances,
            forbiddenTokenMask: _forbiddenTokenMask
        });
        if (!success) revert ForbiddenTokensException(); // U:[FA-30]

        emit SetEnabledTokensMask(creditAccount, enabledTokensMaskUpdated);
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
            quotaChange: quotaChange,
            minQuota: minQuota,
            maxQuota: uint96(Math.min(type(uint96).max, maxQuotaMultiplier * debtLimits.maxDebt))
        }); // U:[FA-34]
    }

    /// @dev `ICreditFacadeV3Multicall.scheduleWithdrawal` implementation
    function _scheduleWithdrawal(address creditAccount, bytes calldata callData)
        internal
        returns (uint256 tokensToDisable)
    {
        (address token, uint256 amount) = abi.decode(callData, (address, uint256)); // U:[FA-35]

        tokensToDisable = ICreditManagerV3(creditManager).scheduleWithdrawal(creditAccount, token, amount); // U:[FA-35]
    }

    /// @dev `ICreditFacadeV3Multicall.revokeAdapterAllowances` implementation
    function _revokeAdapterAllowances(address creditAccount, bytes calldata callData) internal {
        RevocationPair[] memory revocations = abi.decode(callData, (RevocationPair[])); // U:[FA-36]

        ICreditManagerV3(creditManager).revokeAdapterAllowances(creditAccount, revocations); // U:[FA-36]
    }

    /// @dev `ICreditFacadeV3Multicall.payBot` implementation
    function _payBot(address creditAccount, bytes calldata callData) internal {
        uint72 paymentAmount = abi.decode(callData, (uint72));
        address payer = _getBorrowerOrRevert(creditAccount); // U:[FA-37]

        IBotListV3(botList).payBot({
            payer: payer,
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: msg.sender,
            paymentAmount: paymentAmount
        }); // U:[FA-37]
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

    /// @dev Returns inverted quoted tokens mask, avoids external call if it has already been queried
    function _getInvertedQuotedTokensMask(uint256 currentMask) internal view returns (uint256) {
        // since underlying token can't be quoted, we can use `currentMask == 0` as an indicator
        // that mask hasn't been queried yet
        return currentMask == 0 ? ~ICreditManagerV3(creditManager).quotedTokensMask() : currentMask;
    }

    /// @dev Returns price oracle address, avoids external call if it has already been queried
    function _getPriceOracle(address priceOracle) internal view returns (address) {
        return priceOracle == address(0) ? ICreditManagerV3(creditManager).priceOracle() : priceOracle;
    }

    /// @dev Wraps any ETH sent in the function call and sends it back to `msg.sender`
    function _wrapETH() internal {
        if (msg.value != 0) {
            IWETH(weth).deposit{value: msg.value}(); // U:[FA-7]
            IERC20(weth).safeTransfer(msg.sender, msg.value); // U:[FA-7]
        }
    }

    /// @dev Claims ETH from withdrawal manager, expecting that WETH was deposited there earlier in the transaction
    function _wethWithdrawTo(address to) internal {
        IWithdrawalManagerV3(withdrawalManager).claimImmediateWithdrawal({token: ETH_ADDRESS, to: to});
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

    /// @dev Internal wrapper for `creditManager.closeCreditAccount` call to reduce contract size
    function _closeCreditAccount(
        address creditAccount,
        ClosureAction closureAction,
        CollateralDebtData memory collateralDebtData,
        address payer,
        address to,
        uint256 skipTokensMask,
        bool convertToETH
    ) internal returns (uint256 remainingFunds, uint256 reportedLoss) {
        (remainingFunds, reportedLoss) = ICreditManagerV3(creditManager).closeCreditAccount({
            creditAccount: creditAccount,
            closureAction: closureAction,
            collateralDebtData: collateralDebtData,
            payer: payer,
            to: to,
            skipTokensMask: skipTokensMask,
            convertToETH: convertToETH
        });
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

    /// @dev Internal wrapper for `creditManager.calcDebtAndCollateral` call to reduce contract size
    function _calcDebtAndCollateral(address creditAccount, CollateralCalcTask task)
        internal
        view
        returns (CollateralDebtData memory)
    {
        return ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, task);
    }

    /// @dev Internal wrapper for `creditManager.claimWithdrawals` call to reduce contract size
    function _claimWithdrawals(address creditAccount, address to, ClaimAction action)
        internal
        returns (uint256 tokensToEnable)
    {
        tokensToEnable = ICreditManagerV3(creditManager).claimWithdrawals(creditAccount, to, action);
    }

    /// @dev Internal wrapper for `botList.eraseAllBotPermissions` call to reduce contract size
    function _eraseAllBotPermissions(address creditAccount) internal {
        uint16 flags = _flagsOf(creditAccount);
        if (flags & BOT_PERMISSIONS_SET_FLAG != 0) {
            IBotListV3(botList).eraseAllBotPermissions(creditManager, creditAccount);
        }
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
