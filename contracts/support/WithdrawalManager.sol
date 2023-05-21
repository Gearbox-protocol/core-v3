// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    AmountCantBeZeroException,
    CallerNotCreditManagerException,
    NoFreeWithdrawalSlotsException,
    NothingToClaimException
} from "../interfaces/IExceptions.sol";
import {ClaimAction, IWithdrawalManager, IVersion, ScheduledWithdrawal} from "../interfaces/IWithdrawalManager.sol";
import {IERC20Helper} from "../libraries/IERC20Helper.sol";
import {WithdrawalsLogic} from "../libraries/WithdrawalsLogic.sol";
import {ACLTrait} from "../traits/ACLTrait.sol";
import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";

/// @title Withdrawal manager
/// @notice Contract that handles withdrawals from credit accounts.
///         There are two kinds of withdrawals: immediate and scheduled.
///         - Immediate withdrawals can be claimed, well, immediately, and exist to support blacklistable tokens.
///         - Scheduled withdrawals can be claimed after a certain delay, and exist to support partial withdrawals
///           from credit accounts. One credit account can have up to two scheduled withdrawals at the same time.
contract WithdrawalManager is IWithdrawalManager, ACLTrait, ContractsRegisterTrait {
    using SafeERC20 for IERC20;
    using IERC20Helper for IERC20;
    using WithdrawalsLogic for ClaimAction;
    using WithdrawalsLogic for ScheduledWithdrawal;
    using WithdrawalsLogic for ScheduledWithdrawal[2];

    /// @inheritdoc IVersion
    uint256 public constant override version = 3_00;

    /// @inheritdoc IWithdrawalManager
    mapping(address => mapping(address => uint256)) public override immediateWithdrawals;

    /// @inheritdoc IWithdrawalManager
    uint40 public override delay;

    /// @dev Mapping credit account => scheduled withdrawals
    mapping(address => ScheduledWithdrawal[2]) internal _scheduled;

    /// @notice Constructor
    /// @param _addressProvider Address of the address provider
    /// @param _delay Delay for scheduled withdrawals
    constructor(address _addressProvider, uint40 _delay)
        ACLTrait(_addressProvider)
        ContractsRegisterTrait(_addressProvider)
    {
        if (_delay != 0) {
            delay = _delay; // U:[WM-1]
        }
        emit SetWithdrawalDelay(_delay);
    }

    /// --------------------- ///
    /// IMMEDIATE WITHDRAWALS ///
    /// --------------------- ///

    /// @inheritdoc IWithdrawalManager
    function addImmediateWithdrawal(address token, address to, uint256 amount)
        external
        override
        registeredCreditManagerOnly(msg.sender) // U:[WM-2]
    {
        _addImmediateWithdrawal({account: to, token: token, amount: amount});
    }

    /// @inheritdoc IWithdrawalManager
    function claimImmediateWithdrawal(address token, address to)
        external
        override
        nonZeroAddress(to) // U:[WM-4A]
    {
        _claimImmediateWithdrawal(msg.sender, token, to);
    }

    /// @dev Increases `account`'s immediately withdrawable balance of `token` by `amount`
    function _addImmediateWithdrawal(address account, address token, uint256 amount) internal {
        if (amount > 1) {
            immediateWithdrawals[account][token] += amount; // U:[WM-3]
            emit AddImmediateWithdrawal(account, token, amount); // U:[WM-3]
        }
    }

    /// @dev Sends all `account`'s immediately withdrawable balance of `token` to `to`
    function _claimImmediateWithdrawal(address account, address token, address to) internal {
        uint256 amount = immediateWithdrawals[account][token];
        if (amount < 2) revert NothingToClaimException(); // U:[WM-4B]
        unchecked {
            --amount; // U:[WM-4C]
        }
        immediateWithdrawals[account][token] = 1; // U:[WM-4C]
        IERC20(token).safeTransfer(to, amount); // U:[WM-4C]
        emit ClaimImmediateWithdrawal(account, token, to, amount); // U:[WM-4C]
    }

    /// --------------------- ///
    /// SCHEDULED WITHDRAWALS ///
    /// --------------------- ///

    /// @inheritdoc IWithdrawalManager
    function scheduledWithdrawals(address creditAccount)
        external
        view
        override
        returns (ScheduledWithdrawal[2] memory)
    {
        return _scheduled[creditAccount];
    }

    /// @inheritdoc IWithdrawalManager
    function addScheduledWithdrawal(address creditAccount, address token, uint256 amount, uint8 tokenIndex)
        external
        override
        registeredCreditManagerOnly(msg.sender) // U:[WM-2]
    {
        if (amount < 2) {
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

    /// @inheritdoc IWithdrawalManager
    function claimScheduledWithdrawals(address creditAccount, address to, ClaimAction action)
        external
        override
        registeredCreditManagerOnly(msg.sender) // U:[WM-2]
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

    /// @inheritdoc IWithdrawalManager
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

    /// ------------- ///
    /// CONFIGURATION ///
    /// ------------- ///

    /// @inheritdoc IWithdrawalManager
    function setWithdrawalDelay(uint40 _delay)
        external
        override
        configuratorOnly // U:[WM-2]
    {
        if (_delay != delay) {
            delay = _delay; // U:[WM-11]
            emit SetWithdrawalDelay(_delay); // U:[WM-11]
        }
    }
}
