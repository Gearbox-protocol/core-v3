// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";

//  DATA
import {TokenIndex} from "../libraries/TokenIndex.sol";
import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {Balance, BalanceOps} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";
import {QuotaUpdate} from "../interfaces/IPoolQuotaKeeper.sol";

/// INTERFACES
import {ICreditFacade, ICreditFacadeExtended, FullCheckParams} from "../interfaces/ICreditFacade.sol";
import {ICreditManagerV2, ClosureAction} from "../interfaces/ICreditManagerV2.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";

import {IPool4626} from "../interfaces/IPool4626.sol";
import {TokenLT} from "../interfaces/IPoolQuotaKeeper.sol";
import {IDegenNFT} from "@gearbox-protocol/core-v2/contracts/interfaces/IDegenNFT.sol";
import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {IWETHGateway} from "../interfaces/IWETHGateway.sol";
import {IBlacklistHelper} from "../interfaces/IBlacklistHelper.sol";
import {IBotList} from "../interfaces/IBotList.sol";

// CONSTANTS
import {LEVERAGE_DECIMALS} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

struct Params {
    /// @dev Maximal amount of new debt that can be taken per block
    uint128 maxBorrowedAmountPerBlock;
    /// @dev True if increasing debt is forbidden
    bool isIncreaseDebtForbidden;
    /// @dev Timestamp of the next expiration (for expirable Credit Facades only)
    uint40 expirationDate;
}

struct Limits {
    /// @dev Minimal borrowed amount per credit account
    uint128 minBorrowedAmount;
    /// @dev Maximum aborrowed amount per credit account
    uint128 maxBorrowedAmount;
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
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;
    using Address for address;

    using TokenIndex for uint256;
    using TokenIndex for address;

    /// @dev Credit Manager connected to this Credit Facade
    ICreditManagerV2 public immutable creditManager;

    /// @dev Whether the whitelisted mode is active
    bool public immutable whitelisted;

    /// @dev Whether the Credit Manager's underlying has blacklisting
    bool public immutable isBlacklistableUnderlying;

    /// @dev Whether the Credit Facade implements expirable logic
    bool public immutable expirable;

    /// @dev Keeps frequently accessed parameters for storage access optimization
    Params public override params;

    /// @dev Keeps borrowing limits together for storage access optimization
    Limits public override limits;

    /// @dev Keeps parameters that are used to pause the system after too much bad debt over a short period
    CumulativeLossParams public override lossParams;

    /// @dev Address of the pool
    address public immutable pool;

    /// @dev Address of the underlying token
    address public immutable underlying;

    /// @dev True of credit manager support quotas
    bool public immutable supportsQuotas;

    /// @dev Contract containing the list of approval statuses for borrowers / bots
    address public botList;

    /// @dev A map that stores whether a user allows a transfer of an account from another user to themselves
    mapping(address => mapping(address => bool)) public override transfersAllowed;

    /// @dev Address of WETH
    address public immutable wethAddress;

    /// @dev Address of WETH Gateway
    IWETHGateway public immutable wethGateway;

    /// @dev Address of the DegenNFT that gatekeeps account openings in whitelisted mode
    address public immutable override degenNFT;

    /// @dev Address of the BlacklistHelper if underlying is blacklistable, otherwise address(0)
    address public immutable override blacklistHelper;

    /// @dev Stores in a compressed state the last block where borrowing happened and the total amount borrowed in that block
    uint256 internal totalBorrowedInBlock;

    /// @dev Bit mask encoding a set of forbidden tokens
    uint256 public forbiddenTokenMask;

    EnumerableSet.UintSet internal forbiddenTokenSet;

    /// @dev Contract version
    uint256 public constant override version = 3_00;

