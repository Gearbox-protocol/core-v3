// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../interfaces/IAddressProviderV3.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

// LIBS & TRAITS
import {BalancesLogic} from "../libraries/BalancesLogic.sol";
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {BitMask, UNDERLYING_TOKEN_MASK} from "../libraries/BitMask.sol";

//  DATA
import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {Balance} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";

/// INTERFACES
import "../interfaces/ICreditFacade.sol";
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
import {ClaimAction} from "../interfaces/IWithdrawalManager.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import {IPriceFeedOnDemand} from "../interfaces/IPriceFeedOnDemand.sol";

import {IPoolV3} from "../interfaces/IPoolV3.sol";
import {IDegenNFT} from "@gearbox-protocol/core-v2/contracts/interfaces/IDegenNFT.sol";
import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {IWETHGateway} from "../interfaces/IWETHGateway.sol";
import {IBotList} from "../interfaces/IBotList.sol";

// CONSTANTS
import {LEVERAGE_DECIMALS} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";
import "forge-std/console.sol";

uint256 constant OPEN_CREDIT_ACCOUNT_FLAGS = ALL_PERMISSIONS
    & ~(INCREASE_DEBT_PERMISSION | DECREASE_DEBT_PERMISSION | WITHDRAW_PERMISSION) | INCREASE_DEBT_WAS_CALLED;

uint256 constant CLOSE_CREDIT_ACCOUNT_FLAGS = EXTERNAL_CALLS_PERMISSION;

