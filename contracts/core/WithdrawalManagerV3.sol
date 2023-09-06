// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";

import {AP_WETH_TOKEN, IAddressProviderV3, NO_VERSION_CONTROL} from "../interfaces/IAddressProviderV3.sol";
import {
    AmountCantBeZeroException,
    CallerNotCreditManagerException,
    NoFreeWithdrawalSlotsException,
    NothingToClaimException,
    ReceiveIsNotAllowedException
} from "../interfaces/IExceptions.sol";
import {
    ClaimAction, ETH_ADDRESS, IWithdrawalManagerV3, ScheduledWithdrawal
} from "../interfaces/IWithdrawalManagerV3.sol";
import {UnsafeERC20} from "../libraries/UnsafeERC20.sol";
import {WithdrawalsLogic} from "../libraries/WithdrawalsLogic.sol";
import {ACLTrait} from "../traits/ACLTrait.sol";
import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";

/// @title Withdrawal manager
/// @notice Contract that handles withdrawals from credit accounts.
///         There are two kinds of withdrawals: immediate and scheduled.
///         - Immediate withdrawals can be claimed, well, immediately, and exist to support blacklistable tokens
///           and WETH unwrapping upon credit account closure/liquidation.
///         - Scheduled withdrawals can be claimed after a certain delay, and exist to support partial withdrawals
///           from credit accounts. One credit account can have up to two scheduled withdrawals at the same time.
contract WithdrawalManagerV3 is IWithdrawalManagerV3, ACLTrait, ContractsRegisterTrait {
    using SafeERC20 for IERC20;
    using UnsafeERC20 for IERC20;
    using Address for address payable;
    using EnumerableSet for EnumerableSet.AddressSet;
    using WithdrawalsLogic for ClaimAction;
    using WithdrawalsLogic for ScheduledWithdrawal;
    using WithdrawalsLogic for ScheduledWithdrawal[2];

    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice WETH token address
    address public immutable override weth;

    /// @notice Mapping account => token => claimable amount
    mapping(address => mapping(address => uint256)) public override immediateWithdrawals;

    /// @notice Delay for scheduled withdrawals
    uint40 public override delay;

    /// @dev Mapping credit account => scheduled withdrawals
    mapping(address => ScheduledWithdrawal[2]) internal _scheduled;

    /// @dev Mapping from address to its status as an approved credit manager
    mapping(address => bool) public isValidCreditManager;

    /// @dev Ensures that function caller is one of added credit managers
    modifier creditManagerOnly() {
        _ensureCallerIsCreditManager();
        _;
    }

    /// @notice Constructor
    /// @param _addressProvider Address of the address provider
    /// @param _delay Delay for scheduled withdrawals
    constructor(address _addressProvider, uint40 _delay)
        ACLTrait(_addressProvider)
        ContractsRegisterTrait(_addressProvider)
    {
        weth = IAddressProviderV3(_addressProvider).getAddressOrRevert(AP_WETH_TOKEN, NO_VERSION_CONTROL); // U:[WM-1]

        if (_delay != 0) {
            delay = _delay; // U:[WM-1]
        }
        emit SetWithdrawalDelay(_delay);
    }

    /// @notice Allows this contract to unwrap WETH and forbids receiving ETH another way
    receive() external payable {
        if (msg.sender != weth) revert ReceiveIsNotAllowedException(); // U:[WM-2]
    }

    // --------------------- //
    // IMMEDIATE WITHDRAWALS //
    // --------------------- //

    /// @notice Adds new immediate withdrawal for the account
    /// @param token Token to withdraw
    /// @param to Account to add immediate withdrawal for
    /// @param amount Amount to withdraw
    /// @custom:expects Credit manager transferred `amount` of `token` to this contract prior to calling this function
    function addImmediateWithdrawal(address token, address to, uint256 amount)
        external
        override
        creditManagerOnly // U:[WM-2]
    {
        _addImmediateWithdrawal({account: to, token: token, amount: amount}); // U:[WM-3]
    }

    /// @notice Claims caller's immediate withdrawal
    /// @param token Token to claim (if `ETH_ADDRESS`, claims WETH, but unwraps it before sending)
    /// @param to Token recipient
    function claimImmediateWithdrawal(address token, address to)
        external
        override
        nonZeroAddress(to) // U:[WM-4A]
    {
        _claimImmediateWithdrawal({
            account: msg.sender,
            token: token == ETH_ADDRESS ? weth : token,
            to: to,
            unwrapWETH: token == ETH_ADDRESS
        }); // U:[WM-4B,4C,4D]
    }

    /// @dev Increases `account`'s immediately withdrawable balance of `token` by `amount`
    function _addImmediateWithdrawal(address account, address token, uint256 amount) internal {
        if (amount > 1) {
            immediateWithdrawals[account][token] += amount; // U:[WM-3]
            emit AddImmediateWithdrawal(account, token, amount); // U:[WM-3]
        }
    }

    /// @dev Sends all `account`'s immediately withdrawable balance of `token` to `to`
    function _claimImmediateWithdrawal(address account, address token, address to, bool unwrapWETH) internal {
        uint256 amount = immediateWithdrawals[account][token];
        if (amount <= 1) revert NothingToClaimException(); // U:[WM-4B]
        unchecked {
            --amount; // U:[WM-4C,4D]
        }
        immediateWithdrawals[account][token] = 1; // U:[WM-4C,4D]
        _safeTransfer(token, to, amount, unwrapWETH); // U:[WM-4C,4D]
        emit ClaimImmediateWithdrawal(account, token, to, amount); // U:[WM-4C,4D]
    }

    /// @dev Transfers token, optionally unwraps WETH before sending
    function _safeTransfer(address token, address to, uint256 amount, bool unwrapWETH) internal {
        if (unwrapWETH && token == weth) {
            IWETH(weth).withdraw(amount); // U:[WM-4D]
            payable(to).sendValue(amount); // U:[WM-4D]
        } else {
            IERC20(token).safeTransfer(to, amount); // U:[WM-4C]
        }
    }

    // --------------------- //
    // SCHEDULED WITHDRAWALS //
    // --------------------- //

    /// @notice Returns withdrawals scheduled for a given credit account
    /// @param creditAccount Account to get withdrawals for
    /// @return withdrawals See `ScheduledWithdrawal`
    function scheduledWithdrawals(address creditAccount)
        external
        view
        override
        returns (ScheduledWithdrawal[2] memory)
    {
        return _scheduled[creditAccount];
    }

    /// @notice Schedules withdrawal from the credit account
    /// @param creditAccount Account to withdraw from
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw
    /// @param tokenIndex Collateral index of withdrawn token in account's credit manager
    /// @custom:expects Credit manager transferred `amount` of `token` to this contract prior to calling this function
    function addScheduledWithdrawal(address creditAccount, address token, uint256 amount, uint8 tokenIndex)
        external
        override
        creditManagerOnly // U:[WM-2]
    {
        if (amount <= 1) {
            revert AmountCantBeZeroException(); // U:[WM-5A]
        }
        ScheduledWithdrawal[2] storage withdrawals = _scheduled[creditAccount];
        (bool found, uint8 slot) = withdrawals.findFreeSlot(); // U:[WM-5B]
        if (!found) revert NoFreeWithdrawalSlotsException(); // U:[WM-5B]

        uint40 maturity = uint40(block.timestamp) + delay;
        withdrawals[slot] =
            ScheduledWithdrawal({tokenIndex: tokenIndex, token: token, maturity: maturity, amount: amount}); // U:[WM-5B]
        emit AddScheduledWithdrawal(creditAccount, token, amount, maturity); // U:[WM-5B]
    }

    /// @notice Claims scheduled withdrawals from the credit account
    ///         - Withdrawals are either sent to `to` or returned to `creditAccount` based on maturity and `action`
    ///         - If `to` is blacklisted in claimed token, scheduled withdrawal turns into immediate
    /// @param creditAccount Account withdrawal was made from
    /// @param to Address to send withdrawals to
    /// @param action See `ClaimAction`
    /// @return hasScheduled Whether account has at least one scheduled withdrawal after claiming
    /// @return tokensToEnable Bit mask of returned tokens that should be enabled as account's collateral
    function claimScheduledWithdrawals(address creditAccount, address to, ClaimAction action)
        external
        override
        creditManagerOnly // U:[WM-2]
        returns (bool hasScheduled, uint256 tokensToEnable)
    {
        ScheduledWithdrawal[2] storage withdrawals = _scheduled[creditAccount];

        (bool scheduled0, bool claimed0, uint256 tokensToEnable0) =
            _processScheduledWithdrawal(withdrawals[0], action, creditAccount, to); // U:[WM-6B]
        (bool scheduled1, bool claimed1, uint256 tokensToEnable1) =
            _processScheduledWithdrawal(withdrawals[1], action, creditAccount, to); // U:[WM-6B]

        if (action == ClaimAction.CLAIM && !(claimed0 || claimed1)) {
            revert NothingToClaimException(); // U:[WM-6A]
        }

        hasScheduled = scheduled0 || scheduled1; // U:[WM-6B]
        tokensToEnable = tokensToEnable0 | tokensToEnable1; // U:[WM-6B]
    }

    /// @notice Returns scheduled withdrawals from the credit account that can be cancelled
    function cancellableScheduledWithdrawals(address creditAccount, bool isForceCancel)
        external
        view
        override
        returns (address token1, uint256 amount1, address token2, uint256 amount2)
    {
        ScheduledWithdrawal[2] storage withdrawals = _scheduled[creditAccount];
        ClaimAction action = isForceCancel ? ClaimAction.FORCE_CANCEL : ClaimAction.CANCEL; // U:[WM-7]
        if (action.cancelAllowed(withdrawals[0].maturity)) {
            (token1,, amount1) = withdrawals[0].tokenMaskAndAmount(); // U:[WM-7]
        }
        if (action.cancelAllowed(withdrawals[1].maturity)) {
            (token2,, amount2) = withdrawals[1].tokenMaskAndAmount(); // U:[WM-7]
        }
    }

    /// @dev Claims or cancels withdrawal based on its maturity and action type
    function _processScheduledWithdrawal(
        ScheduledWithdrawal storage w,
        ClaimAction action,
        address creditAccount,
        address to
    ) internal returns (bool scheduled, bool claimed, uint256 tokensToEnable) {
        uint40 maturity = w.maturity;
        scheduled = maturity > 1; // U:[WM-8]
        if (action.claimAllowed(maturity)) {
            _claimScheduledWithdrawal(w, creditAccount, to); // U:[WM-8]
            scheduled = false; // U:[WM-8]
            claimed = true; // U:[WM-8]
        } else if (action.cancelAllowed(maturity)) {
            tokensToEnable = _cancelScheduledWithdrawal(w, creditAccount); // U:[WM-8]
            scheduled = false; // U:[WM-8]
        }
    }

    /// @dev Claims scheduled withdrawal, clears withdrawal in storage
    /// @custom:expects Withdrawal is scheduled
    function _claimScheduledWithdrawal(ScheduledWithdrawal storage w, address creditAccount, address to) internal {
        (address token,, uint256 amount) = w.tokenMaskAndAmount(); // U:[WM-9A,9B]
        w.clear(); // U:[WM-9A,9B]
        emit ClaimScheduledWithdrawal(creditAccount, token, to, amount); // U:[WM-9A,9B]

        bool success = IERC20(token).unsafeTransfer(to, amount); // U:[WM-9A]
        if (!success) _addImmediateWithdrawal(to, token, amount); // U:[WM-9B]
    }

    /// @dev Cancels withdrawal, clears withdrawal in storage
    /// @custom:expects Withdrawal is scheduled
    function _cancelScheduledWithdrawal(ScheduledWithdrawal storage w, address creditAccount)
        internal
        returns (uint256 tokensToEnable)
    {
        (address token, uint256 tokenMask, uint256 amount) = w.tokenMaskAndAmount(); // U:[WM-10]
        w.clear(); // U:[WM-10]
        emit CancelScheduledWithdrawal(creditAccount, token, amount); // U:[WM-10]

        IERC20(token).safeTransfer(creditAccount, amount); // U:[WM-10]
        tokensToEnable = tokenMask; // U:[WM-10]
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets delay for scheduled withdrawals, only affects new withdrawal requests
    /// @param newDelay New delay for scheduled withdrawals
    function setWithdrawalDelay(uint40 newDelay)
        external
        override
        configuratorOnly // U:[WM-2]
    {
        if (newDelay != delay) {
            delay = newDelay; // U:[WM-11]
            emit SetWithdrawalDelay(newDelay); // U:[WM-11]
        }
    }

    /// @notice Adds new credit manager that can interact with this contract
    /// @param newCreditManager New credit manager to add
    function addCreditManager(address newCreditManager)
        external
        override
        configuratorOnly // U:[WM-2]
        registeredCreditManagerOnly(newCreditManager) // U:[WM-12A]
    {
        if (!isValidCreditManager[newCreditManager]) {
            isValidCreditManager[newCreditManager] = true; // U:[WM-12B]
            emit AddCreditManager(newCreditManager); // U:[WM-12B]
        }
    }

    /// @dev Ensures caller is one of added credit managers
    function _ensureCallerIsCreditManager() internal view {
        if (!isValidCreditManager[msg.sender]) {
            revert CallerNotCreditManagerException();
        }
    }
}
