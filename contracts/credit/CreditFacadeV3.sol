// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../interfaces/IAddressProviderV3.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

// LIBS & TRAITS
import {CreditLogic} from "../libraries/CreditLogic.sol";
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

import {IPool4626} from "../interfaces/IPool4626.sol";
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

struct DebtLimits {
    /// @dev Minimal borrowed amount per credit account
    uint128 minDebt;
    /// @dev Maximum aborrowed amount per credit account
    uint128 maxDebt;
}

struct CumulativeLossParams {
    /// @dev Current cumulative loss from all bad debt liquidations
    uint128 currentCumulativeLoss;
    /// @dev Max cumulative loss accrued before the system is paused
    uint128 maxCumulativeLoss;
}

/// @title CreditFacadeV3
/// @notice User interface for interacting with Credit Manager.
/// @dev CreditFacadeV3 provides an interface between the user and the Credit Manager. Direct interactions
/// with the Credit Manager are forbidden. There are two ways the Credit Manager can be interacted with:
/// - Through CreditFacadeV3, which provides all the required account management function: open / close / liquidate / manageDebt,
/// as well as Multicalls that allow to perform multiple actions within a single transaction, with a single health check
/// - Through adapters, which call the Credit Manager directly, but only allow interactions with specific target contracts
contract CreditFacadeV3 is ICreditFacade, ACLNonReentrantTrait {
    using Address for address;
    using BitMask for uint256;

    /// @dev Credit Manager connected to this Credit Facade
    address public immutable creditManager;

    /// @dev Whether the whitelisted mode is active
    bool public immutable whitelisted;

    /// @dev Whether the Credit Facade implements expirable logic
    bool public immutable expirable;

    /// @dev Address of the pool
    address public immutable pool;

    /// @dev Address of the underlying token
    address public immutable underlying;

    /// @dev Address of WETH
    address public immutable weth;

    /// @dev Address of WETH Gateway
    address public immutable wethGateway;

    /// @dev Address of the DegenNFT that gatekeeps account openings in whitelisted mode
    address public immutable override degenNFT;

    /// @dev Keeps borrowing debtLimits together for storage access optimization
    DebtLimits public debtLimits;

    /// @dev Maximal amount of new debt that can be taken per block
    uint8 public override maxDebtPerBlockMultiplier;

    /// @dev Stores in a compressed state the last block where borrowing happened and the total amount borrowed in that block
    uint128 internal totalBorrowedInBlock;

    uint64 internal lastBlockBorrowed;

    /// @dev Bit mask encoding a set of forbidden tokens
    uint256 public forbiddenTokenMask;

    /// @dev Keeps parameters that are used to pause the system after too much bad debt over a short period
    CumulativeLossParams public override lossParams;

    /// @dev Contract containing permissions from borrowers to bots
    address public botList;

    /// @dev
    uint40 public expirationDate;

    /// @dev A map that stores whether a user allows a transfer of an account from another user to themselves
    mapping(address => mapping(address => bool)) public override transfersAllowed;

    /// @dev Maps addresses to their status as emergency liquidator.
    /// @notice Emergency liquidators are trusted addresses
    /// that are able to liquidate positions while the contracts are paused,
    /// e.g. when there is a risk of bad debt while an exploit is being patched.
    /// In the interest of fairness, emergency liquidators do not receive a premium
    /// And are compensated by the Gearbox DAO separately.
    mapping(address => bool) public override canLiquidateWhilePaused;

    /// @dev Contract version
    uint256 public constant override version = 3_00;

    /// @dev Restricts actions for users with opened credit accounts only
    modifier creditConfiguratorOnly() {
        if (msg.sender != ICreditManagerV3(creditManager).creditConfigurator()) {
            revert CallerNotConfiguratorException();
        }

        _;
    }

    modifier creditAccountOwnerOnly(address creditAccount) {
        if (msg.sender != _getBorrowerOrRevert(creditAccount)) {
            revert CallerNotCreditAccountOwnerException();
        }
        _;
    }

    modifier nonZeroCallsOnly(MultiCall[] calldata calls) {
        if (calls.length == 0) {
            revert ZeroCallsException();
        }
        _;
    }

    modifier whenNotPausedOrEmergency() {
        require(!paused() || canLiquidateWhilePaused[msg.sender], "Pausable: paused");
        _;
    }

    // Reverts if CreditFacadeV3 is expired
    modifier whenNotExpired() {
        if (_isExpired()) {
            revert NotAllowedAfterExpirationException(); // F: [FA-46]
        }
        _;
    }

    /// @dev Initializes creditFacade and connects it with CreditManagerV3
    /// @param _creditManager address of Credit Manager
    /// @param _degenNFT address of the DegenNFT or address(0) if whitelisted mode is not used
    /// @param _expirable Whether the CreditFacadeV3 can expire and implements expiration-related logic
    constructor(address _creditManager, address _degenNFT, bool _expirable)
        ACLNonReentrantTrait(ICreditManagerV3(_creditManager).addressProvider())
        nonZeroAddress(_creditManager)
    {
        creditManager = _creditManager; // F:[FA-1A]
        pool = ICreditManagerV3(_creditManager).pool();
        underlying = ICreditManagerV3(_creditManager).underlying(); // F:[FA-1A]

        weth = ICreditManagerV3(_creditManager).weth(); // F:[FA-1A]
        wethGateway = ICreditManagerV3(_creditManager).wethGateway();
        botList =
            IAddressProviderV3(ICreditManagerV3(_creditManager).addressProvider()).getAddressOrRevert(AP_BOT_LIST, 3_00);

        degenNFT = _degenNFT; // F:[FA-1A]
        whitelisted = _degenNFT != address(0); // F:[FA-1A]

        expirable = _expirable;
    }

    // Notice: ETH interactions
    // CreditFacadeV3 implements a new flow for interacting with WETH compared to V1.
    // During all actions, any sent ETH value is automatically wrapped into WETH and
    // sent back to the message sender. This makes the protocol's behavior regarding
    // ETH more flexible and consistent, since there is no need to pre-wrap WETH before
    // interacting with the protocol, and no need to compute how much unused ETH has to be sent back.

    /// @dev Opens a Credit Account and runs a batch of operations in a multicall
    /// - Opens credit account with the desired borrowed amount
    /// - Executes all operations in a multicall
    /// - Checks that the new account has enough collateral
    /// - Emits OpenCreditAccount event
    ///
    /// @param debt Debt size
    /// @param onBehalfOf The address to open an account for. Transfers to it have to be allowed if
    /// msg.sender != onBehalfOf
    /// @param calls The array of MultiCall structs encoding the required operations. Generally must have
    /// at least a call to addCollateral, as otherwise the health check at the end will fail.
    /// @param referralCode Referral code which is used for potential rewards. 0 if no referral code provided
    function openCreditAccount(
        uint256 debt,
        address onBehalfOf,
        MultiCall[] calldata calls,
        bool deployNew,
        uint16 referralCode
    )
        external
        payable
        override
        whenNotPaused
        whenNotExpired
        nonReentrant
        nonZeroAddress(onBehalfOf)
        nonZeroCallsOnly(calls)
        returns (address creditAccount)
    {
        uint256[] memory forbiddenBalances;

        // Checks that the borrowed amount is within the borrowing debtLimits
        _revertIfOutOfDebtLimits(debt); // F:[FA-11B]

        // Checks whether the new borrowed amount does not violate the block limit
        _checkIncreaseDebtAllowedAndUpdateBlockLimit(debt); // F:[FA-11]

        // Checks that the msg.sender can open an account for onBehalfOf
        // msg.sender must either be the account owner themselves, or be approved for transfers
        if (msg.sender != onBehalfOf) {
            _revertIfAccountTransferNotAllowed(msg.sender, onBehalfOf);
        } // F:[FA-04C]

        // F:[FA-5] covers case when degenNFT == address(0)
        if (degenNFT != address(0)) {
            IDegenNFT(degenNFT).burn(onBehalfOf, 1); // F:[FA-4B]
        }

        // Wraps ETH and sends it back to msg.sender address
        _wrapETH(); // F:[FA-3B]

        // Requests the Credit Manager to open a Credit Account
        creditAccount = ICreditManagerV3(creditManager).openCreditAccount({
            debt: debt,
            onBehalfOf: onBehalfOf,
            deployNew: deployNew
        }); // F:[FA-8]

        // emits a new event
        emit OpenCreditAccount(creditAccount, onBehalfOf, msg.sender, debt, referralCode); // F:[FA-8]
        // F:[FA-10]: no free flashloans through opening a Credit Account
        // and immediately decreasing debt
        FullCheckParams memory fullCheckParams = _multicall({
            creditAccount: creditAccount,
            calls: calls,
            enabledTokensMask: UNDERLYING_TOKEN_MASK,
            flags: OPEN_CREDIT_ACCOUNT_FLAGS
        }); // F:[FA-8]

        // Checks that the new credit account has enough collateral to cover the debt
        _fullCollateralCheck(
            creditAccount, UNDERLYING_TOKEN_MASK, fullCheckParams, forbiddenBalances, forbiddenTokenMask
        ); // F:[FA-8, 9]
    }

    /// @dev Runs a batch of transactions within a multicall and closes the account
    /// - Wraps ETH to WETH and sends it msg.sender if value > 0
    /// - Executes the multicall - the main purpose of a multicall when closing is to convert all assets to underlying
    /// in order to pay the debt.
    /// - Closes credit account:
    ///    + Checks the underlying balance: if it is greater than the amount paid to the pool, transfers the underlying
    ///      from the Credit Account and proceeds. If not, tries to transfer the shortfall from msg.sender.
    ///    + Transfers all enabled assets with non-zero balances to the "to" address, unless they are marked
    ///      to be skipped in skipTokenMask
    ///    + If there are withdrawals scheduled for Credit Account, claims them all to `to`
    ///    + If convertWETH is true, converts WETH into ETH before sending to the recipient
    /// - Emits a CloseCreditAccount event
    ///
    /// @param to Address to send funds to during account closing
    /// @param skipTokenMask Uint-encoded bit mask where 1's mark tokens that shouldn't be transferred
    /// @param convertWETH If true, converts WETH into ETH before sending to "to"
    /// @param calls The array of MultiCall structs encoding the operations to execute before closing the account.
    function closeCreditAccount(
        address creditAccount,
        address to,
        uint256 skipTokenMask,
        bool convertWETH,
        MultiCall[] calldata calls
    ) external payable override whenNotPaused creditAccountOwnerOnly(creditAccount) nonReentrant {
        // Wraps ETH and sends it back to msg.sender
        _wrapETH(); // F:[FA-3C]

        CollateralDebtData memory debtData = _calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

        _claimWithdrawals(creditAccount, to, ClaimAction.FORCE_CLAIM);

        // [FA-13]: Calls to CreditFacadeV3 are forbidden during closure
        if (calls.length != 0) {
            // TODO: CHANGE
            FullCheckParams memory fullCheckParams =
                _multicall(creditAccount, calls, debtData.enabledTokensMask, CLOSE_CREDIT_ACCOUNT_FLAGS);
            debtData.enabledTokensMask = fullCheckParams.enabledTokensMaskAfter;
        } // F:[FA-2, 12, 13]

        /// HOW TO CHECK QUOTED BALANCES

        /// Bot permissions are specific to (owner, creditAccount),
        /// so they need to be erased on account closure
        _eraseAllBotPermissions({creditAccount: creditAccount, setFlag: false});

        // Requests the Credit manager to close the Credit Account
        _closeCreditAccount({
            creditAccount: creditAccount,
            closureAction: ClosureAction.CLOSE_ACCOUNT,
            collateralDebtData: debtData,
            payer: msg.sender,
            to: to,
            skipTokensMask: skipTokenMask,
            convertWETH: convertWETH
        }); // F:[FA-2, 12]

        // TODO: add test
        if (convertWETH) {
            _wethWithdrawTo(to);
        }

        // Emits a CloseCreditAccount event
        emit CloseCreditAccount(creditAccount, msg.sender, to); // F:[FA-12]
    }

    /// @dev Runs a batch of transactions within a multicall and liquidates the account
    /// - Computes the total value and checks that hf < 1. An account can't be liquidated when hf >= 1.
    ///   Total value has to be computed before the multicall, otherwise the liquidator would be able
    ///   to manipulate it.
    /// - Wraps ETH to WETH and sends it to msg.sender (liquidator) if value > 0
    /// - Executes the multicall - the main purpose of a multicall when liquidating is to convert all assets to underlying
    ///   in order to pay the debt.
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
    ///    + If there are withdrawals scheduled for Credit Account, cancels immature withdrawals and claims mature ones
    ///    + If convertWETH is true, converts WETH into ETH before sending
    /// - Emits LiquidateCreditAccount event
    ///
    /// @param to Address to send funds to after liquidation
    /// @param skipTokenMask Uint-encoded bit mask where 1's mark tokens that shouldn't be transferred
    /// @param convertWETH If true, converts WETH into ETH before sending to "to"
    /// @param calls The array of MultiCall structs encoding the operations to execute before liquidating the account.
    function liquidateCreditAccount(
        address creditAccount,
        address to,
        uint256 skipTokenMask,
        bool convertWETH,
        MultiCall[] calldata calls
    ) external payable override whenNotPausedOrEmergency nonZeroAddress(to) nonReentrant {
        // Checks that the CA exists to revert early for late liquidations and save gas
        address borrower = _getBorrowerOrRevert(creditAccount); // F:[FA-2]

        // Checks that the account hf < 1 and computes the totalValue
        // before the multicall
        ClosureAction closeAction;
        CollateralDebtData memory collateralDebtData;
        {
            ClaimAction claimAction;
            (claimAction, closeAction, collateralDebtData) =
                _isAccountLiquidatable({creditAccount: creditAccount, isEmergency: paused()}); // F:[FA-14]

            if (!collateralDebtData.isLiquidatable) revert CreditAccountNotLiquidatableException();

            collateralDebtData.enabledTokensMask = collateralDebtData.enabledTokensMask.enable(
                _claimWithdrawals({action: claimAction, creditAccount: creditAccount, to: borrower})
            );
        }

        // Wraps ETH and sends it back to msg.sender
        _wrapETH(); // F:[FA-3D]

        if (calls.length != 0) {
            FullCheckParams memory fullCheckParams =
                _multicall(creditAccount, calls, collateralDebtData.enabledTokensMask, CLOSE_CREDIT_ACCOUNT_FLAGS);
            collateralDebtData.enabledTokensMask = fullCheckParams.enabledTokensMaskAfter;
        } // F:[FA-15]

        /// Bot permissions are specific to (owner, creditAccount),
        /// so they need to be erased on account closure
        _eraseAllBotPermissions({creditAccount: creditAccount, setFlag: false});

        (uint256 remainingFunds, uint256 reportedLoss) = _closeCreditAccount({
            creditAccount: creditAccount,
            closureAction: closeAction,
            collateralDebtData: collateralDebtData,
            payer: msg.sender,
            to: to,
            skipTokensMask: skipTokenMask,
            convertWETH: convertWETH
        }); // F:[FA-15,49]

        if (reportedLoss > 0) {
            maxDebtPerBlockMultiplier = 0; // F: [FA-15A]

            /// reportedLoss is always less uint128, because
            /// maxLoss = maxBorrowAmount which is uint128
            lossParams.currentCumulativeLoss += uint128(reportedLoss);
            if (lossParams.currentCumulativeLoss > lossParams.maxCumulativeLoss) {
                _pause(); // F: [FA-15B]
            }
        }

        // TODO: add test
        if (convertWETH) {
            _wethWithdrawTo(to);
        }

        emit LiquidateCreditAccount(creditAccount, borrower, msg.sender, to, closeAction, remainingFunds); // F:[FA-15]
    }

    /// @dev Executes a batch of transactions within a Multicall, to manage an existing account
    ///  - Wraps ETH and sends it back to msg.sender, if value > 0
    ///  - Executes the Multicall
    ///  - Performs a fullCollateralCheck to verify that hf > 1 after all actions
    /// @param calls The array of MultiCall structs encoding the operations to execute.
    function multicall(address creditAccount, MultiCall[] calldata calls)
        external
        payable
        override
        whenNotPaused
        whenNotExpired
        creditAccountOwnerOnly(creditAccount)
        nonReentrant
    {
        // Wraps ETH and sends it back to msg.sender
        _wrapETH(); // F:[FA-3F]

        _multicallFullCollateralCheck(creditAccount, calls, ALL_PERMISSIONS);
    }

    /// @dev Executes a batch of transactions within a Multicall from bot on behalf of a borrower
    ///  - Wraps ETH and sends it back to msg.sender, if value > 0
    ///  - Executes the Multicall
    ///  - Performs a fullCollateralCheck to verify that hf > 1 after all actions
    /// @param creditAccount Address of credit account
    /// @param calls The array of MultiCall structs encoding the operations to execute.
    function botMulticall(address creditAccount, MultiCall[] calldata calls)
        external
        override
        whenNotPaused
        whenNotExpired
        nonReentrant
    {
        address borrower = _getBorrowerOrRevert(creditAccount); // F:[FA-2]
        uint256 botPermissions = IBotList(botList).botPermissions(borrower, msg.sender);
        // Checks that the bot is approved by the borrower and is not forbidden
        if (botPermissions == 0 || IBotList(botList).forbiddenBot(msg.sender)) {
            revert NotApprovedBotException(); // F: [FA-58]
        }

        _multicallFullCollateralCheck(creditAccount, calls, botPermissions);
    }

    function _multicallFullCollateralCheck(address creditAccount, MultiCall[] calldata calls, uint256 permissions)
        internal
        nonZeroCallsOnly(calls)
    {
        uint256 _forbiddenTokenMask = forbiddenTokenMask;

        uint256 enabledTokensMaskBefore = ICreditManagerV3(creditManager).enabledTokensMaskOf(creditAccount);

        uint256[] memory forbiddenBalances = CreditLogic.storeForbiddenBalances({
            creditAccount: creditAccount,
            forbiddenTokenMask: _forbiddenTokenMask,
            enabledTokensMask: enabledTokensMaskBefore,
            getTokenByMaskFn: _getTokenByMask
        });

        FullCheckParams memory fullCheckParams = _multicall(creditAccount, calls, enabledTokensMaskBefore, permissions);

        // Performs a fullCollateralCheck
        // During a multicall, all intermediary health checks are skipped,
        // as one fullCollateralCheck at the end is sufficient
        _fullCollateralCheck(
            creditAccount, enabledTokensMaskBefore, fullCheckParams, forbiddenBalances, _forbiddenTokenMask
        );
    }

    /// @dev IMPLEMENTATION: multicall
    /// - Transfers ownership from  borrower to this contract, as most adapter and Credit Manager functions retrieve
    ///   the Credit Account by msg.sender
    /// - Executes the provided list of calls:
    ///   + if targetContract == address(this), parses call data in the struct and calls the appropriate function (see _processCreditFacadeMulticall below)
    ///   + if targetContract == adapter, calls the adapter with call data as provided. Adapters skip health checks when Credit Facade is the msg.sender,
    ///     as it performs the necessary health checks on its own
    /// @param creditAccount Credit Account address
    // / @param isClosure Whether the multicall is being invoked during a closure action. Calls to Credit Facade are forbidden inside
    // /                  multicalls on closure.
    // / @param increaseDebtWasCalled True if debt was increased before or during the multicall. Used to prevent free flashloans by
    // /                  increasing and decreasing debt within a single multicall.
    //  fullCheckParams Parameters for the full collateral check which can be changed with a special function in a multicall
    //                         - collateralHints: Array of token masks that determines the order in which tokens are checked, to optimize
    //                                            gas in the fullCollateralCheck cycle
    //                         - minHealthFactor: A custom minimal HF threshold. Cannot be lower than PERCENTAGE_FACTOR
    function _multicall(address creditAccount, MultiCall[] calldata calls, uint256 enabledTokensMask, uint256 flags)
        internal
        returns (FullCheckParams memory fullCheckParams)
    {
        uint256 quotedTokenMaskInverted = ~ICreditManagerV3(creditManager).quotedTokenMask();
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
                //xw
                // CREDIT FACADE
                //
                if (mcall.target == address(this)) {
                    // Reverts of calldata has less than 4 bytes
                    if (mcall.callData.length < 4) revert IncorrectCallDataException(); // F:[FA-22]

                    bytes4 method = bytes4(mcall.callData);

                    //
                    // REVERT_IF_RECEIVED_LESS_THAN
                    //
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
                        expectedBalances = CreditLogic.storeBalances(creditAccount, expected); // F:[FA-45]
                    }
                    //
                    // SET FULL CHECK PARAMS
                    //
                    else if (method == ICreditFacadeMulticall.setFullCheckParams.selector) {
                        (fullCheckParams.collateralHints, fullCheckParams.minHealthFactor) =
                            abi.decode(mcall.callData[4:], (uint256[], uint16));
                    }
                    //
                    //
                    //
                    else if (method == ICreditFacadeMulticall.onDemandPriceUpdate.selector) {
                        _onDemandPriceUpdate(mcall.callData[4:]);
                    }
                    //
                    // ADD COLLATERAL
                    //
                    else if (method == ICreditFacadeMulticall.addCollateral.selector) {
                        _revertIfNoPermission(flags, ADD_COLLATERAL_PERMISSION);
                        enabledTokensMask = enabledTokensMask.enable({
                            bitsToEnable: _addCollateral(creditAccount, mcall.callData[4:]),
                            invertedSkipMask: quotedTokenMaskInverted
                        }); // F:[FA-26, 27]
                    }
                    //
                    // INCREASE DEBT
                    //
                    else if (method == ICreditFacadeMulticall.increaseDebt.selector) {
                        _revertIfNoPermission(flags, INCREASE_DEBT_PERMISSION);

                        // Sets increaseDebtWasCalled to prevent debt reductions afterwards,
                        // as that could be used to get free flash loans
                        flags &= ~DECREASE_DEBT_PERMISSION; // F:[FA-28]
                        flags |= INCREASE_DEBT_WAS_CALLED;
                        (uint256 tokensToEnable, uint256 tokensToDisable) = _manageDebt(
                            creditAccount, mcall.callData[4:], enabledTokensMask, ManageDebtAction.INCREASE_DEBT
                        ); // F:[FA-26]
                        enabledTokensMask = enabledTokensMask.enableDisable(tokensToEnable, tokensToDisable);
                    }
                    //
                    // DECREASE DEBT
                    //
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
                    else if (method == ICreditFacadeMulticall.enableToken.selector) {
                        _revertIfNoPermission(flags, ENABLE_TOKEN_PERMISSION);
                        // Parses token
                        address token = abi.decode(mcall.callData[4:], (address)); // F: [FA-53]
                        enabledTokensMask = enabledTokensMask.enable({
                            bitsToEnable: _getTokenMaskOrRevert(token),
                            invertedSkipMask: quotedTokenMaskInverted
                        });
                    }
                    //
                    // DISABLE TOKEN
                    //
                    else if (method == ICreditFacadeMulticall.disableToken.selector) {
                        _revertIfNoPermission(flags, DISABLE_TOKEN_PERMISSION);
                        // Parses token
                        address token = abi.decode(mcall.callData[4:], (address)); // F: [FA-53]
                        /// IGNORE QUOTED TOKEN MASK
                        enabledTokensMask = enabledTokensMask.disable({
                            bitsToDisable: _getTokenMaskOrRevert(token),
                            invertedSkipMask: quotedTokenMaskInverted
                        });
                    }
                    //
                    // UPDATE QUOTA
                    //
                    else if (method == ICreditFacadeMulticall.updateQuota.selector) {
                        _revertIfNoPermission(flags, UPDATE_QUOTA_PERMISSION);
                        (uint256 tokensToEnable, uint256 tokensToDisable) =
                            _updateQuota(creditAccount, mcall.callData[4:], enabledTokensMask);
                        enabledTokensMask = enabledTokensMask.enableDisable(tokensToEnable, tokensToDisable);
                    }
                    //
                    // WITHDRAW
                    //
                    else if (method == ICreditFacadeMulticall.scheduleWithdrawal.selector) {
                        _revertIfNoPermission(flags, WITHDRAW_PERMISSION);
                        uint256 tokensToDisable = _scheduleWithdrawal(creditAccount, mcall.callData[4:]);
                        /// IGNORE QUOTED TOKEN MASK
                        enabledTokensMask = enabledTokensMask.disable({
                            bitsToDisable: tokensToDisable,
                            invertedSkipMask: quotedTokenMaskInverted
                        });
                    }
                    //
                    // RevokeAdapterAllowances
                    //
                    else if (method == ICreditFacadeMulticall.revokeAdapterAllowances.selector) {
                        _revertIfNoPermission(flags, REVOKE_ALLOWANCES_PERMISSION);
                        _revokeAdapterAllowances(creditAccount, mcall.callData[4:]);
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
                    // Checks that the target is an allowed adapter and not CreditManagerV3
                    // As CreditFacadeV3 has powerful permissions in CreditManagers,
                    // functionCall to it is strictly forbidden, even if
                    // the Configurator adds it as an adapter

                    if (ICreditManagerV3(creditManager).adapterToContract(mcall.target) == address(0)) {
                        revert TargetContractNotAllowedException();
                    } // F:[FA-24]

                    if (flags & EXTERNAL_CONTRACT_WAS_CALLED == 0) {
                        flags |= EXTERNAL_CONTRACT_WAS_CALLED;
                        _setCaForExterallCall(creditAccount);
                    }

                    // Makes a call
                    bytes memory result = mcall.target.functionCall(mcall.callData); // F:[FA-29]
                    (uint256 tokensToEnable, uint256 tokensToDisable) = abi.decode(result, (uint256, uint256));
                    /// IGNORE QUOTED TOKEN MASK
                    enabledTokensMask = enabledTokensMask.enableDisable({
                        bitsToEnable: tokensToEnable,
                        bitsToDisable: tokensToDisable,
                        invertedSkipMask: quotedTokenMaskInverted
                    });
                }
            }
        }

        // If expectedBalances was set by calling revertIfGetLessThan,
        // checks that actual token balances are not less than expected balances
        if (expectedBalances.length != 0) {
            CreditLogic.compareBalances(creditAccount, expectedBalances);
        }

        /// @dev Checks that there are no intersections between the user's enabled tokens
        /// and the set of forbidden tokens
        /// @notice The main purpose of forbidding tokens is to prevent exposing
        /// pool funds to dangerous or exploited collateral, without immediately
        /// liquidating accounts that hold the forbidden token
        /// There are two ways pool funds can be exposed:
        ///     - The CA owner tries to swap borrowed funds to the forbidden asset:
        ///       this will be blocked by checkAndEnableToken, which is invoked for tokenOut
        ///       after every operation;
        ///     - The CA owner with an already enabled forbidden token transfers it
        ///       to the account - they can't use addCollateral / enableToken due to checkAndEnableToken,
        ///       but can transfer the token directly when it is enabled and it will be counted in the collateral -
        ///       an borrows against it. This check is used to prevent this.
        /// If the owner has a forbidden token and want to take more debt, they must first
        /// dispose of the token and disable it.
        if ((flags & INCREASE_DEBT_WAS_CALLED != 0) && (enabledTokensMask & forbiddenTokenMask > 0)) {
            revert ForbiddenTokensException();
        }

        if (flags & EXTERNAL_CONTRACT_WAS_CALLED != 0) {
            _returnCaForExterallCall();
        }

        // Emits event for multicall end - used in analytics to track actions within multicalls
        // Emits event for multicall start - used in analytics to track actions within multicalls
        emit FinishMultiCall(); // F:[FA-27,27,29]

        fullCheckParams.enabledTokensMaskAfter = enabledTokensMask;
    }

    function _setCaForExterallCall(address creditAccount) internal {
        // Takes ownership of the Credit Account
        _setExternalCallCreditAccount(creditAccount); // F:[FA-26]
    }

    function _returnCaForExterallCall() internal {
        // Takes ownership of the Credit Account
        _setExternalCallCreditAccount(address(1)); // F:[FA-26]
    }

    function _setExternalCallCreditAccount(address creditAccount) internal {
        ICreditManagerV3(creditManager).setCreditAccountForExternalCall(creditAccount); // F:[FA-26]
    }

    function _revertIfNoPermission(uint256 flags, uint256 permission) internal pure {
        if (flags & permission == 0) {
            revert NoPermissionException(permission);
        }
    }

    function _onDemandPriceUpdate(bytes calldata callData) internal {
        (address token, bytes memory data) = abi.decode(callData, (address, bytes));
        address priceFeed = IPriceOracleV2(ICreditManagerV3(creditManager).priceOracle()).priceFeeds(token);
        if (priceFeed == address(0)) revert PriceFeedNotExistsException();
        IPriceFeedOnDemand(priceFeed).updatePrice(data);
    }

    function _updateQuota(address creditAccount, bytes calldata callData, uint256 enabledTokensMask)
        internal
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        (address token, int96 quotaChange) = abi.decode(callData, (address, int96));
        return ICreditManagerV3(creditManager).updateQuota(creditAccount, token, quotaChange);
    }

    function _revokeAdapterAllowances(address creditAccount, bytes calldata callData) internal {
        (RevocationPair[] memory revocations) = abi.decode(callData, (RevocationPair[]));
        ICreditManagerV3(creditManager).revokeAdapterAllowances(creditAccount, revocations);
    }

    /// @dev Adds expected deltas to current balances on a Credit account and returns the result

    /// @dev Increases debt for a Credit Account
    /// @param creditAccount CA to increase debt for
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
            _checkIncreaseDebtAllowedAndUpdateBlockLimit(amount); // F:[FA-18A]
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

    function _addCollateral(address creditAccount, bytes calldata callData) internal returns (uint256 tokenMaskAfter) {
        (address token, uint256 amount) = abi.decode(callData, (address, uint256)); // F:[FA-26, 27]
        // Requests Credit Manager to transfer collateral to the Credit Account
        tokenMaskAfter = ICreditManagerV3(creditManager).addCollateral(msg.sender, creditAccount, token, amount); // F:[FA-21]

        // Emits event
        emit AddCollateral(creditAccount, token, amount); // F:[FA-21]
    }

    function _scheduleWithdrawal(address creditAccount, bytes calldata callData)
        internal
        returns (uint256 tokensToDisable)
    {
        (address token, uint256 amount) = abi.decode(callData, (address, uint256));
        tokensToDisable = ICreditManagerV3(creditManager).scheduleWithdrawal(creditAccount, token, amount);
    }

    /// @dev Transfers credit account to another user
    /// By default, this action is forbidden, and the user has to approve transfers from sender to itself
    /// by calling approveAccountTransfer.
    /// This is done to prevent malicious actors from transferring compromised accounts to other users.
    /// @param to Address to transfer the account to
    function transferAccountOwnership(address creditAccount, address to)
        external
        override
        whenNotPaused
        whenNotExpired
        nonZeroAddress(to)
        creditAccountOwnerOnly(creditAccount)
        nonReentrant
    {
        _revertIfAccountTransferNotAllowed(msg.sender, to);

        /// Checks that the account hf > 1, as it is forbidden to transfer
        /// accounts that are liquidatable
        (,, CollateralDebtData memory collateralDebtData) = _isAccountLiquidatable(creditAccount, false); // F:[FA-34]

        if (collateralDebtData.isLiquidatable) revert CantTransferLiquidatableAccountException(); // F:[FA-34]

        /// Bot permissions are specific to (owner, creditAccount),
        /// so they need to be erased on account transfer
        _eraseAllBotPermissions(creditAccount, true);

        // Requests the Credit Manager to transfer the account
        ICreditManagerV3(creditManager).transferAccountOwnership(creditAccount, to); // F:[FA-35]

        // Emits event
        emit TransferAccount(creditAccount, msg.sender, to); // F:[FA-35]
    }

    function claimWithdrawals(address creditAccount, address to)
        external
        override
        whenNotPaused
        nonZeroAddress(to)
        creditAccountOwnerOnly(creditAccount)
        nonReentrant
    {
        _claimWithdrawals(creditAccount, to, ClaimAction.CLAIM);
    }

    function setBotPermissions(address creditAccount, address bot, uint192 permissions)
        external
        override
        whenNotPaused
        creditAccountOwnerOnly(creditAccount)
        nonReentrant
    {
        uint16 flags = ICreditManagerV3(creditManager).flagsOf(creditAccount);

        if (flags & BOT_PERMISSIONS_SET_FLAG == 0) {
            _eraseAllBotPermissions(creditAccount, false);

            if (permissions != 0) {
                ICreditManagerV3(creditManager).setFlagFor(creditAccount, BOT_PERMISSIONS_SET_FLAG, true);
            }
        }

        uint256 remainingBots = IBotList(botList).setBotPermissions(creditAccount, bot, permissions);
        if (remainingBots == 0) {
            ICreditManagerV3(creditManager).setFlagFor(creditAccount, BOT_PERMISSIONS_SET_FLAG, false);
        }
    }

    function _eraseAllBotPermissions(address creditAccount, bool setFlag) internal {
        IBotList(botList).eraseAllBotPermissions(creditAccount);

        if (setFlag) {
            ICreditManagerV3(creditManager).setFlagFor(creditAccount, BOT_PERMISSIONS_SET_FLAG, false);
        }
    }

    /// @dev Checks that transfer is allowed
    function _revertIfAccountTransferNotAllowed(address from, address to) internal view {
        if (!transfersAllowed[from][to]) {
            revert AccountTransferNotAllowedException();
        } // F:[FA-33]
    }

    /// @dev Checks that the per-block borrow limit was not violated and updates the
    /// amount borrowed in current block
    function _checkIncreaseDebtAllowedAndUpdateBlockLimit(uint256 amount) internal {
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

    /// @dev Checks that the borrowed principal is within borrowing debtLimits
    /// @param debt The current principal of a Credit Account
    function _revertIfOutOfDebtLimits(uint256 debt) internal view {
        // Checks that amount is in debtLimits
        if (debt < uint256(debtLimits.minDebt) || debt > uint256(debtLimits.maxDebt)) {
            revert BorrowAmountOutOfLimitsException();
        } // F:
    }

    /// @dev Approves account transfer from another user to msg.sender
    /// @param from Address for which account transfers are allowed/forbidden
    /// @param allowTransfer True is transfer is allowed, false if forbidden
    function approveAccountTransfer(address from, bool allowTransfer) external override nonReentrant {
        // In whitelisted mode only select addresses can have Credit Accounts
        // So this action is prohibited
        if (whitelisted) revert AccountTransferNotAllowedException(); // F:[FA-32]

        transfersAllowed[from][msg.sender] = allowTransfer; // F:[FA-38]

        // Emits event
        emit SetAccountTransferAllowance(from, msg.sender, allowTransfer); // F:[FA-38]
    }

    //
    // HELPERS
    //

    /// @dev Internal wrapper for `creditManager.getBorrowerOrRevert()`
    /// @notice The external call is wrapped to optimize contract size
    function _getBorrowerOrRevert(address borrower) internal view returns (address) {
        return ICreditManagerV3(creditManager).getBorrowerOrRevert(borrower);
    }

    function _getTokenMaskOrRevert(address token) internal view returns (uint256 mask) {
        mask = ICreditManagerV3(creditManager).getTokenMaskOrRevert(token);
    }

    function _closeCreditAccount(
        address creditAccount,
        ClosureAction closureAction,
        CollateralDebtData memory collateralDebtData,
        address payer,
        address to,
        uint256 skipTokensMask,
        bool convertWETH
    ) internal returns (uint256 remainingFunds, uint256 reportedLoss) {
        (remainingFunds, reportedLoss) = ICreditManagerV3(creditManager).closeCreditAccount({
            creditAccount: creditAccount,
            closureAction: closureAction,
            collateralDebtData: collateralDebtData,
            payer: payer,
            to: to,
            skipTokensMask: skipTokensMask,
            convertWETH: convertWETH
        }); // F:[FA-15,49]
    }

    /// @dev Internal wrapper for `creditManager.fullCollateralCheck()`
    /// @notice The external call is wrapped to optimize contract size
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

        CreditLogic.checkForbiddenBalances({
            creditAccount: creditAccount,
            enabledTokensMaskBefore: enabledTokensMaskBefore,
            enabledTokensMaskAfter: fullCheckParams.enabledTokensMaskAfter,
            forbiddenBalances: forbiddenBalances,
            forbiddenTokenMask: _forbiddenTokenMask,
            getTokenByMaskFn: _getTokenByMask
        });
    }

    /// @dev Returns whether the Credit Facade is expired
    function _isExpired() internal view returns (bool isExpired) {
        isExpired = (expirable) && (block.timestamp >= expirationDate); // F: [FA-46,47,48]
    }

    //
    // GETTERS
    //

    /// @dev Wraps ETH into WETH and sends it back to msg.sender
    /// TODO: Check L2 networks for supporting native currencies
    function _wrapETH() internal {
        if (msg.value > 0) {
            IWETH(weth).deposit{value: msg.value}(); // F:[FA-3]
            IWETH(weth).transfer(msg.sender, msg.value); // F:[FA-3]
        }
    }

    /// @dev Checks if account is liquidatable (i.e., hf < 1)
    /// @param creditAccount Address of credit account to check
    function _isAccountLiquidatable(address creditAccount, bool isEmergency)
        internal
        view
        returns (ClaimAction claimAction, ClosureAction closeAction, CollateralDebtData memory collateralDebtData)
    {
        claimAction = isEmergency ? ClaimAction.FORCE_CANCEL : ClaimAction.CANCEL;
        collateralDebtData = _calcDebtAndCollateral(
            creditAccount,
            isEmergency
                ? CollateralCalcTask.DEBT_COLLATERAL_FORCE_CANCEL_WITHDRAWALS
                : CollateralCalcTask.DEBT_COLLATERAL_CANCEL_WITHDRAWALS
        );
        closeAction = ClosureAction.LIQUIDATE_ACCOUNT;

        if (!collateralDebtData.isLiquidatable && _isExpired()) {
            collateralDebtData.isLiquidatable = true;
            closeAction = ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT;
        }
    }

    function _calcDebtAndCollateral(address creditAccount, CollateralCalcTask task)
        internal
        view
        returns (CollateralDebtData memory)
    {
        return ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, task);
    }

    function _getTokenByMask(uint256 mask) internal view returns (address) {
        return ICreditManagerV3(creditManager).getTokenByMask(mask);
    }

    function _claimWithdrawals(address creditAccount, address to, ClaimAction action)
        internal
        returns (uint256 tokensToEnable)
    {
        tokensToEnable = ICreditManagerV3(creditManager).claimWithdrawals(creditAccount, to, action);
    }

    function _wethWithdrawTo(address to) internal {
        IWETHGateway(wethGateway).withdrawTo(to);
    }

    //
    // CONFIGURATION
    //

    /// @dev Sets Credit Facade expiration date
    /// @notice See more at https://dev.gearbox.fi/docs/documentation/credit/liquidation#liquidating-accounts-by-expiration
    function setExpirationDate(uint40 newExpirationDate) external creditConfiguratorOnly {
        if (!expirable) {
            revert NotAllowedWhenNotExpirableException();
        }
        expirationDate = newExpirationDate;
    }

    /// @dev Sets borrowing debtLimits per single Credit Account
    /// @param _minDebt The minimal borrowed amount per Credit Account. Minimal amount can be relevant
    /// for liquidations, since very small amounts will make liquidations unprofitable for liquidators
    /// @param _maxDebt The maximal borrowed amount per Credit Account. Used to limit exposure per a single
    /// credit account - especially relevant in whitelisted mode.
    function setDebtLimits(uint128 _minDebt, uint128 _maxDebt, uint8 _maxDebtPerBlockMultiplier)
        external
        creditConfiguratorOnly
    {
        debtLimits.minDebt = _minDebt; // F:
        debtLimits.maxDebt = _maxDebt; // F:
        maxDebtPerBlockMultiplier = _maxDebtPerBlockMultiplier;
    }

    /// @dev Sets the bot list for this Credit Facade
    ///      The bot list is used to determine whether an address has a right to
    ///      run multicalls for a borrower as a bot. The relationship is stored in a separate
    ///      contract for easier transferability
    function setBotList(address _botList) external creditConfiguratorOnly {
        botList = _botList;
    }

    /// @dev Sets the max cumulative loss that can be accrued before pausing the Credit Manager
    function setCumulativeLossParams(uint128 _maxCumulativeLoss, bool resetCumulativeLoss)
        external
        creditConfiguratorOnly
    {
        lossParams.maxCumulativeLoss = _maxCumulativeLoss;
        if (resetCumulativeLoss) {
            lossParams.currentCumulativeLoss = 0;
        }
    }

    /// @dev Adds forbidden token
    function setTokenAllowance(address token, AllowanceAction allowance) external creditConfiguratorOnly {
        uint256 tokenMask = _getTokenMaskOrRevert(token);

        if (allowance == AllowanceAction.ALLOW) {
            if (forbiddenTokenMask & tokenMask != 0) {
                forbiddenTokenMask ^= tokenMask;
            }
        } else {
            forbiddenTokenMask |= tokenMask;
        }
    }

    /// @dev Adds an address to the list of emergency liquidators
    /// @param liquidator Address to add to the list
    function setEmergencyLiquidator(address liquidator, AllowanceAction allowanceAction)
        external
        creditConfiguratorOnly // F:[CM-4]
    {
        canLiquidateWhilePaused[liquidator] = allowanceAction == AllowanceAction.ALLOW;
    }
}
