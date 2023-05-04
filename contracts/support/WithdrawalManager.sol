// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {
    AmountCantBeZeroException,
    CallerNotCreditManagerException,
    NoFreeWithdrawalSlotsException,
    NothingToClaimException
} from "../interfaces/IExceptions.sol";
import {
    CancelAction,
    ClaimAction,
    IWithdrawalManager,
    IVersion,
    ScheduledWithdrawal
} from "../interfaces/IWithdrawalManager.sol";
import {Withdrawals} from "../libraries/Withdrawals.sol";
import {ACLTrait} from "../traits/ACLTrait.sol";
import {IERC20HelperTrait} from "../traits/IERC20HelperTrait.sol";

/// @title Withdrawal manager
/// @notice Contract that handles withdrawals from credit accounts.
///         There are two kinds of withdrawals: immediate and scheduled.
///         - Immediate withdrawals can be claimed, well, immediately, and exist to support blacklistable tokens.
///         - Scheduled withdrawals can be claimed after a certain delay, and exist to support partial withdrawals
///           from credit accounts. One credit account can have up to two scheduled withdrawals at the same time.
contract WithdrawalManager is IWithdrawalManager, ACLTrait, IERC20HelperTrait {
    using Withdrawals for ScheduledWithdrawal;
    using Withdrawals for ScheduledWithdrawal[2];

    /// @inheritdoc IVersion
    uint256 public constant override version = 3_00;

    /// @inheritdoc IWithdrawalManager
    mapping(address => bool) public override creditManagerStatus;

    /// @inheritdoc IWithdrawalManager
    mapping(address => mapping(address => uint256)) public override immediateWithdrawals;

    /// @inheritdoc IWithdrawalManager
    uint40 public override delay;

    /// @dev Mapping credit account => scheduled withdrawals
    mapping(address => ScheduledWithdrawal[2]) private _scheduled;

    /// @notice Ensures that caller of the function is one of registered credit managers
    modifier creditManagerOnly() {
        if (!creditManagerStatus[msg.sender]) {
            revert CallerNotCreditManagerException();
        }
        _;
    }

    /// @notice Constructor
    /// @param _addressProvider Address of the address provider
    /// @param _delay Delay for scheduled withdrawals
    constructor(address _addressProvider, uint40 _delay) ACLTrait(_addressProvider) {
        _setWithdrawalDelay(_delay);
    }

    /// --------------------- ///
    /// IMMEDIATE WITHDRAWALS ///
    /// --------------------- ///

    /// @inheritdoc IWithdrawalManager
    function addImmediateWithdrawal(address account, address token, uint256 amount)
        external
        override
        creditManagerOnly
    {
        _addImmediateWithdrawal(account, token, amount);
    }

    /// @inheritdoc IWithdrawalManager
    function claimImmediateWithdrawal(address token, address to) external override {
        _claimImmediateWithdrawal(msg.sender, token, to);
    }

    /// @dev Increases `account`'s immediately withdrawable balance of `token` by `amount`
    function _addImmediateWithdrawal(address account, address token, uint256 amount) internal {
        if (amount > 1) {
            immediateWithdrawals[account][token] += amount;
            emit AddImmediateWithdrawal(account, token, amount);
        }
    }

    /// @dev Sends all `account`'s immediately withdrawable balance of `token` to `to`
    function _claimImmediateWithdrawal(address account, address token, address to) internal {
        uint256 amount = immediateWithdrawals[account][token];
        if (amount < 2) revert NothingToClaimException();
        unchecked {
            --amount;
        }
        immediateWithdrawals[account][token] = 1;
        _safeTransfer(token, to, amount);
        emit ClaimImmediateWithdrawal(account, token, to, amount);
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
    function cancellableScheduledWithdrawals(address creditAccount, CancelAction action)
        external
        view
        override
        returns (address[2] memory tokens, uint256[2] memory amounts)
    {
        ScheduledWithdrawal[2] memory withdrawals = _scheduled[creditAccount];
        (, bool[2] memory cancellable) = withdrawals.getCancellable(action);

        unchecked {
            for (uint8 i; i < 2; ++i) {
                if (cancellable[i]) (tokens[i],, amounts[i]) = withdrawals[i].tokenMaskAndAmount();
            }
        }
    }

    /// @inheritdoc IWithdrawalManager
    function addScheduledWithdrawal(address creditAccount, address token, uint256 amount, uint8 tokenIndex)
        external
        override
        creditManagerOnly
    {
        if (amount < 2) {
            revert AmountCantBeZeroException();
        }
        ScheduledWithdrawal[2] memory withdrawals = _scheduled[creditAccount];
        (bool found, uint8 slot) = withdrawals.findFreeSlot();
        if (!found) revert NoFreeWithdrawalSlotsException();

        uint40 maturity = uint40(block.timestamp) + delay;
        _scheduled[creditAccount][slot] =
            ScheduledWithdrawal({tokenIndex: tokenIndex, token: token, maturity: maturity, amount: amount});
        emit AddScheduledWithdrawal(creditAccount, token, amount, maturity);
    }

    /// @inheritdoc IWithdrawalManager
    function cancelScheduledWithdrawals(address creditAccount, address to, CancelAction action)
        external
        override
        creditManagerOnly
        returns (uint256 tokensToEnable)
    {
        ScheduledWithdrawal[2] memory withdrawals = _scheduled[creditAccount];
        (bool[2] memory scheduled, bool[2] memory cancellable) = withdrawals.getCancellable(action);

        unchecked {
            for (uint8 i; i < 2; ++i) {
                if (scheduled[i]) {
                    if (cancellable[i]) {
                        tokensToEnable |= _cancel(withdrawals[i], creditAccount);
                    } else {
                        _claim(withdrawals[i], creditAccount, to, false);
                    }
                    _scheduled[creditAccount][i] = withdrawals[i];
                }
            }
        }
    }

    /// @inheritdoc IWithdrawalManager
    function claimScheduledWithdrawals(address creditAccount, address to, ClaimAction action)
        external
        override
        creditManagerOnly
        returns (bool)
    {
        ScheduledWithdrawal[2] memory withdrawals = _scheduled[creditAccount];
        bool[2] memory claimable = withdrawals.getClaimable(action);
        if (!(claimable[0] || claimable[1])) revert NothingToClaimException();

        unchecked {
            for (uint8 i; i < 2; ++i) {
                if (claimable[i]) {
                    _claim(withdrawals[i], creditAccount, to, true);
                    _scheduled[creditAccount][i] = withdrawals[i];
                }
            }
        }

        return withdrawals.hasScheduled();
    }

    /// @dev Cancels withdrawal, clears withdrawal in memory
    function _cancel(ScheduledWithdrawal memory withdrawal, address creditAccount)
        internal
        returns (uint256 tokensToEnable)
    {
        (address token, uint256 tokenMask, uint256 amount) = withdrawal.tokenMaskAndAmount();
        withdrawal.clear();
        emit CancelScheduledWithdrawal(creditAccount, token, amount);
        _safeTransfer(token, creditAccount, amount);
        tokensToEnable = tokenMask;
    }

    /// @dev Claims withdrawal, clears withdrawal in memory
    function _claim(ScheduledWithdrawal memory withdrawal, address creditAccount, address to, bool safe) internal {
        (address token,, uint256 amount) = withdrawal.tokenMaskAndAmount();
        withdrawal.clear();
        emit ClaimScheduledWithdrawal(creditAccount, token, to, amount);
        if (safe) {
            _safeTransfer(token, to, amount);
        } else if (!_unsafeTransfer(token, to, amount)) {
            _addImmediateWithdrawal(to, token, amount);
        }
    }

    /// ------------- ///
    /// CONFIGURATION ///
    /// ------------- ///

    /// @inheritdoc IWithdrawalManager
    function setWithdrawalDelay(uint40 _delay) external override configuratorOnly {
        _setWithdrawalDelay(_delay);
    }

    /// @dev Sets new delay for scheduled withdrawals
    function _setWithdrawalDelay(uint40 _delay) internal {
        if (_delay != delay) {
            delay = _delay;
            emit SetWithdrawalDelay(_delay);
        }
    }

    /// @inheritdoc IWithdrawalManager
    function setCreditManagerStatus(address creditManager, bool status) external override configuratorOnly {
        if (creditManagerStatus[creditManager] != status) {
            creditManagerStatus[creditManager] = status;
            emit SetCreditManagerStatus(creditManager, status);
        }
    }
}
