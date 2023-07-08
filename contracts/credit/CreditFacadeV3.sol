// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// LIBS & TRAITS
import {BalancesLogic, Balance, BalanceWithMask} from "../libraries/BalancesLogic.sol";
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {BitMask, UNDERLYING_TOKEN_MASK} from "../libraries/BitMask.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

//  DATA

/// INTERFACES
import "../interfaces/ICreditFacadeV3.sol";
import "../interfaces/IAddressProviderV3.sol";
import {
    ICreditManagerV3,
    ClosureAction,
    ManageDebtAction,
    RevocationPair,
    CollateralDebtData,
    CollateralCalcTask,
    BOT_PERMISSIONS_SET_FLAG
} from "../interfaces/ICreditManagerV3.sol";
import {AllowanceAction} from "../interfaces/ICreditConfiguratorV3.sol";
import {ClaimAction, ETH_ADDRESS, IWithdrawalManagerV3} from "../interfaces/IWithdrawalManagerV3.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracleV2.sol";

import {IPoolV3, IPoolBase} from "../interfaces/IPoolV3.sol";
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

/// @title CreditFacadeV3
/// @notice A contract that provides a user interface for interacting with Credit Manager.
/// @dev CreditFacadeV3 provides an interface between the user and the Credit Manager. Direct interactions
/// with the Credit Manager are forbidden. Credit Facade provides access to all account management functions,
/// opening, closing, liquidating, managing debt, as well as calls to external protocols (through adapters, which
/// also can't be interacted with directly). All of these actions are only accessible through `multicall`.
contract CreditFacadeV3 is ICreditFacadeV3, ACLNonReentrantTrait {
    using Address for address;
    using BitMask for uint256;
    using SafeCast for uint256;

    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice maxDebt to maxQuota multiplier
    uint256 public constant maxQuotaMultiplier = 8;

    /// @notice Credit Manager connected to this Credit Facade
    address public immutable creditManager;

    /// @notice Whether the Credit Facade implements expirable logic
    bool public immutable expirable;

    /// @notice Whether to track total debt on Credit Facade
    /// @dev Only true for older pool versions that do not track total debt themselves
    bool public immutable trackTotalDebt;

    /// @notice Address of WETH
    address public immutable weth;

    /// @notice Address of withdrawal manager contract
    address public immutable withdrawalManager;

    /// @notice Address of the IDegenNFTV2 that gatekeeps account openings in whitelisted mode
    address public immutable override degenNFT;

    bool immutable supportsQuotas;

    /// @notice Date of the next Credit Account expiration (for CF's with expirable logic)
    uint40 public expirationDate;

    /// @notice Maximal amount of new debt that can be taken per block
    uint8 public override maxDebtPerBlockMultiplier;

    /// @notice Last block in which debt was increased on a Credit Account
    uint64 internal lastBlockBorrowed;

    /// @notice The total amount of new debt in the last block where debt was increased
    uint128 internal totalBorrowedInBlock;

    /// @notice Contract containing permissions from borrowers to bots
    address public botList;

    /// @notice Limits on debt principal for a single Credit Account
    DebtLimits public debtLimits;

    /// @notice Bit mask encoding a set of forbidden tokens
    uint256 public forbiddenTokenMask;

    /// @notice Keeps parameters that are used to pause the system after too much bad debt over a short period
    CumulativeLossParams public override lossParams;

    /// @notice Keeps the current total debt and the total debt cap
    /// @dev Only used with pools that do not track total debt of the CM themselves
    TotalDebt public override totalDebt;

    /// @notice Maps addresses to their status as emergency liquidator.
    /// @dev Emergency liquidators are trusted addresses
    /// that are able to liquidate positions while the contracts are paused,
    /// e.g. when there is a risk of bad debt while an exploit is being patched.
    /// In the interest of fairness, emergency liquidators do not receive a premium
    /// And are compensated by the Gearbox DAO separately.
    mapping(address => bool) public override canLiquidateWhilePaused;

    /// @notice Restricts functions to the connected Credit Configurator only
    modifier creditConfiguratorOnly() {
        _checkCreditConfigurator();
        _;
    }

    /// @notice Restricts functions to the owner of a Credit Account
    modifier creditAccountOwnerOnly(address creditAccount) {
        _checkCreditAccountOwner(creditAccount);
        _;
    }

    /// @notice Restricts functions to the non-paused contract state, unless the caller
    ///      is an emergency liquidator
    modifier whenNotPausedOrEmergency() {
        require(!paused() || canLiquidateWhilePaused[msg.sender], "Pausable: paused");
        _;
    }

    /// @notice Restricts functions to when the CF is not expired
    modifier whenNotExpired() {
        _checkExpired();
        _;
    }

    /// @notice Wraps ETH and sends it back to msg.sender address
    modifier wrapETH() {
        _wrapETH();
        _;
    }

    /// @notice Private function for `creditConfiguratorOnly`; used for contract size optimization
    function _checkCreditConfigurator() private view {
        if (msg.sender != ICreditManagerV3(creditManager).creditConfigurator()) {
            revert CallerNotConfiguratorException();
        }
    }

    /// @notice Private function for `creditAccountOwnerOnly`; used for contract size optimization
    function _checkCreditAccountOwner(address creditAccount) private view {
        if (msg.sender != _getBorrowerOrRevert(creditAccount)) {
            revert CallerNotCreditAccountOwnerException();
        }
    }

    /// @notice Reverts if the contract is expired
    function _checkExpired() private view {
        if (_isExpired()) {
            revert NotAllowedAfterExpirationException(); // F: [FA-46]
        }
    }

    /// @notice Initializes creditFacade and connects it to CreditManagerV3
    /// @param _creditManager address of Credit Manager
    /// @param _degenNFT address of the IDegenNFTV2 or address(0) if whitelisted mode is not used
    /// @param _expirable Whether the CreditFacadeV3 can expire and implements expiration-related logic
    constructor(address _creditManager, address _degenNFT, bool _expirable)
        ACLNonReentrantTrait(ICreditManagerV3(_creditManager).addressProvider())
    {
        creditManager = _creditManager; // U:[FA-1] // F:[FA-1A]

        weth = ICreditManagerV3(_creditManager).weth(); // U:[FA-1] // F:[FA-1A]
        withdrawalManager = ICreditManagerV3(_creditManager).withdrawalManager(); // U:[FA-1]
        botList =
            IAddressProviderV3(ICreditManagerV3(_creditManager).addressProvider()).getAddressOrRevert(AP_BOT_LIST, 3_00);

        IPoolBase pool = IPoolBase(ICreditManagerV3(_creditManager).pool());

        trackTotalDebt = pool.version() < 3_00;

        degenNFT = _degenNFT; // U:[FA-1]  // F:[FA-1A]

        expirable = _expirable; // U:[FA-1] // F:[FA-1A]

        supportsQuotas = ICreditManagerV3(_creditManager).supportsQuotas();
    }

    // Notice: ETH interactions
    // CreditFacadeV3 implements the following flow for accepting native ETH:
    // During all actions, any sent ETH value is automatically wrapped into WETH and
    // sent back to the message sender. This makes the protocol's behavior regarding
    // ETH more flexible and consistent, since there is no need to pre-wrap WETH before
    // interacting with the protocol, and no need to compute how much unused ETH has to be sent back.

    /// @notice Opens a Credit Account and runs a batch of operations in a multicall
    /// - Performs sanity checks
    /// - Burns IDegenNFTV2 (in whitelisted mode)
    /// - Opens credit account with the desired debt amount
    /// - Executes all operations in a multicall
    /// - Checks that the new account has enough collateral
    /// - Emits OpenCreditAccount event
    ///
    /// @param debt Debt size
    /// @param onBehalfOf The address to open an account for
    /// @param calls The array of MultiCall structs encoding the required operations. Generally must have
    /// at least a call to addCollateral, as otherwise the health check at the end will fail.
    /// @param referralCode Referral code that is used for potential rewards. 0 if no referral code provided
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
        // Checks that the borrowed amount is within the debt limits
        _revertIfOutOfDebtLimits(debt); // U:[FA-8]

        // Checks whether the new borrowed amount does not violate the block limit
        _revertIfOutOfBorrowingLimit(debt); // F:[FA-11]

        // Checks whether the total debt amount does not exceed the limit and updates
        // the current total debt amount
        // Only in `trackTotalDebt` mode
        if (trackTotalDebt) {
            _revertIfOutOfTotalDebtLimit(debt, ManageDebtAction.INCREASE_DEBT); // U:[FA-8,10]
        }

        /// Attempts to burn the IDegenNFTV2 - if onBehalfOf has none, this will fail
        if (degenNFT != address(0)) {
            if (msg.sender != onBehalfOf) revert ForbiddenInWhitelistedModeException(); // U:[FA-9]
            IDegenNFTV2(degenNFT).burn(onBehalfOf, 1); // U:[FA-9]
        }

        // Requests the Credit Manager to open a Credit Account
        creditAccount = ICreditManagerV3(creditManager).openCreditAccount({debt: debt, onBehalfOf: onBehalfOf}); // U:[FA-10]

        // Emits an event for Credit Account opening
        emit OpenCreditAccount(creditAccount, onBehalfOf, msg.sender, debt, referralCode); // U:[FA-10]

        // Initially, only the underlying is on the Credit Account,
        // so the enabledTokenMask before the multicall is 1
        // Also, changing debt is prohibited during account opening,
        // to prevent any free flash loans
        FullCheckParams memory fullCheckParams = _multicall({
            creditAccount: creditAccount,
            calls: calls,
            enabledTokensMask: UNDERLYING_TOKEN_MASK,
            flags: OPEN_CREDIT_ACCOUNT_FLAGS
        }); // U:[FA-10]

        // Since it's not possible to enable any forbidden tokens on a new account,
        // this array is empty
        BalanceWithMask[] memory forbiddenBalances;

        // Checks that the new credit account has enough collateral to cover the debt
        _fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMaskBefore: UNDERLYING_TOKEN_MASK,
            fullCheckParams: fullCheckParams,
            forbiddenBalances: forbiddenBalances,
            _forbiddenTokenMask: forbiddenTokenMask
        }); // U:[FA-10]
    }

    /// @notice Runs a batch of transactions within a multicall and closes the account
    /// - Retrieves all debt data from the Credit Manager, such as debt and accrued interest and fees
    /// - Forces all pending withdrawals, even if they are not mature yet: successful account closure means
    ///   that there was enough collateral on the account to fully repay all debt - so this action is safe
    /// - Executes the multicall - the main purpose of a multicall when closing is to convert assets to underlying
    ///   in order to pay the debt.
    /// - Erases all bot permissions from an account, to protect future users from potentially unwanted bot permissions
    /// - Closes credit account:
    ///    + Checks the underlying balance: if it is greater than the amount paid to the pool, transfers the underlying
    ///      from the Credit Account and proceeds. If not, tries to transfer the shortfall from msg.sender;
    ///    + If active quotas are present, they are all set to zero;
    ///    + Transfers all enabled assets with non-zero balances to the "to" address, unless they are marked
    ///      to be skipped in skipTokenMask
    ///    + If convertToETH is true, converts WETH into ETH before sending to the recipient
    ///    + Returns the Credit Account to the factory
    /// - Emits a CloseCreditAccount event
    ///
    /// @param creditAccount Address of the Credit Account to liquidate. This is required, as V3 allows a borrower to
    ///                      have several CAs with one Credit Manager
    /// @param to Address to send funds to during account closing
    /// @param skipTokenMask Uint-encoded bit mask where 1's mark tokens that shouldn't be transferred
    /// @param convertToETH If true, converts WETH into ETH before sending to "to"
    /// @param calls The array of MultiCall structs encoding the operations to execute before closing the account.
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
        /// Requests CM to calculate debt only, since we don't need to know the collateral value for
        /// full account closure
        CollateralDebtData memory debtData = _calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY); // U:[FA-11]

        /// All pending withdrawals are claimed, even if they are not yet mature
        _claimWithdrawals(creditAccount, to, ClaimAction.FORCE_CLAIM); // U:[FA-11]

        if (calls.length != 0) {
            /// All account management functions are forbidden during closure
            FullCheckParams memory fullCheckParams =
                _multicall(creditAccount, calls, debtData.enabledTokensMask, CLOSE_CREDIT_ACCOUNT_FLAGS); // U:[FA-11]
            debtData.enabledTokensMask = fullCheckParams.enabledTokensMaskAfter; // U:[FA-11]
        }

        /// Bot permissions are specific to (owner, creditAccount),
        /// so they need to be erased on account closure
        _eraseAllBotPermissionsAtClosure({creditAccount: creditAccount}); // U:[FA-11]

        // Requests the Credit manager to close the Credit Account
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

        // Updates the current total debt amount
        // Only in `trackTotalDebt` mode
        if (trackTotalDebt) {
            _revertIfOutOfTotalDebtLimit(debtData.debt, ManageDebtAction.DECREASE_DEBT); // U:[FA-11]
        }

        // Emits an event
        emit CloseCreditAccount(creditAccount, msg.sender, to); // U:[FA-11]
    }

    /// @notice Runs a batch of transactions within a multicall and liquidates the account
    /// - Applies on-demand price feed updates if any are found in the multicall.
    /// - Computes the total value and checks that hf < 1. An account can't be liquidated when hf >= 1.
    ///   Total value has to be computed before the multicall, otherwise the liquidator would be able
    ///   to manipulate it. Withdrawals are included into the total value according to the following logic
    ///    + If the liquidation is normal, then only non-mature withdrawals are included. This means
    ///      that if the CA has enough collateral INCLUDING immature withdrawals, then it is considered healthy.
    ///    + If the liquidation is emergency, then ALL withdrawals are included. If an attack attempt was performed and
    ///      the attacker scheduled a malicious withdrawal, this ensures that the funds can be recovered (by force cancelling the withdrawal)
    ///      even if this withdrawal matures while a response is being coordinated.
    /// - Cancels or claims withdrawals based on liquidation type:
    ///    + If this is a normal liquidation, then mature pending withdrawals are claimed and immature ones are cancelled and returned to the Credit Account
    ///    + If this is an emergency liquidation, all pending withdrawals (regardless of maturity) are returned to the CA
    /// - Executes the multicall - the main purpose of a multicall when liquidating is to convert all assets to underlying
    ///   in order to pay the debt.
    /// - Erases all bot permissions from an account, to protect future users from potentially unwanted bot permissions
    /// - Liquidate credit account:
    ///    + Computes the amount that needs to be paid to the pool. If totalValue * liquidationDiscount < borrow + interest + fees,
    ///      only totalValue * liquidationDiscount has to be paid. Since liquidationDiscount < 1, the liquidator can take
    ///      totalValue * (1 - liquidationDiscount) as premium. Also computes the remaining funds to be sent to borrower
    ///      as totalValue * liquidationDiscount - amountToPool.
    ///    + Checks the underlying balance: if it is greater than amountToPool + remainingFunds, transfers the underlying
    ///      from the Credit Account and proceeds. If not, tries to transfer the shortfall from the liquidator.
    ///    + Transfers all enabled assets with non-zero balances to the "to" address, unless they are marked
    ///      to be skipped in skipTokenMask. If the liquidator is confident that all assets were converted
    ///      during the multicall, they can set the mask to uint256.max - 1, to only transfer the underlying
    ///    + If active quotas are present, they are all set to zero;
    ///    + If convertToETH is true, converts WETH into ETH before sending
    ///    + Returns the Credit Account to the factory
    /// - If liquidation reported a loss, borrowing is prohibited and the cumulative loss value is increase;
    ///   If cumulative loss reaches a critical threshold, the system is paused
    /// - Emits LiquidateCreditAccount event
    ///
    /// @param creditAccount Credit Account to liquidate
    /// @param to Address to send funds to after liquidation
    /// @param skipTokenMask Uint-encoded bit mask where 1's mark tokens that shouldn't be transferred
    /// @param convertToETH If true, converts WETH into ETH before sending to "to"
    /// @param calls The array of MultiCall structs encoding the operations to execute before liquidating the account.
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
        // Checks that the CA exists to revert early for late liquidations and save gas
        address borrower = _getBorrowerOrRevert(creditAccount); // F:[FA-5]

        // Price feed updates must be applied before the multicall because they affect CA's collateral evaluation
        uint256 remainingCalls = _applyOnDemandPriceUpdates(calls);

        // Checks that the account hf < 1 and computes the totalValue
        // before the multicall
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

        if (remainingCalls != 0) {
            FullCheckParams memory fullCheckParams = _multicall(
                creditAccount,
                calls,
                collateralDebtData.enabledTokensMask,
                CLOSE_CREDIT_ACCOUNT_FLAGS | PRICE_UPDATES_ALREADY_APPLIED
            ); // U:[FA-16]
            collateralDebtData.enabledTokensMask = fullCheckParams.enabledTokensMaskAfter; // U:[FA-16]
        }

        /// Bot permissions are specific to (owner, creditAccount),
        /// so they need to be erased on account closure
        _eraseAllBotPermissionsAtClosure({creditAccount: creditAccount}); // U:[FA-16]

        (uint256 remainingFunds, uint256 reportedLoss) = _closeCreditAccount({
            creditAccount: creditAccount,
            closureAction: closeAction,
            collateralDebtData: collateralDebtData,
            payer: msg.sender,
            to: to,
            skipTokensMask: skipTokenMask,
            convertToETH: convertToETH
        }); // U:[FA-16]

        // Updates the current total debt amount
        // Only in `trackTotalDebt` mode
        if (trackTotalDebt) {
            _revertIfOutOfTotalDebtLimit(collateralDebtData.debt, ManageDebtAction.DECREASE_DEBT); // U:[FA-16]
        }

        /// If there is non-zero loss, then borrowing is forbidden in
        /// case this is an attack and there is risk of copycats afterwards
        /// If cumulative loss exceeds maxCumulativeLoss, the CF is paused,
        /// which ensures that the attacker can create at most maxCumulativeLoss + maxDebt of bad debt
        if (reportedLoss > 0) {
            maxDebtPerBlockMultiplier = 0; // U:[FA-17]

            /// reportedLoss is always less than uint128, because
            /// maxLoss = maxBorrowAmount which is uint128
            lossParams.currentCumulativeLoss += uint128(reportedLoss); // U:[FA-17]
            if (lossParams.currentCumulativeLoss > lossParams.maxCumulativeLoss) {
                _pause(); // U:[FA-17]
            }
        }

        if (convertToETH) {
            _wethWithdrawTo(to); // U:[FA-16]
        }

        emit LiquidateCreditAccount(creditAccount, borrower, msg.sender, to, closeAction, remainingFunds); // U:[FA-14,16,17]
    }

    /// @notice Executes a batch of transactions within a Multicall, to manage an existing account
    ///  - Wraps ETH and sends it back to msg.sender, if value > 0
    ///  - Executes the Multicall
    ///  - Performs a fullCollateralCheck to verify that hf > 1 after all actions
    /// @param calls The array of MultiCall structs encoding the operations to execute.
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

    /// @notice Executes a batch of transactions within a Multicall from bot on behalf of a Credit Account's owner
    ///  - Retrieves bot permissions from botList and checks whether it is forbidden
    ///  - Executes the Multicall, with actions limited to `botPermissions`
    ///  - Performs a fullCollateralCheck to verify that hf > 1 after all actions
    /// @param creditAccount Address of credit account
    /// @param calls The array of MultiCall structs encoding the operations to execute.
    function botMulticall(address creditAccount, MultiCall[] calldata calls)
        external
        override
        whenNotPaused // U:[FA-2]
        whenNotExpired // U:[FA-3]
        nonReentrant // U:[FA-4]
    {
        uint16 flags = _flagsOf(creditAccount);

        (uint256 botPermissions, bool forbidden, bool hasSpecialPermissions) = IBotListV3(botList).getBotStatus({
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: msg.sender
        });

        // Checks that the bot is approved by the borrower (or has special permissions from DAO) and is not forbidden
        if ((!hasSpecialPermissions && (flags & BOT_PERMISSIONS_SET_FLAG == 0)) || botPermissions == 0 || forbidden) {
            revert NotApprovedBotException(); // U:[FA-19]
        }

        botPermissions |= hasSpecialPermissions ? 0 : PAY_BOT_CAN_BE_CALLED;

        _multicallFullCollateralCheck(creditAccount, calls, botPermissions); // U:[FA-19, 20]
    }

    /// @notice Convenience internal function that packages a multicall and a fullCheck together,
    ///      since they one is always performed after the other (except for account opening/closing)
    function _multicallFullCollateralCheck(address creditAccount, MultiCall[] calldata calls, uint256 permissions)
        internal
    {
        /// V3 checks forbidden tokens at the end of the multicall. Three conditions have to be fulfilled for
        /// a multicall to be successful:
        /// - No new forbidden tokens can be enabled during the multicall
        /// - Forbidden token balances cannot be increased during the multicall
        /// - Debt cannot be increased while forbidden tokens are enabled on an account
        /// This ensures that no pool funds can be used to increase exposure to forbidden tokens. To that end,
        /// before the multicall forbidden token balances are stored to compare with balances after
        uint256 _forbiddenTokenMask = forbiddenTokenMask;
        uint256 enabledTokensMaskBefore = ICreditManagerV3(creditManager).enabledTokensMaskOf(creditAccount); // U:[FA-18]

        BalanceWithMask[] memory forbiddenBalances = BalancesLogic.storeForbiddenBalances({
            creditAccount: creditAccount,
            forbiddenTokenMask: _forbiddenTokenMask,
            enabledTokensMask: enabledTokensMaskBefore,
            getTokenByMaskFn: _getTokenByMask
        });

        FullCheckParams memory fullCheckParams = _multicall(
            creditAccount,
            calls,
            enabledTokensMaskBefore,
            permissions | (forbiddenBalances.length > 0 ? FORBIDDEN_TOKENS_ON_ACCOUNT : 0)
        );

        // Performs one fullCollateralCheck at the end of a multicall
        _fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMaskBefore: enabledTokensMaskBefore,
            fullCheckParams: fullCheckParams,
            forbiddenBalances: forbiddenBalances,
            _forbiddenTokenMask: _forbiddenTokenMask
        }); // U:[FA-18]
    }

    /// @notice IMPLEMENTATION: multicall
    /// - Executes the provided list of calls:
    ///   + if targetContract == address(this), parses call data in the struct and calls the appropriate function
    ///   + if targetContract != address(this), checks that the address is an adapter and calls with calldata as provided.
    /// - For all calls, there are usually additional check and actions performed (see each action below for more details)
    /// @dev Unlike previous versions, in Gearbox V3 the mid-multicall enabledTokensMask is kept on the stack and updated based on values
    ///      returned from the Credit Manager and adapter functions. enabledTokensMask in storage is only updated once at the end of fullCollateralCheck.
    /// @param creditAccount Credit Account address
    /// @param calls List of calls to perform
    /// @param enabledTokensMask The mask of tokens enabled on the account before the multicall
    /// @param flags A bit mask of flags that encodes permissions, as well as other important information
    ///              that needs to persist throughout the multicall
    /// @return fullCheckParams Parameters passed to the full collateral check after the multicall
    ///                         - collateralHints: Array of token masks that determines the order in which tokens are checked, to optimize
    ///                                            gas in the fullCollateralCheck cycle
    ///                         - minHealthFactor: A custom minimal HF threshold. Cannot be lower than PERCENTAGE_FACTOR
    ///                         - enabledTokensMaskAfter: The mask of tokens enabled on the account after the multicall
    ///                                                   The enabledTokensMask value in Credit Manager storage is updated
    ///                                                   during the fullCollateralCheck
    function _multicall(address creditAccount, MultiCall[] calldata calls, uint256 enabledTokensMask, uint256 flags)
        internal
        returns (FullCheckParams memory fullCheckParams)
    {
        /// Inverted mask of quoted tokens is pre-compute to avoid
        /// enabling or disabling them outside `updateQuota`
        uint256 quotedTokensMaskInverted =
            supportsQuotas ? ~ICreditManagerV3(creditManager).quotedTokensMask() : type(uint256).max;

        // Emits event for multicall start - used in analytics to track actions within multicalls
        emit StartMultiCall({creditAccount: creditAccount, caller: msg.sender}); // U:[FA-18]

        // Declares the expectedBalances array, which can later be used for slippage control
        Balance[] memory expectedBalances;

        // Minimal HF is set to PERCENTAGE_FACTOR by default
        fullCheckParams.minHealthFactor = PERCENTAGE_FACTOR;

        uint256 len = calls.length;

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                MultiCall calldata mcall = calls[i];
                //
                // CREDIT FACADE
                //
                if (mcall.target == address(this)) {
                    bytes4 method = bytes4(mcall.callData);

                    //
                    // REVERT IF RECEIVED LESS THAN
                    //
                    /// Method allows the user to enable slippage control, verifying that
                    /// the multicall has produced expected minimal token balances
                    /// Used as protection against sandwiching and untrusted path providers
                    if (method == ICreditFacadeV3Multicall.revertIfReceivedLessThan.selector) {
                        // Method can only be called once since the provided Balance array
                        // contains deltas that are added to the current balances
                        // Calling this function again could potentially override old values
                        // and cause confusion, especially if called later in the MultiCall
                        if (expectedBalances.length != 0) {
                            revert ExpectedBalancesAlreadySetException(); // U:[FA-23]
                        }

                        // Sets expected balances to currentBalance + delta
                        Balance[] memory expected = abi.decode(mcall.callData[4:], (Balance[])); // U:[FA-23]
                        expectedBalances = BalancesLogic.storeBalances(creditAccount, expected); // U:[FA-23]
                    }
                    //
                    // ON DEMAND PRICE UPDATE
                    //
                    /// Utility function that enables support for price feeds with on-demand
                    /// price updates. This helps support tokens where there is no traditional price feeds,
                    /// but there is attested off-chain price data.
                    else if (method == ICreditFacadeV3Multicall.onDemandPriceUpdate.selector) {
                        if (flags & PRICE_UPDATES_ALREADY_APPLIED == 0) {
                            _onDemandPriceUpdate(mcall.callData[4:]); // U:[FA-25]
                        }
                    }
                    //
                    // ADD COLLATERAL
                    //
                    /// Transfers new collateral from the caller to the Credit Account.
                    else if (method == ICreditFacadeV3Multicall.addCollateral.selector) {
                        _revertIfNoPermission(flags, ADD_COLLATERAL_PERMISSION); // U:[FA-21]
                        enabledTokensMask = enabledTokensMask.enable({
                            bitsToEnable: _addCollateral(creditAccount, mcall.callData[4:]),
                            invertedSkipMask: quotedTokensMaskInverted
                        }); // U:[FA-26]
                    }
                    //
                    // UPDATE QUOTA
                    //
                    /// Updates a quota on a token. Quota is an underlying-denominated value
                    /// that imposes a limit on the exposure of borrowed funds to a certain asset.
                    /// Tokens with quota logic are only enabled and disabled on updating the quota
                    /// from zero to positive value and back, respectively.
                    else if (method == ICreditFacadeV3Multicall.updateQuota.selector) {
                        _revertIfNoPermission(flags, UPDATE_QUOTA_PERMISSION); // U:[FA-21]
                        (uint256 tokensToEnable, uint256 tokensToDisable) =
                            _updateQuota(creditAccount, mcall.callData[4:], flags & FORBIDDEN_TOKENS_ON_ACCOUNT > 0); // U:[FA-34]
                        enabledTokensMask = enabledTokensMask.enableDisable(tokensToEnable, tokensToDisable); // U:[FA-34]
                    }
                    //
                    // WITHDRAW
                    //
                    /// Schedules a delayed withdrawal of assets from a Credit Account.
                    /// This sends asset from the CA to the withdrawal manager and excludes them
                    /// from collateral computations (with some exceptions). After a delay,
                    /// the account owner can claim the withdrawal.
                    else if (method == ICreditFacadeV3Multicall.scheduleWithdrawal.selector) {
                        _revertIfNoPermission(flags, WITHDRAW_PERMISSION); // U:[FA-21]

                        flags = flags.enable(REVERT_ON_FORBIDDEN_TOKENS);

                        uint256 tokensToDisable = _scheduleWithdrawal(creditAccount, mcall.callData[4:]); // U:[FA-34]
                        enabledTokensMask = enabledTokensMask.disable({
                            bitsToDisable: tokensToDisable,
                            invertedSkipMask: quotedTokensMaskInverted
                        }); // U:[FA-35]
                    }
                    //
                    // INCREASE DEBT
                    //
                    /// Increases the Credit Account's debt and sends the new borrowed funds
                    /// from the pool to the Credit Account. Changes some flags,
                    /// in order to enforce some restrictions after increasing debt,
                    /// such is decreaseDebt or having forbidden tokens being prohibited
                    else if (method == ICreditFacadeV3Multicall.increaseDebt.selector) {
                        _revertIfNoPermission(flags, INCREASE_DEBT_PERMISSION); // U:[FA-21]

                        flags = flags.enable(REVERT_ON_FORBIDDEN_TOKENS).disable(DECREASE_DEBT_PERMISSION); // U:[FA-29]

                        (uint256 tokensToEnable,) = _manageDebt(
                            creditAccount, mcall.callData[4:], enabledTokensMask, ManageDebtAction.INCREASE_DEBT
                        ); // U:[FA-27]
                        enabledTokensMask = enabledTokensMask.enable(tokensToEnable); // U:[FA-27]
                    }
                    //
                    // DECREASE DEBT
                    //
                    /// Decreases the Credit Account's debt and sends the funds back to the pool
                    else if (method == ICreditFacadeV3Multicall.decreaseDebt.selector) {
                        // it's forbidden to call decreaseDebt after increaseDebt, in the same multicall
                        _revertIfNoPermission(flags, DECREASE_DEBT_PERMISSION); // U:[FA-21]

                        (, uint256 tokensToDisable) = _manageDebt(
                            creditAccount, mcall.callData[4:], enabledTokensMask, ManageDebtAction.DECREASE_DEBT
                        ); // U:[FA-31]
                        enabledTokensMask = enabledTokensMask.disable(tokensToDisable); // U:[FA-31]
                    }
                    //
                    // PAY BOT
                    //
                    /// Requests the bot list to pay a bot. Used by bots to receive payment for their services.
                    /// Only available in `botMulticall` and can only be called once
                    else if (method == ICreditFacadeV3Multicall.payBot.selector) {
                        _revertIfNoPermission(flags, PAY_BOT_CAN_BE_CALLED); // U:[FA-21]
                        flags = flags.disable(PAY_BOT_CAN_BE_CALLED); // U:[FA-37]
                        _payBot(creditAccount, mcall.callData[4:]); // U:[FA-37]
                    }
                    //
                    // SET FULL CHECK PARAMS
                    //
                    /// Sets the parameters to be used during the full collateral check.
                    /// Collateral hints can be used to check tokens in a particular order - this allows
                    /// to put the most valuable tokens first and save gas, as full collateral check eval
                    /// is lazy. minHealthFactor can be used to set a custom health factor threshold, which
                    /// is especially useful for bots.
                    else if (method == ICreditFacadeV3Multicall.setFullCheckParams.selector) {
                        (fullCheckParams.collateralHints, fullCheckParams.minHealthFactor) =
                            abi.decode(mcall.callData[4:], (uint256[], uint16)); // U:[FA-24]
                    }
                    //
                    // ENABLE TOKEN
                    //
                    /// Enables a token on a Credit Account, which includes it into collateral
                    /// computations
                    else if (method == ICreditFacadeV3Multicall.enableToken.selector) {
                        _revertIfNoPermission(flags, ENABLE_TOKEN_PERMISSION); // U:[FA-21]
                        // Parses token
                        address token = abi.decode(mcall.callData[4:], (address)); // U:[FA-33]
                        enabledTokensMask = enabledTokensMask.enable({
                            bitsToEnable: _getTokenMaskOrRevert(token),
                            invertedSkipMask: quotedTokensMaskInverted
                        }); // U:[FA-33]
                    }
                    //
                    // DISABLE TOKEN
                    //
                    /// Disables a token on a Credit Account, which excludes it from collateral
                    /// computations
                    else if (method == ICreditFacadeV3Multicall.disableToken.selector) {
                        _revertIfNoPermission(flags, DISABLE_TOKEN_PERMISSION); // U:[FA-21]
                        // Parses token
                        address token = abi.decode(mcall.callData[4:], (address)); // U:[FA-33]
                        /// IGNORE QUOTED TOKEN MASK
                        enabledTokensMask = enabledTokensMask.disable({
                            bitsToDisable: _getTokenMaskOrRevert(token),
                            invertedSkipMask: quotedTokensMaskInverted
                        }); // U:[FA-33]
                    }
                    //
                    // REVOKE ADAPTER ALLOWANCES
                    //
                    /// Sets allowance to the provided list of contracts to one. Can be used
                    /// to clean up leftover allowances from old contracts
                    else if (method == ICreditFacadeV3Multicall.revokeAdapterAllowances.selector) {
                        _revertIfNoPermission(flags, REVOKE_ALLOWANCES_PERMISSION); // U:[FA-21]
                        _revokeAdapterAllowances(creditAccount, mcall.callData[4:]); // U:[FA-36]
                    }
                    //
                    // UNKNOWN METHOD
                    //
                    else {
                        revert UnknownMethodException(); // U:[FA-22]
                    }
                } else {
                    //
                    // ADAPTERS
                    //
                    _revertIfNoPermission(flags, EXTERNAL_CALLS_PERMISSION);
                    // U:[FA-21]

                    address targetContract = ICreditManagerV3(creditManager).adapterToContract(mcall.target);

                    // Checks that the target is an allowed adapter in Credit Manager
                    if (targetContract == address(0)) {
                        revert TargetContractNotAllowedException();
                    }

                    /// The `externalCallCreditAccount` value in CreditManager is set to the currently processed
                    /// Credit Account. This value is used by adapters to retrieve the CA that is being worked on
                    /// After the multicall, the value is set back to address(1)
                    if (flags & EXTERNAL_CONTRACT_WAS_CALLED == 0) {
                        flags = flags.enable(EXTERNAL_CONTRACT_WAS_CALLED);
                        _setActiveCreditAccount(creditAccount); // U:[FA-38]
                    }

                    /// Performs an adapter call. Each external adapter function returns
                    /// the masks of tokens to enable and disable, which are applied to the mask
                    /// on the stack; the net change in the enabled token set is saved to storage
                    /// only in fullCollateralCheck at the end of the multicall
                    bytes memory result = mcall.target.functionCall(mcall.callData); // U:[FA-38]

                    // Emits an event
                    emit Execute({creditAccount: creditAccount, targetContract: targetContract});

                    (uint256 tokensToEnable, uint256 tokensToDisable) = abi.decode(result, (uint256, uint256)); // U:[FA-38]
                    enabledTokensMask = enabledTokensMask.enableDisable({
                        bitsToEnable: tokensToEnable,
                        bitsToDisable: tokensToDisable,
                        invertedSkipMask: quotedTokensMaskInverted
                    }); // U:[FA-38]
                }
            }
        }

        // If expectedBalances was set by calling revertIfGetLessThan,
        // checks that actual token balances are not less than expected balances
        if (expectedBalances.length != 0) {
            bool success = BalancesLogic.compareBalances(creditAccount, expectedBalances);
            if (!success) revert BalanceLessThanMinimumDesiredException(); // U:[FA-23]
        }

        /// If increaseDebt or scheduleWithdrawal was called during the multicall, all forbidden tokens must be disabled at the end
        /// Otherwise, funds could be borrowed / withdrawn against a forbidden token, which is prohibited
        if ((flags & REVERT_ON_FORBIDDEN_TOKENS != 0) && (enabledTokensMask & forbiddenTokenMask != 0)) {
            revert ForbiddenTokensException(); // U:[FA-27]
        }

        /// If the `externalCallCreditAccount` value was set to the current CA, it must be reset
        if (flags & EXTERNAL_CONTRACT_WAS_CALLED != 0) {
            _unsetActiveCreditAccount(); // U:[FA-38]
        }

        /// Emits event for multicall end - used in analytics to track actions within multicalls
        emit FinishMultiCall(); // U:[FA-18]

        /// Saves the final enabledTokensMask to be later passed into the fullCollateralCheck,
        /// where it will be saved to storage
        fullCheckParams.enabledTokensMaskAfter = enabledTokensMask; // U:[FA-38]
    }

    /// @dev Applies on-demand price feed updates from the multicall if the are any, returns number of calls remaining
    ///      `onDemandPriceUpdate` calls are expected to be placed before all other calls in the multicall
    function _applyOnDemandPriceUpdates(MultiCall[] calldata calls) internal returns (uint256 remainingCalls) {
        uint256 len = calls.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                MultiCall calldata mcall = calls[i];
                if (
                    mcall.target == address(this)
                        && bytes4(mcall.callData) == ICreditFacadeV3Multicall.onDemandPriceUpdate.selector
                ) {
                    _onDemandPriceUpdate(mcall.callData[4:]);
                } else {
                    return len - i;
                }
            }
            return 0;
        }
    }

    /// @notice Sets the `activeCreditAccount` in Credit Manager
    ///      to the passed Credit Account
    /// @param creditAccount CA address
    function _setActiveCreditAccount(address creditAccount) internal {
        ICreditManagerV3(creditManager).setActiveCreditAccount(creditAccount); // F:[FA-26]
    }

    /// @notice Sets the `externalCallCreditAccount` in Credit Manager
    ///      to the default value
    function _unsetActiveCreditAccount() internal {
        _setActiveCreditAccount(address(1)); // F:[FA-26]
    }

    /// @notice Reverts if provided flags contain no permission for the requested action
    /// @param flags A bitmask with flags for the multicall operation
    /// @param permission The flag of the permission to check
    function _revertIfNoPermission(uint256 flags, uint256 permission) internal pure {
        if (flags & permission == 0) {
            revert NoPermissionException(permission); // F:[FA-39]
        }
    }

    /// @notice Requests an on-demand price update from a price feed
    ///      The price update accepts a generic data blob that is processed
    ///      on the price feed side.
    /// @dev Should generally be called only when interacting with tokens
    ///         that use on-demand price feeds
    /// @param callData Bytes calldata for parsing
    function _onDemandPriceUpdate(bytes calldata callData) internal {
        (address token, bytes memory data) = abi.decode(callData, (address, bytes)); // U:[FA-25]

        address priceFeed = IPriceOracleV2(ICreditManagerV3(creditManager).priceOracle()).priceFeeds(token); // U:[FA-25]
        if (priceFeed == address(0)) revert PriceFeedDoesNotExistException(); // U:[FA-25]

        IUpdatablePriceFeed(priceFeed).updatePrice(data); // U:[FA-25]
    }

    /// @notice Requests the Credit Manager to transfer collateral from the caller to the Credit Account
    /// @param creditAccount Credit Account to add collateral for
    /// @param callData Bytes calldata for parsing
    function _addCollateral(address creditAccount, bytes calldata callData) internal returns (uint256 tokenMaskAfter) {
        (address token, uint256 amount) = abi.decode(callData, (address, uint256)); // U:[FA-26]
        // Requests Credit Manager to transfer collateral to the Credit Account

        tokenMaskAfter = ICreditManagerV3(creditManager).addCollateral({
            payer: msg.sender,
            creditAccount: creditAccount,
            token: token,
            amount: amount
        }); // U:[FA-26]

        // Emits event
        emit AddCollateral(creditAccount, token, amount); // U:[FA-26]
    }

    /// @notice Requests the Credit Manager to change the CA's debt
    /// @param creditAccount CA to change debt for
    /// @param callData Bytes calldata for parsing
    function _manageDebt(
        address creditAccount,
        bytes calldata callData,
        uint256 enabledTokensMask,
        ManageDebtAction action
    ) internal returns (uint256 tokensToEnable, uint256 tokensToDisable) {
        uint256 amount = abi.decode(callData, (uint256)); // U:[FA-27,31]

        if (action == ManageDebtAction.INCREASE_DEBT) {
            // Checks that the borrowed amount does not violate the per block limit
            // This also ensures that increaseDebt can't be called when borrowing is forbidden
            // (since the block limit will be 0)
            _revertIfOutOfBorrowingLimit(amount); // U:[FA-28]
        }

        // Checks whether the total debt amount does not exceed the limit and updates
        // the current total debt amount
        // Only in `trackTotalDebt` mode
        if (trackTotalDebt) {
            _revertIfOutOfTotalDebtLimit(amount, action); // U:[FA-27, 31]
        }

        uint256 newDebt;
        // Requests the Credit Manager to borrow additional funds from the pool
        (newDebt, tokensToEnable, tokensToDisable) =
            ICreditManagerV3(creditManager).manageDebt(creditAccount, amount, enabledTokensMask, action); // U:[FA-27,31]

        // Checks that the new total borrowed amount is within bounds
        _revertIfOutOfDebtLimits(newDebt); // U:[FA-28, 32]

        // Emits event
        if (action == ManageDebtAction.INCREASE_DEBT) {
            emit IncreaseDebt({creditAccount: creditAccount, amount: amount}); // U:[FA-27]
        } else {
            emit DecreaseDebt({creditAccount: creditAccount, amount: amount}); // U:[FA-31]
        }
    }

    /// @notice Requests Credit Manager to update a Credit Account's quota for a certain token
    /// @param creditAccount Credit Account to update the quota for
    /// @param callData Bytes calldata for parsing
    function _updateQuota(address creditAccount, bytes calldata callData, bool hasForbiddenTokens)
        internal
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        (address token, int96 quotaChange, uint96 minQuota) = abi.decode(callData, (address, int96, uint96)); // U:[FA-34]

        if (hasForbiddenTokens && quotaChange > 0) {
            uint256 mask = _getTokenMaskOrRevert(token);
            if (mask & forbiddenTokenMask > 0) revert ForbiddenTokensException();
        }

        (tokensToEnable, tokensToDisable) = ICreditManagerV3(creditManager).updateQuota({
            creditAccount: creditAccount,
            token: token,
            quotaChange: quotaChange,
            minQuota: minQuota,
            maxQuota: uint96(Math.min(type(uint96).max, maxQuotaMultiplier * debtLimits.maxDebt))
        }); // U:[FA-34]
    }

    /// @notice Requests the Credit Manager to schedule a withdrawal
    /// @param creditAccount Credit Account to schedule withdrawals for
    /// @param callData Bytes calldata for parsing
    function _scheduleWithdrawal(address creditAccount, bytes calldata callData)
        internal
        returns (uint256 tokensToDisable)
    {
        (address token, uint256 amount) = abi.decode(callData, (address, uint256)); // U:[FA-35]
        tokensToDisable = ICreditManagerV3(creditManager).scheduleWithdrawal(creditAccount, token, amount); // U:[FA-35]
    }

    /// @notice Requests Credit Manager to remove a set of existing allowances
    /// @param creditAccount Credit Account to revoke allowances for
    /// @param callData Bytes calldata for parsing
    function _revokeAdapterAllowances(address creditAccount, bytes calldata callData) internal {
        (RevocationPair[] memory revocations) = abi.decode(callData, (RevocationPair[])); // U:[FA-36]
        ICreditManagerV3(creditManager).revokeAdapterAllowances(creditAccount, revocations); // U:[FA-36]
    }

    /// @notice Requests the bot list to pay the bot for performed services
    /// @param creditAccount Credit account the service was performed for
    /// @param callData Bytes calldata for parsing
    function _payBot(address creditAccount, bytes calldata callData) internal {
        uint72 paymentAmount = abi.decode(callData, (uint72));

        /// The current owner of the account always pays for bot services
        address payer = _getBorrowerOrRevert(creditAccount); // U:[FA-37]

        IBotListV3(botList).payBot({
            payer: payer,
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: msg.sender,
            paymentAmount: paymentAmount
        }); // U:[FA-37]
    }

    /// @notice Claims all mature delayed withdrawals, transferring funds from
    ///      withdrawal manager to the address provided by the CA owner
    /// @param creditAccount CA to claim withdrawals for
    /// @param to Address to transfer the withdrawals to
    function claimWithdrawals(address creditAccount, address to)
        external
        override
        creditAccountOwnerOnly(creditAccount) // U:[FA-5]
        whenNotPaused // U:[FA-2]
        nonReentrant // U:[FA-4]
    {
        _claimWithdrawals(creditAccount, to, ClaimAction.CLAIM); // U:[FA-40]
    }

    /// @notice Sets permissions and funding parameters for a bot
    ///      Also manages BOT_PERMISSIONS_SET_FLAG, to allow
    ///      the contracts to determine whether a CA has permissions for any bot
    /// @param creditAccount CA to set permissions for
    /// @param bot Bot to set permissions for
    /// @param permissions A bit mask of permissions
    /// @param fundingAmount Total amount of ETH available to the bot for payments
    /// @param weeklyFundingAllowance Amount of ETH available to the bot weekly
    function setBotPermissions(
        address creditAccount,
        address bot,
        uint192 permissions,
        uint72 fundingAmount,
        uint72 weeklyFundingAllowance
    )
        external
        override
        creditAccountOwnerOnly(creditAccount) // U:[FA-5]
        nonReentrant // U:[FA-4]
    {
        uint16 flags = _flagsOf(creditAccount);

        if (flags & BOT_PERMISSIONS_SET_FLAG == 0) {
            _eraseAllBotPermissions({creditAccount: creditAccount}); // U:[FA-41]

            // If flag wasn't enabled before and bot has some permissions, it sets flag
            if (permissions != 0) {
                _setFlagFor({creditAccount: creditAccount, flag: BOT_PERMISSIONS_SET_FLAG, value: true}); // U:[FA-41]
            }
        }

        uint256 remainingBots = IBotListV3(botList).setBotPermissions({
            creditManager: creditManager,
            creditAccount: creditAccount,
            bot: bot,
            permissions: permissions,
            fundingAmount: fundingAmount,
            weeklyFundingAllowance: weeklyFundingAllowance
        }); // U:[FA-41]

        if (remainingBots == 0) {
            _setFlagFor({creditAccount: creditAccount, flag: BOT_PERMISSIONS_SET_FLAG, value: false}); // U:[FA-41]
        }
    }

    /// @notice Convenience function to erase all bot permissions for a Credit Account upon closure
    function _eraseAllBotPermissionsAtClosure(address creditAccount) internal {
        uint16 flags = _flagsOf(creditAccount); // U:[FA-42]

        if (flags & BOT_PERMISSIONS_SET_FLAG != 0) {
            _eraseAllBotPermissions(creditAccount); // U:[FA-42]
        }
    }

    //
    // CHECKS
    //

    /// @notice Checks that the per-block borrow limit was not violated and updates the
    /// amount borrowed in current block
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

        /// @dev It's safe covert because we control that
        /// uint256(_maxDebtPerBlockMultiplier) * debtLimits.maxDebt < type(uint128).max
        totalBorrowedInBlock = uint128(newDebtInCurrentBlock); // U:[FA-43]
    }

    /// @notice Checks that the borrowed principal is within borrowing debtLimits
    /// @param debt The current principal of a Credit Account
    function _revertIfOutOfDebtLimits(uint256 debt) internal view {
        // Checks that amount is in debtLimits
        uint256 minDebt;
        uint256 maxDebt;

        // minDebt = debtLimits.minDebt, maxDebt = debtLimits.maxDebt
        assembly {
            let data := sload(debtLimits.slot)
            maxDebt := shr(128, data)
            minDebt := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }

        if ((debt < minDebt) || (debt > maxDebt)) {
            revert BorrowAmountOutOfLimitsException(); // U:[FA-44]
        }
    }

    /// @notice Internal wrapper for `creditManager.fullCollateralCheck()`
    /// @dev The external call is wrapped to optimize contract size
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

    /// @notice Returns whether the Credit Facade is expired
    function _isExpired() internal view returns (bool isExpired) {
        isExpired = (expirable) && (block.timestamp >= expirationDate); // U:[FA-46]
    }

    /// @notice Updates total debt and checks that it does not exceed the limit
    function _revertIfOutOfTotalDebtLimit(uint256 delta, ManageDebtAction action) internal {
        if (delta != 0) {
            uint256 currentTotalDebt; // U:[FA-47]
            uint256 totalDebtLimit; // U:[FA-47]

            // currentTotalDebt = totalDebt.currentTotalDebt, totalDebtLimit = totalDebt.currentTotalDebt
            assembly {
                let data := sload(totalDebt.slot)
                totalDebtLimit := shr(128, data)
                currentTotalDebt := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            }

            if (action == ManageDebtAction.INCREASE_DEBT) {
                currentTotalDebt += delta; // U:[FA-47]
                if (currentTotalDebt > totalDebtLimit) {
                    revert CreditManagerCantBorrowException(); // U:[FA-47]
                }

                // it's safe, because currentTotalDebt <= totalDebtLimit which is uint128
                totalDebt.currentTotalDebt = uint128(currentTotalDebt); // U:[FA-47]
            } else {
                unchecked {
                    /// It's safe to downcast to uint128m because currentTotalDebt - delta < currentTotalDebt which is uint128
                    totalDebt.currentTotalDebt = currentTotalDebt > delta ? uint128(currentTotalDebt - delta) : 0; // U:[FA-47]
                }
            }
        }
    }

    //
    // HELPERS
    //

    /// @notice Wraps ETH into WETH and sends it back to msg.sender
    function _wrapETH() internal {
        if (msg.value != 0) {
            IWETH(weth).deposit{value: msg.value}(); // U:[FA-7]
            IWETH(weth).transfer(msg.sender, msg.value); // U:[FA-7]
        }
    }

    /// @notice Internal wrapper for `creditManager.getBorrowerOrRevert()`
    /// @dev The external call is wrapped to optimize contract size
    function _getBorrowerOrRevert(address creditAccount) internal view returns (address) {
        return ICreditManagerV3(creditManager).getBorrowerOrRevert({creditAccount: creditAccount});
    }

    /// @notice Internal wrapper for `creditManager.getTokenMaskOrRevert()`
    /// @dev The external call is wrapped to optimize contract size
    function _getTokenMaskOrRevert(address token) internal view returns (uint256 mask) {
        mask = ICreditManagerV3(creditManager).getTokenMaskOrRevert(token);
    }

    function _flagsOf(address creditAccount) internal view returns (uint16) {
        return ICreditManagerV3(creditManager).flagsOf(creditAccount);
    }

    /// @notice Internal wrapper for `CreditManager.setFlagFor()`. The external call is wrapped
    ///      to optimize contract size
    function _setFlagFor(address creditAccount, uint16 flag, bool value) internal {
        ICreditManagerV3(creditManager).setFlagFor(creditAccount, flag, value);
    }

    /// @notice Internal wrapper for `creditManager.closeCreditAccount()`
    /// @dev The external call is wrapped to optimize contract size
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
        }); // F:[FA-15,49]
    }

    /// @notice Internal wrapper for `creditManager.calcDebtAndCollateral()`
    /// @dev The external call is wrapped to optimize contract size
    function _calcDebtAndCollateral(address creditAccount, CollateralCalcTask task)
        internal
        view
        returns (CollateralDebtData memory)
    {
        return ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, task);
    }

    /// @notice Internal wrapper for `creditManager.getTokenByMask()`
    /// @dev The external call is wrapped to optimize contract size
    function _getTokenByMask(uint256 mask) internal view returns (address) {
        return ICreditManagerV3(creditManager).getTokenByMask(mask);
    }

    /// @notice Internal wrapper for `creditManager.claimWithdrawals()`
    /// @dev The external call is wrapped to optimize contract size
    function _claimWithdrawals(address creditAccount, address to, ClaimAction action)
        internal
        returns (uint256 tokensToEnable)
    {
        tokensToEnable = ICreditManagerV3(creditManager).claimWithdrawals(creditAccount, to, action); // U:[FA-16,37]
    }

    /// @dev Claims ETH from withdrawal manager, expecting that WETH was deposited there earlier in the transaction
    function _wethWithdrawTo(address to) internal {
        IWithdrawalManagerV3(withdrawalManager).claimImmediateWithdrawal({token: ETH_ADDRESS, to: to});
    }

    function _eraseAllBotPermissions(address creditAccount) internal {
        IBotListV3(botList).eraseAllBotPermissions(creditManager, creditAccount);
    }

    //
    // CONFIGURATION
    //

    /// @notice Sets Credit Facade expiration date
    /// @dev See more at https://dev.gearbox.fi/docs/documentation/credit/liquidation#liquidating-accounts-by-expiration
    function setExpirationDate(uint40 newExpirationDate)
        external
        creditConfiguratorOnly // U:[FA-6]
    {
        if (!expirable) {
            revert NotAllowedWhenNotExpirableException(); // U:[FA-48]
        }
        expirationDate = newExpirationDate; // U:[FA-48]
    }

    /// @notice Sets borrowing debtLimits per single Credit Account
    /// @param _minDebt The minimal borrowed amount per Credit Account. Minimal amount can be relevant
    /// for liquidations, since very small amounts will make liquidations unprofitable for liquidators
    /// @param _maxDebt The maximal borrowed amount per Credit Account. Used to limit exposure per a single
    /// credit account - especially relevant in whitelisted mode.
    function setDebtLimits(uint128 _minDebt, uint128 _maxDebt, uint8 _maxDebtPerBlockMultiplier)
        external
        creditConfiguratorOnly // U:[FA-6]
    {
        if ((uint256(_maxDebtPerBlockMultiplier) * _maxDebt) >= type(uint128).max) {
            revert IncorrectParameterException(); // U:[FA-49]
        }

        debtLimits.minDebt = _minDebt; // U:[FA-49]
        debtLimits.maxDebt = _maxDebt; // U:[FA-49]
        maxDebtPerBlockMultiplier = _maxDebtPerBlockMultiplier; // U:[FA-49]
    }

    /// @notice Sets the bot list for this Credit Facade
    ///      The bot list is used to determine whether an address has a right to
    ///      run multicalls for a borrower as a bot. The relationship is stored in a separate contract.
    function setBotList(address _botList)
        external
        creditConfiguratorOnly // U:[FA-6]
    {
        botList = _botList; // U:[FA-50]
    }

    /// @notice Sets the max cumulative loss that can be accrued before pausing the Credit Manager
    /// @param _maxCumulativeLoss The threshold of cumulative loss that triggers a system pause
    /// @param resetCumulativeLoss Whether to reset the current cumulative loss
    function setCumulativeLossParams(uint128 _maxCumulativeLoss, bool resetCumulativeLoss)
        external
        creditConfiguratorOnly // U:[FA-6]
    {
        lossParams.maxCumulativeLoss = _maxCumulativeLoss; // U:[FA-51]
        if (resetCumulativeLoss) {
            lossParams.currentCumulativeLoss = 0; // U:[FA-51]
        }
    }

    /// @notice Changes the token's forbidden status
    /// @param token Address of the token to set status for
    /// @param allowance Status to set (ALLOW / FORBID)
    function setTokenAllowance(address token, AllowanceAction allowance)
        external
        creditConfiguratorOnly // U:[FA-6]
    {
        uint256 tokenMask = _getTokenMaskOrRevert(token); // U:[FA-52]

        forbiddenTokenMask = (allowance == AllowanceAction.ALLOW)
            ? forbiddenTokenMask.disable(tokenMask)
            : forbiddenTokenMask.enable(tokenMask); // U:[FA-52]
    }

    /// @notice Changes the status of an emergency liquidator
    /// @param liquidator Address to change status for
    /// @param allowanceAction Status to set (ALLOW / FORBID)
    function setEmergencyLiquidator(address liquidator, AllowanceAction allowanceAction)
        external
        creditConfiguratorOnly // U:[FA-6]
    {
        canLiquidateWhilePaused[liquidator] = allowanceAction == AllowanceAction.ALLOW; // U:[FA-53]
    }

    /// @notice Sets the total debt limit and the current total debt value
    /// @dev The current total debt value is only changed during Credit Facade migration
    /// @param newCurrentTotalDebt The current total debt value (should differ from recorded value only on Credit Facade migration)
    /// @param newLimit The new value for total debt limit
    function setTotalDebtParams(uint128 newCurrentTotalDebt, uint128 newLimit) external creditConfiguratorOnly {
        totalDebt.currentTotalDebt = newCurrentTotalDebt;
        totalDebt.totalDebtLimit = newLimit;
    }
}