    /// @dev Restricts actions for users with opened credit accounts only
    modifier creditConfiguratorOnly() {
        if (msg.sender != creditManager.creditConfigurator()) {
            revert CallerNotConfiguratorException();
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
        require(!paused() || creditManager.canLiquidateWhilePaused(msg.sender), "Pausable: paused");
        _;
    }

    /// @dev Initializes creditFacade and connects it with CreditManagerV3
    /// @param _creditManager address of Credit Manager
    /// @param _degenNFT address of the DegenNFT or address(0) if whitelisted mode is not used
    /// @param _blacklistHelper address of the funds recovery contract for blacklistable underlyings.
    ///                         Must be address(0) is the underlying is not blacklistable
    /// @param _expirable Whether the CreditFacadeV3 can expire and implements expiration-related logic
    constructor(address _creditManager, address _degenNFT, address _blacklistHelper, bool _expirable)
        ACLNonReentrantTrait(address(IPool4626(ICreditManagerV2(_creditManager).pool()).addressProvider()))
        nonZeroAddress(_creditManager)
    {
        creditManager = ICreditManagerV2(_creditManager); // F:[FA-1A]
        pool = creditManager.pool();
        underlying = ICreditManagerV2(_creditManager).underlying(); // F:[FA-1A]
        supportsQuotas = creditManager.supportsQuotas(); // TODO: add test

        wethAddress = ICreditManagerV2(_creditManager).wethAddress(); // F:[FA-1A]
        wethGateway = IWETHGateway(ICreditManagerV2(_creditManager).wethGateway());

        degenNFT = _degenNFT; // F:[FA-1A]
        whitelisted = _degenNFT != address(0); // F:[FA-1A]

        blacklistHelper = _blacklistHelper;
        isBlacklistableUnderlying = _blacklistHelper != address(0);
        if (_blacklistHelper != address(0)) {
            emit BlacklistHelperSet(_blacklistHelper);
        }

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
    /// @param borrowedAmount Debt size
    /// @param onBehalfOf The address to open an account for. Transfers to it have to be allowed if
    /// msg.sender != onBehalfOf
    /// @param calls The array of MultiCall structs encoding the required operations. Generally must have
    /// at least a call to addCollateral, as otherwise the health check at the end will fail.
    /// @param referralCode Referral code which is used for potential rewards. 0 if no referral code provided
    function openCreditAccount(
        uint256 borrowedAmount,
        address onBehalfOf,
        MultiCall[] calldata calls,
        uint16 referralCode
    ) external payable override whenNotPaused nonReentrant nonZeroCallsOnly(calls) {
        uint256[] memory forbiddenBalances;

        // Checks whether the new borrowed amount does not violate the block limit
        _checkAndUpdateBorrowedBlockLimit(borrowedAmount); // F:[FA-11]

        // Checks that the msg.sender can open an account for onBehalfOf
        _revertIfOpenCreditAccountNotAllowed(onBehalfOf); // F:[FA-4A, 4B]

        // Checks that the borrowed amount is within the borrowing limits
        _revertIfOutOfBorrowedLimits(borrowedAmount); // F:[FA-11B]

        // Wraps ETH and sends it back to msg.sender address
        _wrapETH(); // F:[FA-3B]

        // Requests the Credit Manager to open a Credit Account
        address creditAccount = creditManager.openCreditAccount(borrowedAmount, onBehalfOf); // F:[FA-8]

        // emits a new event
        emit OpenCreditAccount(onBehalfOf, creditAccount, borrowedAmount, referralCode); // F:[FA-8]
        // F:[FA-10]: no free flashloans through opening a Credit Account
        // and immediately decreasing debt
        FullCheckParams memory fullCheckParams = _multicall(calls, onBehalfOf, creditAccount, 1, false, true); // F:[FA-8]

        // Checks that the new credit account has enough collateral to cover the debt
        _fullCollateralCheck(creditAccount, 1, fullCheckParams, forbiddenBalances); // F:[FA-8, 9]
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
    ///    + If convertWETH is true, converts WETH into ETH before sending to the recipient
    /// - Emits a CloseCreditAccount event
    ///
    /// @param to Address to send funds to during account closing
    /// @param skipTokenMask Uint-encoded bit mask where 1's mark tokens that shouldn't be transferred
    /// @param convertWETH If true, converts WETH into ETH before sending to "to"
    /// @param calls The array of MultiCall structs encoding the operations to execute before closing the account.
    function closeCreditAccount(address to, uint256 skipTokenMask, bool convertWETH, MultiCall[] calldata calls)
        external
        payable
        override
        whenNotPaused
        nonReentrant
    {
        // Check for existing CA
        address creditAccount = _getCreditAccountOrRevert(msg.sender); // F:[FA-2]

        // Wraps ETH and sends it back to msg.sender
        _wrapETH(); // F:[FA-3C]

        uint256 enabledTokensMask = _enabledTokenMask(creditAccount);

        // [FA-13]: Calls to CreditFacadeV3 are forbidden during closure
        if (calls.length != 0) {
            // TODO: CHANGE
            FullCheckParams memory fullCheckParams =
                _multicall(calls, msg.sender, creditAccount, enabledTokensMask, true, false);
            enabledTokensMask = fullCheckParams.enabledTokensMaskAfter;
        } // F:[FA-2, 12, 13]

        (,, uint256 borrowedAmountWithInterestAndFees) = creditManager.calcCreditAccountAccruedInterest(creditAccount);

        // Requests the Credit manager to close the Credit Account
        creditManager.closeCreditAccount(
            msg.sender,
            ClosureAction.CLOSE_ACCOUNT,
            0,
            msg.sender,
            to,
            enabledTokensMask,
            skipTokenMask,
            borrowedAmountWithInterestAndFees,
            convertWETH
        ); // F:[FA-2, 12]

        // TODO: add test
        if (convertWETH) {
            wethGateway.withdrawTo(to);
        }

        // Emits a CloseCreditAccount event
        emit CloseCreditAccount(msg.sender, to); // F:[FA-12]
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
    ///    + If convertWETH is true, converts WETH into ETH before sending
    /// - Emits LiquidateCreditAccount event
    ///
    /// @param to Address to send funds to after liquidation
    /// @param skipTokenMask Uint-encoded bit mask where 1's mark tokens that shouldn't be transferred
    /// @param convertWETH If true, converts WETH into ETH before sending to "to"
    /// @param calls The array of MultiCall structs encoding the operations to execute before liquidating the account.
    function liquidateCreditAccount(
        address borrower,
        address to,
        uint256 skipTokenMask,
        bool convertWETH,
        MultiCall[] calldata calls
    ) external payable override whenNotPausedOrEmergency nonReentrant nonZeroAddress(to) {
        // Checks that the CA exists to revert early for late liquidations and save gas
        address creditAccount = _getCreditAccountOrRevert(borrower); // F:[FA-2]

        // Checks that the account hf < 1 and computes the totalValue
        // before the multicall
        ClosureAction closeAction;
        uint256 totalValue;
        uint256 borrowedAmountWithInterest;
        uint256 enabledTokensMask;
        {
            bool isLiquidatable;
            (isLiquidatable, closeAction, totalValue, borrowedAmountWithInterest, enabledTokensMask) =
                _isAccountLiquidatable(creditAccount); // F:[FA-14]

            if (!isLiquidatable) revert CreditAccountNotLiquidatableException();
        }
        // Wraps ETH and sends it back to msg.sender
        _wrapETH(); // F:[FA-3D]

        if (calls.length != 0) {
            // TODO: CHANGE
            FullCheckParams memory fullCheckParams = _multicall(calls, borrower, creditAccount, 0, true, false);
            enabledTokensMask = fullCheckParams.enabledTokensMaskAfter;
        } // F:[FA-15]

        // uint256 remainingFunds =
        _liquidateCreditAccount(
            totalValue,
            borrower,
            to,
            enabledTokensMask,
            skipTokenMask,
            borrowedAmountWithInterest,
            convertWETH,
            closeAction
        );
    }

    /// @dev Closes a liquidated credit account, possibly expired
    function _liquidateCreditAccount(
        uint256 totalValue,
        address borrower,
        address to,
        uint256 enabledTokensMask,
        uint256 skipTokenMask,
        uint256 borrowedAmountWithInterest,
        bool convertWETH,
        ClosureAction closeAction
    ) internal returns (uint256 remainingFunds) {
        uint256 helperBalance = _isBlacklisted(borrower);
        // If the borrower is blacklisted, transfer the account to a special recovery contract,
        // so that the attempt to transfer remaining funds to a blacklisted borrower does not
        // break the liquidation. The borrower can retrieve the funds from the recovery contract afterwards.
        if (helperBalance > 0) {
            _transferAccount(borrower, blacklistHelper);
        } // F:[FA-56]

        // Liquidates the CA and sends the remaining funds to the borrower or blacklist helper
        uint256 reportedLoss;
        (remainingFunds, reportedLoss) = creditManager.closeCreditAccount(
            helperBalance > 0 ? blacklistHelper : borrower,
            closeAction,
            totalValue,
            msg.sender,
            to,
            enabledTokensMask,
            skipTokenMask,
            borrowedAmountWithInterest,
            convertWETH
        ); // F:[FA-15,49]

        if (reportedLoss > 0) {
            params.isIncreaseDebtForbidden = true; // F: [FA-15A]

            /// reportedLoss is always less uint128, because
            /// maxLoss = maxBorrowAmount which is uint128
            lossParams.currentCumulativeLoss += uint128(reportedLoss);
            if (lossParams.currentCumulativeLoss > lossParams.maxCumulativeLoss) {
                _pause(); // F: [FA-15B]
            }
        }

        /// Credit Facade increases the borrower's claimable balance in BlacklistHelper, so the
        /// borrower can recover funds to a different address
        if (helperBalance > 0 && remainingFunds > 1) {
            _increaseClaimableBalance(borrower, helperBalance);
        }

        // TODO: add test
        if (convertWETH) {
            wethGateway.withdrawTo(to);
        }

        emit LiquidateCreditAccount(borrower, msg.sender, to, closeAction, remainingFunds); // F:[FA-15]
    }

    /// @dev Checks whether borrower is blacklisted in the underlying token and, if so,
    ///      returns non-zero value equal to blacklist helper's balance of underlying
    //       Zero return value always indicates that borrower is not blacklisted
    function _isBlacklisted(address borrower) internal view returns (uint256 helperBalance) {
        if (
            isBlacklistableUnderlying && IBlacklistHelper(blacklistHelper).isBlacklisted(underlying, borrower) // F:[FA-56]
        ) {
            // can't realistically overflow
            unchecked {
                helperBalance = IERC20(underlying).balanceOf(blacklistHelper) + 1;
            }
        }
    }

    /// @dev Checks if blacklist helper's balance of underlying increased after liquidation
    ///      and, if so, increases the borrower's claimable balance by the difference
    ///      Not relying on `remainingFunds` to support fee-on-transfer tokens
    function _increaseClaimableBalance(address borrower, uint256 helperBalanceBefore) internal {
        uint256 helperBalance = IERC20(underlying).balanceOf(blacklistHelper);
        if (helperBalance > helperBalanceBefore) {
            uint256 amount;
            unchecked {
                amount = helperBalance - helperBalanceBefore;
            }
            IBlacklistHelper(blacklistHelper).addClaimable(underlying, borrower, amount); // F:[FA-56]
            emit UnderlyingSentToBlacklistHelper(borrower, amount); // F:[FA-56]
        }
    }

    /// @dev Executes a batch of transactions within a Multicall, to manage an existing account
    ///  - Wraps ETH and sends it back to msg.sender, if value > 0
    ///  - Executes the Multicall
    ///  - Performs a fullCollateralCheck to verify that hf > 1 after all actions
    /// @param calls The array of MultiCall structs encoding the operations to execute.
    function multicall(MultiCall[] calldata calls) external payable override whenNotPaused nonReentrant {
        // Wraps ETH and sends it back to msg.sender
        _wrapETH(); // F:[FA-3F]

        _multicallFullCollateralCheck(msg.sender, calls);
    }

    /// @dev Executes a batch of transactions within a Multicall from bot on behalf of a borrower
    ///  - Wraps ETH and sends it back to msg.sender, if value > 0
    ///  - Executes the Multicall
    ///  - Performs a fullCollateralCheck to verify that hf > 1 after all actions
    /// @param borrower Borrower to perform the multicall for
    /// @param calls The array of MultiCall structs encoding the operations to execute.
    function botMulticall(address borrower, MultiCall[] calldata calls)
        external
        payable
        override
        whenNotPaused
        nonReentrant
    {
        // Checks that the bot is approved by the borrower and is not forbidden
        if (!IBotList(botList).approvedBot(borrower, msg.sender) || IBotList(botList).forbiddenBot(msg.sender)) {
            revert NotApprovedBotException(); // F: [FA-58]
        }

        _multicallFullCollateralCheck(borrower, calls);
    }

    function _multicallFullCollateralCheck(address borrower, MultiCall[] calldata calls)
        internal
        nonZeroCallsOnly(calls)
    {
        // Checks that msg.sender has an account
        address creditAccount = _getCreditAccountOrRevert(borrower);

        (uint256 enabledTokenMaskBefore, uint256[] memory forbiddenBalances) = _storeForbiddenBalances(creditAccount);

        FullCheckParams memory fullCheckParams =
            _multicall(calls, msg.sender, creditAccount, enabledTokenMaskBefore, false, false);

        // Performs a fullCollateralCheck
        // During a multicall, all intermediary health checks are skipped,
        // as one fullCollateralCheck at the end is sufficient
        _fullCollateralCheck(creditAccount, enabledTokenMaskBefore, fullCheckParams, forbiddenBalances);
    }

    /// @dev IMPLEMENTATION: multicall
    /// - Transfers ownership from  borrower to this contract, as most adapter and Credit Manager functions retrieve
    ///   the Credit Account by msg.sender
    /// - Executes the provided list of calls:
    ///   + if targetContract == address(this), parses call data in the struct and calls the appropriate function (see _processCreditFacadeMulticall below)
    ///   + if targetContract == adapter, calls the adapter with call data as provided. Adapters skip health checks when Credit Facade is the msg.sender,
    ///     as it performs the necessary health checks on its own
    /// @param borrower Owner of the Credit Account
    /// @param creditAccount Credit Account address
    /// @param isClosure Whether the multicall is being invoked during a closure action. Calls to Credit Facade are forbidden inside
    ///                  multicalls on closure.
    /// @param increaseDebtWasCalled True if debt was increased before or during the multicall. Used to prevent free flashloans by
    ///                  increasing and decreasing debt within a single multicall.
    //  fullCheckParams Parameters for the full collateral check which can be changed with a special function in a multicall
    //                         - collateralHints: Array of token masks that determines the order in which tokens are checked, to optimize
    //                                            gas in the fullCollateralCheck cycle
    //                         - minHealthFactor: A custom minimal HF threshold. Cannot be lower than PERCENTAGE_FACTOR
    function _multicall(
        MultiCall[] calldata calls,
        address borrower,
        address creditAccount,
        uint256 enabledTokensMask,
        bool isClosure,
        bool increaseDebtWasCalled
    ) internal returns (FullCheckParams memory fullCheckParams) {
        // Takes ownership of the Credit Account
        _transferAccount(borrower, address(this)); // F:[FA-26]

        // Emits event for multicall start - used in analytics to track actions within multicalls
        emit MultiCallStarted(borrower); // F:[FA-26]

        // Declares the expectedBalances array, which can later be used for slippage control
        Balance[] memory expectedBalances;

        fullCheckParams.minHealthFactor = PERCENTAGE_FACTOR;
        // Minimal HF is set to PERCENTAGE_FACTOR by default

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

                    // No internal calls on closure except slippage control, to avoid loss manipulation
                    if (isClosure && method != ICreditFacadeExtended.revertIfReceivedLessThan.selector) {
                        revert ForbiddenDuringClosureException();
                    } // F:[FA-13]

                    bytes memory callData = mcall.callData[4:];

                    //
                    // REVERT_IF_RECEIVED_LESS_THAN
                    //
                    if (method == ICreditFacadeExtended.revertIfReceivedLessThan.selector) {
                        // Sets expected balances to currentBalance + delta
                        expectedBalances = _storeBalances(creditAccount, callData, expectedBalances); // F:[FA-45]
                    }
                    //
                    // SET FULL CHECK PARAMS
                    //
                    else if (method == ICreditFacadeExtended.setFullCheckParams.selector) {
                        (fullCheckParams.collateralHints, fullCheckParams.minHealthFactor) =
                            abi.decode(callData, (uint256[], uint16));
                    }
                    //
                    // ADD COLLATERAL
                    //
                    else if (method == ICreditFacadeExtended.addCollateral.selector) {
                        enabledTokensMask |= _addCollateral(creditAccount, callData, borrower); // F:[FA-26, 27]
                    }
                    //
                    // INCREASE DEBT
                    //
                    else if (method == ICreditFacadeExtended.increaseDebt.selector) {
                        // Sets increaseDebtWasCalled to prevent debt reductions afterwards,
                        // as that could be used to get free flash loans
                        increaseDebtWasCalled = true; // F:[FA-28]
                        _increaseDebt(creditAccount, callData, borrower); // F:[FA-26]
                    }
                    //
                    // DECREASE DEBT
                    //
                    else if (method == ICreditFacadeExtended.decreaseDebt.selector) {
                        // it's forbidden to call decreaseDebt after increaseDebt, in the same multicall
                        if (increaseDebtWasCalled) {
                            revert IncreaseAndDecreaseForbiddenInOneCallException();
                        }
                        // F:[FA-28]

                        _decreaseDebt(creditAccount, callData, borrower); // F:[FA-27]
                    }
                    //
                    // ENABLE TOKEN
                    //
                    else if (method == ICreditFacadeExtended.enableToken.selector) {
                        // Parses token
                        address token = abi.decode(callData, (address)); // F: [FA-53]
                        enabledTokensMask |= _tokenMaskByAddressOrRevert(token);
                    }
                    //
                    // DISABLE TOKEN
                    //
                    else if (method == ICreditFacadeExtended.disableToken.selector) {
                        // Parses token
                        address token = abi.decode(callData, (address)); // F: [FA-53]
                        enabledTokensMask &= ~_tokenMaskByAddressOrRevert(token);
                    }
                    //
                    // UPDATE QUOTAS
                    //
                    else if (method == ICreditFacadeExtended.updateQuotas.selector) {
                        QuotaUpdate[] memory quotaUpdates = abi.decode(callData, (QuotaUpdate[]));
                        creditManager.updateQuotas(creditAccount, quotaUpdates);
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

                    // Checks that the target is an allowed adapter and not CreditManagerV3
                    // As CreditFacadeV3 has powerful permissions in CreditManagers,
                    // functionCall to it is strictly forbidden, even if
                    // the Configurator adds it as an adapter
                    if (
                        creditManager.adapterToContract(mcall.target) == address(0)
                            || mcall.target == address(creditManager)
                    ) revert TargetContractNotAllowedException(); // F:[FA-24]

                    // Makes a call
                    bytes memory result = mcall.target.functionCall(mcall.callData); // F:[FA-29]
                    (uint256 tokensToEnable, uint256 tokensToDsable) = abi.decode(result, (uint256, uint256));
                    enabledTokensMask = (enabledTokensMask | tokensToEnable) & (~tokensToDsable);
                }
            }
        }

        // If expectedBalances was set by calling revertIfGetLessThan,
        // checks that actual token balances are not less than expected balances
        if (expectedBalances.length != 0) {
            _compareBalances(creditAccount, expectedBalances);
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
        if (increaseDebtWasCalled && (enabledTokensMask & forbiddenTokenMask > 0)) {
            revert ForbiddenTokensException();
        }

        // Emits event for multicall end - used in analytics to track actions within multicalls
        emit MultiCallFinished(); // F:[FA-27,27,29]

        fullCheckParams.enabledTokensMaskAfter = enabledTokensMask;

        // Returns ownership back to the borrower
        _transferAccount(address(this), borrower); // F:[FA-27,27,29]
    }

    /// @dev Adds expected deltas to current balances on a Credit account and returns the result

    /// @param creditAccount Credit Account to compute balances for
    /// @param callData Bytes calldata for parsing
    /// @param expectedBalances Current value of expected balances, used for checking that we run the function only once

    function _storeBalances(address creditAccount, bytes memory callData, Balance[] memory expectedBalances)
        internal
        view
        returns (Balance[] memory expected)
    {
        // Method can only be called once since the provided Balance array
        // contains deltas that are added to the current balances
        // Calling this function again could potentially override old values
        // and cause confusion, especially if called later in the MultiCall
        if (expectedBalances.length != 0) {
            revert ExpectedBalancesAlreadySetException();
        } // F:[FA-45A]

        // Retrieves the balance list from calldata
        expected = abi.decode(callData, (Balance[])); // F:[FA-45]
        uint256 len = expected.length; // F:[FA-45]

        for (uint256 i = 0; i < len;) {
            expected[i].balance += IERC20(expected[i].token).balanceOf(creditAccount); // F:[FA-45]
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Compares current balances to previously saved expected balances.
    /// Reverts if at least one balance is lower than expected
    /// @param creditAccount Credit Account to check
    /// @param expected Expected balances after all operations

    function _compareBalances(address creditAccount, Balance[] memory expected) internal view {
        uint256 len = expected.length; // F:[FA-45]
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                if (IERC20(expected[i].token).balanceOf(creditAccount) < expected[i].balance) {
                    revert BalanceLessThanMinimumDesiredException(expected[i].token);
                } // F:[FA-45]
            }
        }
    }

    /// @dev Increases debt for a Credit Account
    /// @param creditAccount CA to increase debt for
    /// @param callData Bytes calldata for parsing
    /// @param borrower Owner of the account
    function _increaseDebt(address creditAccount, bytes memory callData, address borrower) internal {
        // It is forbidden to take new debt if increaseDebtForbidden mode is enabled
        if (params.isIncreaseDebtForbidden) {
            revert IncreaseDebtForbiddenException();
        } // F:[FA-18C]

        uint256 amount = abi.decode(callData, (uint256)); // F:[FA-26]

        // Checks that the borrowed amount does not violate the per block limit
        _checkAndUpdateBorrowedBlockLimit(amount); // F:[FA-18A]

        // Requests the Credit Manager to borrow additional funds from the pool
        uint256 newBorrowedAmount = creditManager.manageDebt(creditAccount, amount, true); // F:[FA-17]

        // Checks that the new total borrowed amount is within bounds
        _revertIfOutOfBorrowedLimits(newBorrowedAmount); // F:[FA-18B]

        // Emits event
        emit IncreaseBorrowedAmount(borrower, amount); // F:[FA-17]
    }

    /// @dev Decreases debt for a Credit Account
    /// @param creditAccount CA to increase debt for
    /// @param callData Bytes calldata for parsing
    /// @param borrower Owner of the account
    function _decreaseDebt(address creditAccount, bytes memory callData, address borrower) internal {
        uint256 amount = abi.decode(callData, (uint256)); // F:[FA-26]

        // Requests the creditManager to reduce the borrowed sum by amount
        uint256 newBorrowedAmount = creditManager.manageDebt(creditAccount, amount, false); // F:[FA-19]

        // Checks that the new borrowed amount is within limits
        _revertIfOutOfBorrowedLimits(newBorrowedAmount); // F:[FA-20]

        // Emits an event
        emit DecreaseBorrowedAmount(borrower, amount); // F:[FA-19]
    }

    function _addCollateral(address creditAccount, bytes memory callData, address borrower)
        internal
        returns (uint256 tokenMaskAfter)
    {
        (address token, uint256 amount) = abi.decode(callData, (address, uint256)); // F:[FA-26, 27]
        // Requests Credit Manager to transfer collateral to the Credit Account
        tokenMaskAfter = creditManager.addCollateral(msg.sender, creditAccount, token, amount); // F:[FA-21]

        // Emits event
        emit AddCollateral(borrower, token, amount); // F:[FA-21]
    }

    /// @dev Transfers credit account to another user
    /// By default, this action is forbidden, and the user has to approve transfers from sender to itself
    /// by calling approveAccountTransfer.
    /// This is done to prevent malicious actors from transferring compromised accounts to other users.
    /// @param to Address to transfer the account to
    function transferAccountOwnership(address to) external override whenNotPaused nonReentrant {
        // In whitelisted mode only select addresses can have Credit Accounts
        // So this action is prohibited
        if (whitelisted) revert AccountTransferNotAllowedException(); // F:[FA-32]

        address creditAccount = _getCreditAccountOrRevert(msg.sender); // F:[FA-2]

        // Checks that transfer is allowed
        if (!transfersAllowed[msg.sender][to]) {
            revert AccountTransferNotAllowedException();
        } // F:[FA-33]

        /// Checks that the account hf > 1, as it is forbidden to transfer
        /// accounts that are liquidatable
        _isAccountLiquidatable(creditAccount); // F:[FA-34]

        /// TODO: FIX
        // if (isLiquidatable) revert CantTransferLiquidatableAccountException(); // F:[FA-34]

        // Requests the Credit Manager to transfer the account
        _transferAccount(msg.sender, to); // F:[FA-35]

        // Emits event
        emit TransferAccount(msg.sender, to); // F:[FA-35]
    }

    /// @dev Verifies that the msg.sender can open an account for onBehalfOf
    /// -  For expirable Credit Facade, expiration date must not be reached
    /// -  For whitelisted mode, msg.sender must open the account for themselves
    ///    and have at least one DegenNFT to burn
    /// -  Otherwise, checks that account transfers from msg.sender to onBehalfOf
    ///    are approved
    /// @param onBehalfOf Account which would own credit account
    function _revertIfOpenCreditAccountNotAllowed(address onBehalfOf) internal {
        // Opening new Credit Accounts is prohibited in increaseDebtForbidden mode
        if (params.isIncreaseDebtForbidden) {
            revert IncreaseDebtForbiddenException();
        } // F:[FA-7]

        // Checks that this CreditFacadeV3 is not expired
        if (_isExpired()) {
            revert OpenAccountNotAllowedAfterExpirationException(); // F: [FA-46]
        }

        // Checks that the borrower is not blacklisted, if the underlying is blacklistable
        if (_isBlacklisted(onBehalfOf) != 0) {
            revert NotAllowedForBlacklistedAddressException();
        }

        // F:[FA-5] covers case when degenNFT == address(0)
        if (degenNFT != address(0)) {
            // F:[FA-4B]

            // In whitelisted mode, users can only open an account by burning a DegenNFT
            // And opening an account for another address is forbidden
            if (whitelisted && msg.sender != onBehalfOf) {
                revert AccountTransferNotAllowedException();
            } // F:[FA-4B]

            IDegenNFT(degenNFT).burn(onBehalfOf, 1); // F:[FA-4B]
        }

        _revertIfActionOnAccountNotAllowed(onBehalfOf);
    }

    /// @dev Checks if the message sender is allowed to do an action on a CA
    /// @param onBehalfOf The account which owns the target CA
    function _revertIfActionOnAccountNotAllowed(address onBehalfOf) internal view {
        // msg.sender must either be the account owner themselves,
        // or be approved for transfers
        if (msg.sender != onBehalfOf && !transfersAllowed[msg.sender][onBehalfOf]) {
            revert AccountTransferNotAllowedException();
        } // F:[FA-04C]
    }

    /// @dev Checks that the per-block borrow limit was not violated and updates the
    /// amount borrowed in current block
    function _checkAndUpdateBorrowedBlockLimit(uint256 amount) internal {
        // Skipped in whitelisted mode, since there is a strict limit on the number
        // of credit accounts that can be opened, which implies a limit on borrowing
        if (!whitelisted) {
            uint256 _limitPerBlock = params.maxBorrowedAmountPerBlock; // F:[FA-18]

            // If the limit is unit128.max, the check is disabled
            // F:[FA-36] test case when _limitPerBlock == type(uint128).max
            if (_limitPerBlock != type(uint128).max) {
                (uint64 lastBlock, uint128 lastLimit) = getTotalBorrowedInBlock(); // F:[FA-18, 37]

                uint256 newLimit = (lastBlock == block.number)
                    ? amount + lastLimit // F:[FA-37]
                    : amount; // F:[FA-18, 37]

                if (newLimit > _limitPerBlock) {
                    revert BorrowedBlockLimitException();
                } // F:[FA-18]

                _updateTotalBorrowedInBlock(uint128(newLimit)); // F:[FA-37]
            }
        }
    }

    /// @dev Checks that the borrowed principal is within borrowing limits
    /// @param borrowedAmount The current principal of a Credit Account
    function _revertIfOutOfBorrowedLimits(uint256 borrowedAmount) internal view {
        // Checks that amount is in limits
        if (borrowedAmount < uint256(limits.minBorrowedAmount) || borrowedAmount > uint256(limits.maxBorrowedAmount)) {
            revert BorrowAmountOutOfLimitsException();
        } // F:
    }

    /// @dev Returns the last block where debt was taken,
    ///      and the total amount borrowed in that block
    function getTotalBorrowedInBlock() public view returns (uint64 blockLastUpdate, uint128 borrowedInBlock) {
        blockLastUpdate = uint64(totalBorrowedInBlock >> 128); // F:[FA-37]
        borrowedInBlock = uint128(totalBorrowedInBlock & type(uint128).max); // F:[FA-37]
    }

    /// @dev Saves the total amount borrowed in the current block for future checks
    /// @param borrowedInBlock Updated total borrowed amount
    function _updateTotalBorrowedInBlock(uint128 borrowedInBlock) internal {
        totalBorrowedInBlock = uint256(block.number << 128) | borrowedInBlock; // F:[FA-37]
    }

    /// @dev Approves account transfer from another user to msg.sender
    /// @param from Address for which account transfers are allowed/forbidden
    /// @param state True is transfer is allowed, false if forbidden
    function approveAccountTransfer(address from, bool state) external override nonReentrant {
        transfersAllowed[from][msg.sender] = state; // F:[FA-38]

        // Emits event
        emit TransferAccountAllowed(from, msg.sender, state); // F:[FA-38]
    }

    //
    // HELPERS
    //

    /// @dev Internal wrapper for `creditManager.transferAccountOwnership()`
    /// @notice The external call is wrapped to optimize contract size
    function _transferAccount(address from, address to) internal {
        creditManager.transferAccountOwnership(from, to);
    }

    /// @dev Internal wrapper for `creditManager.getCreditAccountOrRevert()`
    /// @notice The external call is wrapped to optimize contract size
    function _getCreditAccountOrRevert(address borrower) internal view returns (address) {
        return creditManager.getCreditAccountOrRevert(borrower);
    }

    function _tokenMaskByAddressOrRevert(address token) internal view returns (uint256 mask) {
        mask = creditManager.getTokenMaskOrRevert(token);
        if (mask == 0) revert TokenNotAllowedException();
    }

    /// @dev Internal wrapper for `creditManager.fullCollateralCheck()`
    /// @notice The external call is wrapped to optimize contract size
    function _fullCollateralCheck(
        address creditAccount,
        uint256 enabledTokenMaskBefore,
        FullCheckParams memory fullCheckParams,
        uint256[] memory forbiddenBalances
    ) internal {
        creditManager.fullCollateralCheck(
            creditAccount,
            fullCheckParams.enabledTokensMaskAfter,
            fullCheckParams.collateralHints,
            fullCheckParams.minHealthFactor
        );

        uint256 forbiddenTokensOnAccount = fullCheckParams.enabledTokensMaskAfter & forbiddenTokenMask;

        if (forbiddenTokensOnAccount != 0) {
            if (enabledTokenMaskBefore ^ fullCheckParams.enabledTokensMaskAfter & forbiddenTokensOnAccount != 0) {
                revert TokenNotAllowedException();
            }

            _checkForbiddenBalances(creditAccount, forbiddenBalances, forbiddenTokensOnAccount);
        }
    }

    function _storeForbiddenBalances(address creditAccount)
        internal
        view
        returns (uint256 enabledTokenMaskBefore, uint256[] memory forbiddenBalances)
    {
        enabledTokenMaskBefore = creditManager.enabledTokensMap(creditAccount);
        uint256 forbiddenTokensOnAccount = enabledTokenMaskBefore & forbiddenTokenMask;
        if (forbiddenTokensOnAccount != 0) {
            uint256 len = forbiddenTokenSet.length();
            forbiddenBalances = new uint256[](len);

            unchecked {
                for (uint256 i; i < len; ++i) {
                    (address token, uint8 index) = forbiddenTokenSet.at(i).unzip();
                    if (forbiddenTokensOnAccount & (1 << index) != 0) {
                        forbiddenBalances[i] = IERC20(token).balanceOf(creditAccount);
                    }
                }
            }
        }
    }

    function _checkForbiddenBalances(
        address creditAccount,
        uint256[] memory forbiddenBalances,
        uint256 forbiddenTokensOnAccount
    ) internal view {
        uint256 len = forbiddenTokenSet.length();

        unchecked {
            for (uint256 i; i < len; ++i) {
                (address token, uint8 index) = forbiddenTokenSet.at(i).unzip();
                if (forbiddenTokensOnAccount & (1 << index) != 0) {
                    uint256 balance = IERC20(token).balanceOf(creditAccount);
                    if (balance > forbiddenBalances[i]) {
                        revert ForbiddenTokensException();
                    }
                }
            }
        }
    }

    /// @dev Returns whether the Credit Facade is expired
    function _isExpired() internal view returns (bool isExpired) {
        isExpired = (expirable) && (block.timestamp >= params.expirationDate); // F: [FA-46,47,48]
    }

    //
    // GETTERS
    //

    // /// @dev Calculates total value for provided Credit Account in underlying
    // /// More: https://dev.gearbox.fi/developers/credit/economy#totalUSD-value
    // ///
    // /// @param creditAccount Credit Account address
    // /// @return total Total value in underlying
    // /// @return twv Total weighted (discounted by liquidation thresholds) value in underlying
    function calcTotalValue(address creditAccount) public view override returns (uint256 total, uint256 twv) {
        // return creditManager.calcTotalValue(creditAccount);
    }

    // /**
    //  * @dev Calculates health factor for the credit account
    //  *
    //  *          sum(asset[i] * liquidation threshold[i])
    //  *   Hf = --------------------------------------------
    //  *         borrowed amount + interest accrued + fees
    //  *
    //  *
    //  * More info: https://dev.gearbox.fi/developers/credit/economy#health-factor
    //  *
    //  * @param creditAccount Credit account address
    //  * @return hf = Health factor in bp (see PERCENTAGE FACTOR in Constants.sol)
    //  */
    // function calcCreditAccountHealthFactor(address creditAccount) public view override returns (uint256 hf) {
    //     (, uint256 twv) = calcTotalValue(creditAccount); // F:[FA-42]
    //     (,, uint256 borrowAmountWithInterestAndFees) = creditManager.calcCreditAccountAccruedInterest(creditAccount); // F:[FA-42]
    //     hf = (twv * PERCENTAGE_FACTOR) / borrowAmountWithInterestAndFees; // F:[FA-42]
    // }

    /// @dev Returns true if the borrower has an open Credit Account
    /// @param borrower Borrower address
    function hasOpenedCreditAccount(address borrower) public view override returns (bool) {
        return creditManager.creditAccounts(borrower) != address(0); // F:[FA-43]
    }

    /// @dev Wraps ETH into WETH and sends it back to msg.sender
    function _wrapETH() internal {
        if (msg.value > 0) {
            IWETH(wethAddress).deposit{value: msg.value}(); // F:[FA-3]
            IWETH(wethAddress).transfer(msg.sender, msg.value); // F:[FA-3]
        }
    }

    /// @dev Checks if account is liquidatable (i.e., hf < 1)
    /// @param creditAccount Address of credit account to check

    function _isAccountLiquidatable(address creditAccount)
        internal
        view
        returns (
            bool isLiquidatable,
            ClosureAction ca,
            uint256 totalValue,
            uint256 borrowedAmountWithInterest,
            uint256 enabledTokenMask
        )
    {
        (totalValue,, borrowedAmountWithInterest, enabledTokenMask, isLiquidatable) = _calcTotalValue(creditAccount);

        if (_isExpired()) {
            return (
                true, ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT, totalValue, borrowedAmountWithInterest, enabledTokenMask
            );
        }

        return
            (isLiquidatable, ClosureAction.LIQUIDATE_ACCOUNT, totalValue, borrowedAmountWithInterest, enabledTokenMask);
    }

    function _calcTotalValue(address creditAccount)
        internal
        view
        returns (
            uint256 total,
            uint256 twv,
            uint256 borrowedAmountWithInterest,
            uint256 enabledTokenMask,
            bool canBeLiquidated
        )
    {
        return creditManager.calcTotalValue(creditAccount);
    }

    function _enabledTokenMask(address creditAccount) internal view returns (uint256) {
        return creditManager.enabledTokensMap(creditAccount);
    }

    //
    // CONFIGURATION
    //

    /// @dev Sets the increaseDebtForbidden mode
    /// @notice increaseDebtForbidden can be used to secure pool funds
    /// without pausing the entire system. E.g., if a bug is reported
    /// that can potentially lead to loss of funds, but there is no
    /// immediate threat, new borrowing can be stopped, while other
    /// functionality (trading, closing/liquidating accounts) is retained
    function setIncreaseDebtForbidden(bool _mode)
        external
        creditConfiguratorOnly // F:[FA-44]
    {
        params.isIncreaseDebtForbidden = _mode;
    }

    /// @dev Sets borrowing limit per single block
    /// @notice Borrowing limit per block in conjunction with
    /// the monitoring system serves to minimize loss from hacks
    /// While an attacker would be able to steal, in worst case,
    /// up to (limitPerBlock * n blocks) of funds, the monitoring
    /// system would pause the contracts after detecting suspicious
    /// activity
    function setLimitPerBlock(uint128 newLimit)
        external
        creditConfiguratorOnly // F:[FA-44]
    {
        params.maxBorrowedAmountPerBlock = newLimit;
    }

    /// @dev Sets Credit Facade expiration date
    /// @notice See more at https://dev.gearbox.fi/docs/documentation/credit/liquidation#liquidating-accounts-by-expiration
    function setExpirationDate(uint40 newExpirationDate) external creditConfiguratorOnly {
        if (!expirable) {
            revert NotAllowedWhenNotExpirableException();
        }
        params.expirationDate = newExpirationDate;
    }

    /// @dev Sets borrowing limits per single Credit Account
    /// @param _minBorrowedAmount The minimal borrowed amount per Credit Account. Minimal amount can be relevant
    /// for liquidations, since very small amounts will make liquidations unprofitable for liquidators
    /// @param _maxBorrowedAmount The maximal borrowed amount per Credit Account. Used to limit exposure per a single
    /// credit account - especially relevant in whitelisted mode.
    function setCreditAccountLimits(uint128 _minBorrowedAmount, uint128 _maxBorrowedAmount)
        external
        creditConfiguratorOnly
    {
        limits.minBorrowedAmount = _minBorrowedAmount; // F:
        limits.maxBorrowedAmount = _maxBorrowedAmount; // F:
    }

    /// @dev Sets the bot list for this Credit Facade
    ///      The bot list is used to determine whether an address has a right to
    ///      run multicalls for a borrower as a bot. The relationship is stored in a separate
    ///      contract for easier transferability
    function setBotList(address _botList) external creditConfiguratorOnly {
        botList = _botList;
    }

    /// @dev Sets the max cumulative loss that can be accrued before pausing the Credit Manager
    function setMaxCumulativeLoss(uint128 _maxCumulativeLoss) external creditConfiguratorOnly {
        lossParams.maxCumulativeLoss = _maxCumulativeLoss;
    }

    /// @dev Resets the current cumulative loss value
    function resetCumulativeLoss() external creditConfiguratorOnly {
        lossParams.currentCumulativeLoss = 0;
    }

    /// @dev Adds forbidden token
    function forbidToken(address tokenToForbid) external creditConfiguratorOnly {
        (uint256 tokenMaskMap, uint256 zip) = _getTokenMaskAndZip(tokenToForbid);
        forbiddenTokenSet.add(zip);
        forbiddenTokenMask |= tokenMaskMap;
    }

    function allowToken(address token) external creditConfiguratorOnly {
        (uint256 tokenMaskMap, uint256 zip) = _getTokenMaskAndZip(token);
        if (forbiddenTokenSet.contains(zip)) {
            forbiddenTokenSet.remove(zip);
            forbiddenTokenMask ^= tokenMaskMap;
        }
    }

    function _getTokenMaskAndZip(address token) internal view returns (uint256 tokenMask, uint256 zip) {
        tokenMask = _tokenMaskByAddressOrRevert(token);
        uint8 tokenIndex = _maskToIndex(tokenMask);
        zip = token.zipWith(tokenIndex);
    }

    function _maskToIndex(uint256 mask) internal pure returns (uint8) {
        for (uint8 index; index < 256; index++) {
            if (mask == (1 << index)) return index;
        }
        revert IncorrectParameterException();
    }
}