/// @title CreditFacadeV3
/// @notice A contract that provides a user interface for interacting with Credit Manager.
/// @dev CreditFacadeV3 provides an interface between the user and the Credit Manager. Direct interactions
/// with the Credit Manager are forbidden. Credit Facade provides access to all account management functions,
/// opening, closing, liquidating, managing debt, as well as calls to external protocols (through adapters, which
/// also can't be interacted with directly). All of these actions are only accessible through `multicall`.
contract CreditFacadeV3 is ICreditFacade, ACLNonReentrantTrait {
    using Address for address;
    using BitMask for uint256;

    /// @notice Credit Manager connected to this Credit Facade
    address public immutable creditManager;

    /// @notice Whether the Credit Facade implements expirable logic
    bool public immutable expirable;

    /// @notice Address of WETH
    address public immutable weth;

    /// @notice Address of WETH Gateway
    address public immutable wethGateway;

    /// @notice Address of the DegenNFT that gatekeeps account openings in whitelisted mode
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

    /// @notice Maps addresses to their status as emergency liquidator.
    /// @dev Emergency liquidators are trusted addresses
    /// that are able to liquidate positions while the contracts are paused,
    /// e.g. when there is a risk of bad debt while an exploit is being patched.
    /// In the interest of fairness, emergency liquidators do not receive a premium
    /// And are compensated by the Gearbox DAO separately.
    mapping(address => bool) public override canLiquidateWhilePaused;

    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice Restricts functions to the connected Credit Configurator only
    modifier creditConfiguratorOnly() {
        _checkCreditConfigurator();
        _;
    }

    /// @notice Private function for `creditConfiguratorOnly`; used for contract size optimization
    function _checkCreditConfigurator() private view {
        if (msg.sender != ICreditManagerV3(creditManager).creditConfigurator()) {
            revert CallerNotConfiguratorException();
        }
    }

    /// @notice Restricts functions to the owner of a Credit Account
    modifier creditAccountOwnerOnly(address creditAccount) {
        _checkCreditAccountOwner(creditAccount);
        _;
    }

    /// @notice Private function for `creditAccountOwnerOnly`; used for contract size optimization
    function _checkCreditAccountOwner(address creditAccount) private view {
        if (msg.sender != _getBorrowerOrRevert(creditAccount)) {
            revert CallerNotCreditAccountOwnerException();
        }
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

    /// @notice Reverts if the contract is expired
    function _checkExpired() private view {
        if (_isExpired()) {
            revert NotAllowedAfterExpirationException(); // F: [FA-46]
        }
    }

    /// @notice Wraps ETH and sends it back to msg.sender address
    modifier wrapETH() {
        _wrapETH();
        _;
    }

    /// @notice Initializes creditFacade and connects it to CreditManagerV3
    /// @param _creditManager address of Credit Manager
    /// @param _degenNFT address of the DegenNFT or address(0) if whitelisted mode is not used
    /// @param _expirable Whether the CreditFacadeV3 can expire and implements expiration-related logic
    constructor(address _creditManager, address _degenNFT, bool _expirable)
        ACLNonReentrantTrait(ICreditManagerV3(_creditManager).addressProvider())
    {
        creditManager = _creditManager; // U:[FA-1] // F:[FA-1A]

        weth = ICreditManagerV3(_creditManager).weth(); // U:[FA-1] // F:[FA-1A]
        wethGateway = ICreditManagerV3(_creditManager).wethGateway(); // U:[FA-1]
        botList =
            IAddressProviderV3(ICreditManagerV3(_creditManager).addressProvider()).getAddressOrRevert(AP_BOT_LIST, 3_00);

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
    /// - Burns DegenNFT (in whitelisted mode)
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
        _revertIfOutOfBorrowingLimit(debt); // U:[FA-8]

        /// Attempts to burn the DegenNFT - if onBehalfOf has none, this will fail
        if (degenNFT != address(0)) {
            if (msg.sender != onBehalfOf) revert ForbiddenInWhitelistedModeException(); // U:[FA-9]
            IDegenNFT(degenNFT).burn(onBehalfOf, 1); // U:[FA-9]
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
        uint256[] memory forbiddenBalances;

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

        // Emits an event
        emit CloseCreditAccount(creditAccount, msg.sender, to); // U:[FA-11]
    }

    /// @notice Runs a batch of transactions within a multicall and liquidates the account
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

        if (calls.length != 0) {
            FullCheckParams memory fullCheckParams =
                _multicall(creditAccount, calls, collateralDebtData.enabledTokensMask, CLOSE_CREDIT_ACCOUNT_FLAGS);
            collateralDebtData.enabledTokensMask = fullCheckParams.enabledTokensMaskAfter;
        }

        /// Bot permissions are specific to (owner, creditAccount),
        /// so they need to be erased on account closure
        _eraseAllBotPermissionsAtClosure({creditAccount: creditAccount});

        (uint256 remainingFunds, uint256 reportedLoss) = _closeCreditAccount({
            creditAccount: creditAccount,
            closureAction: closeAction,
            collateralDebtData: collateralDebtData,
            payer: msg.sender,
            to: to,
            skipTokensMask: skipTokenMask,
            convertToETH: convertToETH
        });

        /// If there is non-zero loss, then borrowing is forbidden in
        /// case this is an attack and there is risk of copycats afterwards
        /// If cumulative loss exceeds maxCumulativeLoss, the CF is paused,
        /// which ensures that the attacker can create at most maxCumulativeLoss + maxBorrowedAmount of bad debt
        if (reportedLoss > 0) {
            maxDebtPerBlockMultiplier = 0; // F: [FA-15A]

            /// reportedLoss is always less than uint128, because
            /// maxLoss = maxBorrowAmount which is uint128
            lossParams.currentCumulativeLoss += uint128(reportedLoss);
            if (lossParams.currentCumulativeLoss > lossParams.maxCumulativeLoss) {
                _pause(); // F: [FA-15B]
            }
        }

        if (convertToETH) {
            _wethWithdrawTo(to);
        }

        emit LiquidateCreditAccount(creditAccount, borrower, msg.sender, to, closeAction, remainingFunds);
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
        _multicallFullCollateralCheck(creditAccount, calls, ALL_PERMISSIONS);
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
        (uint256 botPermissions, bool forbidden) = IBotList(botList).getBotStatus(creditAccount, msg.sender);
        // Checks that the bot is approved by the borrower and is not forbidden
        if (botPermissions == 0 || forbidden) {
            revert NotApprovedBotException(); // F: [FA-58]
        }

        _multicallFullCollateralCheck(creditAccount, calls, botPermissions | PAY_BOT_PERMISSION);
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
        uint256 enabledTokensMaskBefore = ICreditManagerV3(creditManager).enabledTokensMaskOf(creditAccount);
        uint256[] memory forbiddenBalances = BalancesLogic.storeForbiddenBalances({
            creditAccount: creditAccount,
            forbiddenTokenMask: _forbiddenTokenMask,
            enabledTokensMask: enabledTokensMaskBefore,
            getTokenByMaskFn: _getTokenByMask
        });

        FullCheckParams memory fullCheckParams = _multicall(creditAccount, calls, enabledTokensMaskBefore, permissions);

        // Performs one fullCollateralCheck at the end of a multicall
        _fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMaskBefore: enabledTokensMaskBefore,
            fullCheckParams: fullCheckParams,
            forbiddenBalances: forbiddenBalances,
            _forbiddenTokenMask: _forbiddenTokenMask
        });
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
            supportsQuotas ? type(uint256).max : ~ICreditManagerV3(creditManager).quotedTokensMask();

        // Emits event for multicall start - used in analytics to track actions within multicalls
        emit StartMultiCall(creditAccount); // F:[FA-26]

        // Declares the expectedBalances array, which can later be used for slippage control
        Balance[] memory expectedBalances;

        // Minimal HF is set to PERCENTAGE_FACTOR by default
        fullCheckParams.minHealthFactor = PERCENTAGE_FACTOR;

        uint256 len = calls.length; // F:[FA-26]

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                MultiCall calldata mcall = calls[i]; // F:[FA-26]
                //
                // CREDIT FACADE
                //
                if (mcall.target == address(this)) {
                    // Reverts of calldata has less than 4 bytes
                    if (mcall.callData.length < 4) revert IncorrectCallDataException(); // F:[FA-22]

                    bytes4 method = bytes4(mcall.callData);

                    //
                    // REVERT IF RECEIVED LESS THAN
                    //
                    /// Method allows the user to enable slippage control, verifying that
                    /// the multicall has produced expected minimal token balances
                    /// Used as protection against sandwiching and untrusted path providers
                    if (method == ICreditFacadeMulticall.revertIfReceivedLessThan.selector) {
                        // Method can only be called once since the provided Balance array
                        // contains deltas that are added to the current balances
                        // Calling this function again could potentially override old values
                        // and cause confusion, especially if called later in the MultiCall
                        if (expectedBalances.length != 0) {
                            revert ExpectedBalancesAlreadySetException();
                        } // F:[FA-45A]

                        // Sets expected balances to currentBalance + delta
                        Balance[] memory expected = abi.decode(mcall.callData[4:], (Balance[])); // F:[FA-45]
                        expectedBalances = BalancesLogic.storeBalances(creditAccount, expected); // F:[FA-45]
                    }
                    //
                    // SET FULL CHECK PARAMS
                    //
                    /// Sets the parameters to be used during the full collateral check.
                    /// Collateral hints can be used to check tokens in a particular order - this allows
                    /// to put the most valuable tokens first and save gas, as full collateral check eval
                    /// is lazy. minHealthFactor can be used to set a custom health factor threshold, which
                    /// is especially useful for bots.
                    else if (method == ICreditFacadeMulticall.setFullCheckParams.selector) {
                        (fullCheckParams.collateralHints, fullCheckParams.minHealthFactor) =
                            abi.decode(mcall.callData[4:], (uint256[], uint16));
                    }
                    //
                    // ON DEMAND PRICE UPDATE
                    //
                    /// Utility function that enables support for price feeds with on-demand
                    /// price updates. This helps support tokens where there is no traditional price feeds,
                    /// but there is attested off-chain price data.
                    else if (method == ICreditFacadeMulticall.onDemandPriceUpdate.selector) {
                        _onDemandPriceUpdate(mcall.callData[4:]);
                    }
                    //
                    // ADD COLLATERAL
                    //
                    /// Transfers new collateral from the caller to the Credit Account.
                    else if (method == ICreditFacadeMulticall.addCollateral.selector) {
                        _revertIfNoPermission(flags, ADD_COLLATERAL_PERMISSION);
                        enabledTokensMask = enabledTokensMask.enable({
                            bitsToEnable: _addCollateral(creditAccount, mcall.callData[4:]),
                            invertedSkipMask: quotedTokensMaskInverted
                        }); // F:[FA-26, 27]
                    }
                    //
                    // INCREASE DEBT
                    //
                    /// Increases the Credit Account's debt and sends the new borrowed funds
                    /// from the pool to the Credit Account. Changes some flags,
                    /// in order to enforce some restrictions after increasing debt,
                    /// such is decreaseDebt or having forbidden tokens being prohibited
                    else if (method == ICreditFacadeMulticall.increaseDebt.selector) {
                        _revertIfNoPermission(flags, INCREASE_DEBT_PERMISSION);

                        flags = flags.enable(INCREASE_DEBT_WAS_CALLED).disable(DECREASE_DEBT_PERMISSION); // F:[FA-28]

                        (uint256 tokensToEnable, uint256 tokensToDisable) = _manageDebt(
                            creditAccount, mcall.callData[4:], enabledTokensMask, ManageDebtAction.INCREASE_DEBT
                        ); // F:[FA-26]
                        enabledTokensMask = enabledTokensMask.enableDisable(tokensToEnable, tokensToDisable);
                    }
                    //
                    // DECREASE DEBT
                    //
                    /// Decreases the Credit Account's debt and sends the funds back to the pool
                    else if (method == ICreditFacadeMulticall.decreaseDebt.selector) {
                        // it's forbidden to call decreaseDebt after increaseDebt, in the same multicall
                        _revertIfNoPermission(flags, DECREASE_DEBT_PERMISSION);
                        // F:[FA-28]

                        (uint256 tokensToEnable, uint256 tokensToDisable) = _manageDebt(
                            creditAccount, mcall.callData[4:], enabledTokensMask, ManageDebtAction.DECREASE_DEBT
                        ); // F:[FA-27]
                        enabledTokensMask = enabledTokensMask.enableDisable(tokensToEnable, tokensToDisable);
                    }
                    //
                    // ENABLE TOKEN
                    //
                    /// Enables a token on a Credit Account, which includes it into collateral
                    /// computations
                    else if (method == ICreditFacadeMulticall.enableToken.selector) {
                        _revertIfNoPermission(flags, ENABLE_TOKEN_PERMISSION);
                        // Parses token
                        address token = abi.decode(mcall.callData[4:], (address)); // F: [FA-53]
                        enabledTokensMask = enabledTokensMask.enable({
                            bitsToEnable: _getTokenMaskOrRevert(token),
                            invertedSkipMask: quotedTokensMaskInverted
                        });
                    }
                    //
                    // DISABLE TOKEN
                    //
                    /// Disables a token on a Credit Account, which excludes it from collateral
                    /// computations
                    else if (method == ICreditFacadeMulticall.disableToken.selector) {
                        _revertIfNoPermission(flags, DISABLE_TOKEN_PERMISSION);
                        // Parses token
                        address token = abi.decode(mcall.callData[4:], (address)); // F: [FA-53]
                        /// IGNORE QUOTED TOKEN MASK
                        enabledTokensMask = enabledTokensMask.disable({
                            bitsToDisable: _getTokenMaskOrRevert(token),
                            invertedSkipMask: quotedTokensMaskInverted
                        });
                    }
                    //
                    // UPDATE QUOTA
                    //
                    /// Updates a quota on a token. Quota is an underlying-denominated value
                    /// that imposes a limit on the exposure of borrowed funds to a certain asset.
                    /// Tokens with quota logic are only enabled and disabled on updating the quota
                    /// from zero to positive value and back, respectively.
                    else if (method == ICreditFacadeMulticall.updateQuota.selector) {
                        _revertIfNoPermission(flags, UPDATE_QUOTA_PERMISSION);
                        (uint256 tokensToEnable, uint256 tokensToDisable) =
                            _updateQuota(creditAccount, mcall.callData[4:]);
                        enabledTokensMask = enabledTokensMask.enableDisable(tokensToEnable, tokensToDisable);
                    }
                    //
                    // WITHDRAW
                    //
                    /// Schedules a delayed withdrawal of assets from a Credit Account.
                    /// This sends asset from the CA to the withdrawal manager and excludes them
                    /// from collateral computations (with some exceptions). After a delay,
                    /// the account owner can claim the withdrawal.
                    else if (method == ICreditFacadeMulticall.scheduleWithdrawal.selector) {
                        _revertIfNoPermission(flags, WITHDRAW_PERMISSION);
                        uint256 tokensToDisable = _scheduleWithdrawal(creditAccount, mcall.callData[4:]);
                        enabledTokensMask = enabledTokensMask.disable({
                            bitsToDisable: tokensToDisable,
                            invertedSkipMask: quotedTokensMaskInverted
                        });
                    }
                    //
                    // REVOKE ADAPTER ALLOWANCES
                    //
                    /// Sets allowance to the provided list of contracts to one. Can be used
                    /// to clean up leftover allowances from old contracts
                    else if (method == ICreditFacadeMulticall.revokeAdapterAllowances.selector) {
                        _revertIfNoPermission(flags, REVOKE_ALLOWANCES_PERMISSION);
                        _revokeAdapterAllowances(creditAccount, mcall.callData[4:]);
                    }
                    //
                    // PAY BOT
                    //
                    /// Requests the bot list to pay a bot. Used by bots to receive payment for their services.
                    /// Only available in `botMulticall` and can only be called once
                    else if (method == ICreditFacadeMulticall.payBot.selector) {
                        _revertIfNoPermission(flags, PAY_BOT_PERMISSION);
                        flags = flags.disable(PAY_BOT_PERMISSION);
                        _payBot(creditAccount, mcall.callData[4:]);
                    }
                    //
                    // UNKNOWN METHOD
                    //
                    else {
                        revert UnknownMethodException(); // F:[FA-23]
                    }
                } else {
                    //
                    // ADAPTERS
                    //
                    _revertIfNoPermission(flags, EXTERNAL_CALLS_PERMISSION);

                    // Checks that the target is an allowed adapter in Credit Manager
                    if (ICreditManagerV3(creditManager).adapterToContract(mcall.target) == address(0)) {
                        revert TargetContractNotAllowedException();
                    } // F:[FA-24]

                    /// The `externalCallCreditAccount` value in CreditManager is set to the currently processed
                    /// Credit Account. This value is used by adapters to retrieve the CA that is being worked on
                    /// After the multicall, the value is set back to address(1)
                    if (flags & EXTERNAL_CONTRACT_WAS_CALLED == 0) {
                        flags = flags.enable(EXTERNAL_CONTRACT_WAS_CALLED);
                        _setActiveCreditAccount(creditAccount);
                    }

                    /// Performs an adapter call. Each external adapter function returns
                    /// the masks of tokens to enable and disable, which are applied to the mask
                    /// on the stack; the net change in the enabled token set is saved to storage
                    /// only in fullCollateralCheck at the end of the multicall
                    bytes memory result = mcall.target.functionCall(mcall.callData); // F:[FA-29]
                    (uint256 tokensToEnable, uint256 tokensToDisable) = abi.decode(result, (uint256, uint256));
                    enabledTokensMask = enabledTokensMask.enableDisable({
                        bitsToEnable: tokensToEnable,
                        bitsToDisable: tokensToDisable,
                        invertedSkipMask: quotedTokensMaskInverted
                    });
                }
            }
        }

        // If expectedBalances was set by calling revertIfGetLessThan,
        // checks that actual token balances are not less than expected balances
        if (expectedBalances.length != 0) {
            BalancesLogic.compareBalances(creditAccount, expectedBalances);
        }

        /// If increaseDebt was called during the multicall, all forbidden tokens must be disabled at the end
        /// otherwise, funds could be borrowed against forbidden token, which is prohibited
        if ((flags & INCREASE_DEBT_WAS_CALLED != 0) && (enabledTokensMask & forbiddenTokenMask != 0)) {
            revert ForbiddenTokensException();
        }

        /// If the `externalCallCreditAccount` value was set to the current CA, it must be reset
        if (flags & EXTERNAL_CONTRACT_WAS_CALLED != 0) {
            _unsetActiveCreditAccount();
        }

        /// Emits event for multicall end - used in analytics to track actions within multicalls
        emit FinishMultiCall(); // F:[FA-27,27,29]

        /// Saves the final enabledTokensMask to be later passed into the fullCollateralCheck,
        /// where it will be saved to storage
        fullCheckParams.enabledTokensMaskAfter = enabledTokensMask;
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
            revert NoPermissionException(permission);
        }
    }

    /// @notice Requests an on-demand price update from a price feed
    ///      The price update accepts a generic data blob that is processed
    ///      on the price feed side.
    /// @dev Should generally be called only when interacting with tokens
    ///         that use on-demand price feeds
    /// @param callData Bytes calldata for parsing
    function _onDemandPriceUpdate(bytes calldata callData) internal {
        (address token, bytes memory data) = abi.decode(callData, (address, bytes));

        address priceFeed = IPriceOracleV2(ICreditManagerV3(creditManager).priceOracle()).priceFeeds(token);
        if (priceFeed == address(0)) revert PriceFeedNotExistsException();

        IPriceFeedOnDemand(priceFeed).updatePrice(data);
    }

    /// @notice Requests Credit Manager to update a Credit Account's quota for a certain token
    /// @param creditAccount Credit Account to update the quota for
    /// @param callData Bytes calldata for parsing
    function _updateQuota(address creditAccount, bytes calldata callData)
        internal
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        (address token, int96 quotaChange) = abi.decode(callData, (address, int96));
        return ICreditManagerV3(creditManager).updateQuota(creditAccount, token, quotaChange);
    }

    /// @notice Requests Credit Manager to remove a set of existing allowances
    /// @param creditAccount Credit Account to revoke allowances for
    /// @param callData Bytes calldata for parsing
    function _revokeAdapterAllowances(address creditAccount, bytes calldata callData) internal {
        (RevocationPair[] memory revocations) = abi.decode(callData, (RevocationPair[]));
        ICreditManagerV3(creditManager).revokeAdapterAllowances(creditAccount, revocations);
    }

    /// @notice Requests the bot list to pay the bot for performed services
    /// @param creditAccount Credit account the service was performed for
    /// @param callData Bytes calldata for parsing
    function _payBot(address creditAccount, bytes calldata callData) internal {
        uint72 paymentAmount = abi.decode(callData, (uint72));

        /// The current owner of the account always pays for bot services
        address payer = _getBorrowerOrRevert(creditAccount);

        IBotList(botList).payBot(payer, creditAccount, msg.sender, paymentAmount);
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
        uint256 amount = abi.decode(callData, (uint256)); // F:[FA-26]

        if (action == ManageDebtAction.INCREASE_DEBT) {
            // Checks that the borrowed amount does not violate the per block limit
            // This also ensures that increaseDebt can't be called when borrowing is forbidden
            // (since the block limit will be 0)
            _revertIfOutOfBorrowingLimit(amount); // F:[FA-18A]
        }

        uint256 newDebt;
        // Requests the Credit Manager to borrow additional funds from the pool
        (newDebt, tokensToEnable, tokensToDisable) =
            ICreditManagerV3(creditManager).manageDebt(creditAccount, amount, enabledTokensMask, action); // F:[FA-17]

        // Checks that the new total borrowed amount is within bounds
        _revertIfOutOfDebtLimits(newDebt); // F:[FA-18B]

        // Emits event
        if (action == ManageDebtAction.INCREASE_DEBT) {
            emit IncreaseDebt(creditAccount, amount); // F:[FA-17]
        } else {
            emit DecreaseDebt(creditAccount, amount); // F:[FA-19]
        }
    }

    /// @notice Requests the Credit Manager to transfer collateral from the caller to the Credit Account
    /// @param creditAccount Credit Account to add collateral for
    /// @param callData Bytes calldata for parsing
    function _addCollateral(address creditAccount, bytes calldata callData) internal returns (uint256 tokenMaskAfter) {
        (address token, uint256 amount) = abi.decode(callData, (address, uint256)); // F:[FA-26, 27]
        // Requests Credit Manager to transfer collateral to the Credit Account
        tokenMaskAfter = ICreditManagerV3(creditManager).addCollateral(msg.sender, creditAccount, token, amount); // F:[FA-21]

        // Emits event
        emit AddCollateral(creditAccount, token, amount); // F:[FA-21]
    }

    /// @notice Requests the Credit Manager to schedule a withdrawal
    /// @param creditAccount Credit Account to schedule withdrawals for
    /// @param callData Bytes calldata for parsing
    function _scheduleWithdrawal(address creditAccount, bytes calldata callData)
        internal
        returns (uint256 tokensToDisable)
    {
        (address token, uint256 amount) = abi.decode(callData, (address, uint256));
        tokensToDisable = ICreditManagerV3(creditManager).scheduleWithdrawal(creditAccount, token, amount);
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
        _claimWithdrawals(creditAccount, to, ClaimAction.CLAIM);
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
            _eraseAllBotPermissions({creditAccount: creditAccount});

            // If flag wasn't enabled before and bot has some permissions, it sets flag
            if (permissions != 0) {
                _setFlagFor(creditAccount, BOT_PERMISSIONS_SET_FLAG, true);
            }
        }

        uint256 remainingBots =
            IBotList(botList).setBotPermissions(creditAccount, bot, permissions, fundingAmount, weeklyFundingAllowance);

        if (remainingBots == 0) {
            _setFlagFor(creditAccount, BOT_PERMISSIONS_SET_FLAG, false);
        }
    }

    /// @notice Convenience function to erase all bot permissions for a Credit Account upon closure
    function _eraseAllBotPermissionsAtClosure(address creditAccount) internal {
        uint16 flags = _flagsOf(creditAccount);

        if (flags & BOT_PERMISSIONS_SET_FLAG != 0) {
            _eraseAllBotPermissions(creditAccount);
        }
    }

    function _eraseAllBotPermissions(address creditAccount) internal {
        IBotList(botList).eraseAllBotPermissions(creditAccount);
    }

    function _flagsOf(address creditAccount) internal view returns (uint16) {
        return ICreditManagerV3(creditManager).flagsOf(creditAccount);
    }

    /// @notice Internal wrapper for `CreditManager.setFlagFor()`. The external call is wrapped
    ///      to optimize contract size
    function _setFlagFor(address creditAccount, uint16 flag, bool value) internal {
        ICreditManagerV3(creditManager).setFlagFor(creditAccount, flag, value);
    }

    /// @notice Checks that the per-block borrow limit was not violated and updates the
    /// amount borrowed in current block
    function _revertIfOutOfBorrowingLimit(uint256 amount) internal {
        uint8 _maxDebtPerBlockMultiplier = maxDebtPerBlockMultiplier; // F:[FA-18]\

        if (_maxDebtPerBlockMultiplier == 0) {
            revert BorrowedBlockLimitException();
        }

        if (_maxDebtPerBlockMultiplier == type(uint8).max) return;

        uint256 newDebtInCurrentBlock;

        if (lastBlockBorrowed == block.number) {
            newDebtInCurrentBlock = amount + totalBorrowedInBlock;
        } else {
            newDebtInCurrentBlock = amount;
            lastBlockBorrowed = uint64(block.number);
        }

        if (newDebtInCurrentBlock > uint256(_maxDebtPerBlockMultiplier) * debtLimits.maxDebt) {
            revert BorrowedBlockLimitException();
        } // F:[FA-18]

        totalBorrowedInBlock = uint128(newDebtInCurrentBlock);
    }

    /// @notice Checks that the borrowed principal is within borrowing debtLimits
    /// @param debt The current principal of a Credit Account
    function _revertIfOutOfDebtLimits(uint256 debt) internal view {
        // Checks that amount is in debtLimits
        if (debt < uint256(debtLimits.minDebt) || debt > uint256(debtLimits.maxDebt)) {
            revert BorrowAmountOutOfLimitsException();
        } // F:
    }

    //
    // HELPERS
    //

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

    /// @notice Internal wrapper for `creditManager.fullCollateralCheck()`
    /// @dev The external call is wrapped to optimize contract size
    function _fullCollateralCheck(
        address creditAccount,
        uint256 enabledTokensMaskBefore,
        FullCheckParams memory fullCheckParams,
        uint256[] memory forbiddenBalances,
        uint256 _forbiddenTokenMask
    ) internal {
        ICreditManagerV3(creditManager).fullCollateralCheck(
            creditAccount,
            fullCheckParams.enabledTokensMaskAfter,
            fullCheckParams.collateralHints,
            fullCheckParams.minHealthFactor
        );

        BalancesLogic.checkForbiddenBalances({
            creditAccount: creditAccount,
            enabledTokensMaskBefore: enabledTokensMaskBefore,
            enabledTokensMaskAfter: fullCheckParams.enabledTokensMaskAfter,
            forbiddenBalances: forbiddenBalances,
            forbiddenTokenMask: _forbiddenTokenMask,
            getTokenByMaskFn: _getTokenByMask
        });
    }

    /// @notice Returns whether the Credit Facade is expired
    function _isExpired() internal view returns (bool isExpired) {
        isExpired = (expirable) && (block.timestamp >= expirationDate); // F: [FA-46,47,48]
    }

    /// @notice Wraps ETH into WETH and sends it back to msg.sender
    /// TODO: Check L2 networks for supporting native currencies
    function _wrapETH() internal {
        if (msg.value > 0) {
            IWETH(weth).deposit{value: msg.value}(); // U:[FA-7]
            IWETH(weth).transfer(msg.sender, msg.value); // U:[FA-7]
        }
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
        tokensToEnable = ICreditManagerV3(creditManager).claimWithdrawals(creditAccount, to, action);
    }

    /// @notice Internal wrapper for `IWETHGateway.withdrawTo()`
    /// @dev The external call is wrapped to optimize contract size
    /// @dev Used to convert WETH to ETH and send it to user
    function _wethWithdrawTo(address to) internal {
        IWETHGateway(wethGateway).withdrawTo(to);
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
            revert NotAllowedWhenNotExpirableException();
        }
        expirationDate = newExpirationDate;
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
        debtLimits.minDebt = _minDebt; // F:
        debtLimits.maxDebt = _maxDebt; // F:
        maxDebtPerBlockMultiplier = _maxDebtPerBlockMultiplier;
    }

    /// @notice Sets the bot list for this Credit Facade
    ///      The bot list is used to determine whether an address has a right to
    ///      run multicalls for a borrower as a bot. The relationship is stored in a separate contract.
    function setBotList(address _botList)
        external
        creditConfiguratorOnly // U:[FA-6]
    {
        botList = _botList;
    }

    /// @notice Sets the max cumulative loss that can be accrued before pausing the Credit Manager
    /// @param _maxCumulativeLoss The threshold of cumulative loss that triggers a system pause
    /// @param resetCumulativeLoss Whether to reset the current cumulative loss
    function setCumulativeLossParams(uint128 _maxCumulativeLoss, bool resetCumulativeLoss)
        external
        creditConfiguratorOnly // U:[FA-6]
    {
        lossParams.maxCumulativeLoss = _maxCumulativeLoss;
        if (resetCumulativeLoss) {
            lossParams.currentCumulativeLoss = 0;
        }
    }

    /// @notice Changes the token's forbidden status
    /// @param token Address of the token to set status for
    /// @param allowance Status to set (ALLOW / FORBID)
    function setTokenAllowance(address token, AllowanceAction allowance)
        external
        creditConfiguratorOnly // U:[FA-6]
    {
        uint256 tokenMask = _getTokenMaskOrRevert(token);

        forbiddenTokenMask = (allowance == AllowanceAction.ALLOW)
            ? forbiddenTokenMask.disable(tokenMask)
            : forbiddenTokenMask.enable(tokenMask);
    }

    /// @notice Changes the status of an emergency liquidator
    /// @param liquidator Address to change status for
    /// @param allowanceAction Status to set (ALLOW / FORBID)
    function setEmergencyLiquidator(address liquidator, AllowanceAction allowanceAction)
        external
        creditConfiguratorOnly // U:[FA-6]
    {
        canLiquidateWhilePaused[liquidator] = allowanceAction == AllowanceAction.ALLOW;
    }
}
