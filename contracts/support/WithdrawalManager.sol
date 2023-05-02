// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {
    CallerNotCreditManagerException,
    NoFreeWithdrawalSlotsException,
    NothingToClaimException
} from "../interfaces/IExceptions.sol";
import {IWithdrawalManager, IVersion, ScheduledWithdrawal} from "../interfaces/IWithdrawalManager.sol";
import {Withdrawals} from "../libraries/Withdrawals.sol";
import {ACLTrait} from "../traits/ACLTrait.sol";

/// @title Withdrawal manager
/// @notice Contract that handles withdrawals from credit accounts.
///         There are two kinds of withdrawals: immediate and scheduled.
///         - Immediate withdrawals can be claimed, well, immediately, and exist to support liquidation of accounts
///           whose owners are blacklisted in credit manager's underlying.
///         - Scheduled withdrawals can be claimed after a certain delay, and exist to support partial withdrawals
///           from credit accounts. One credit account can have up to two immature withdrawals at the same time.
///           Additional rules for scheduled withdrawals:
///           + if account is closed, both mature and immature withdrawals are claimed
///           + if account is liquidated, immature withdrawals are cancelled and mature ones are claimed
///           + if account is liquidated in emergency mode, both mature and immature withdrawals are cancelled
///           + in emergency mode, claiming is disabled
contract WithdrawalManager is IWithdrawalManager, ACLTrait {
    using SafeERC20 for IERC20;
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

    /// @dev Mapping credit manager => credit account => scheduled withdrawals
    mapping(address => mapping(address => ScheduledWithdrawal[2])) private _scheduled;

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
        immediateWithdrawals[account][token] += amount;
        emit AddImmediateWithdrawal(account, token, amount);
    }

    /// @inheritdoc IWithdrawalManager
    function claimImmediateWithdrawal(address token, address to) external override {
        uint256 amount = immediateWithdrawals[msg.sender][token];
        if (amount < 2) revert NothingToClaimException();
        unchecked {
            --amount;
        }
        immediateWithdrawals[msg.sender][token] = 1;
        IERC20(token).safeTransfer(to, amount);
        emit ClaimImmediateWithdrawal(msg.sender, token, to, amount);
    }

    /// --------------------- ///
    /// SCHEDULED WITHDRAWALS ///
    /// --------------------- ///

    /// @inheritdoc IWithdrawalManager
    function scheduledWithdrawals(address creditManager, address creditAccount)
        external
        view
        override
        returns (ScheduledWithdrawal[2] memory)
    {
        return _scheduled[creditManager][creditAccount];
    }

    /// @inheritdoc IWithdrawalManager
    function cancellableScheduledWithdrawals(address creditManager, address creditAccount)
        external
        view
        override
        returns (uint256[2] memory tokenMasks, uint256[2] memory amounts)
    {
        ScheduledWithdrawal[2] memory withdrawals = _scheduled[creditManager][creditAccount];
        (bool[2] memory initialized, bool[2] memory claimable) =
            withdrawals.status({isEmergency: _isEmergency(creditManager), forceClaim: false});

        unchecked {
            for (uint8 i; i < 2; ++i) {
                if (initialized[i] && !claimable[i]) (tokenMasks[i], amounts[i]) = withdrawals[i].tokenMaskAndAmount();
            }
        }
    }

    /// @inheritdoc IWithdrawalManager
    function claimableScheduledWithdrawals(address creditManager, address creditAccount)
        external
        view
        override
        returns (uint256[2] memory tokenMasks, uint256[2] memory amounts)
    {
        ScheduledWithdrawal[2] memory withdrawals = _scheduled[creditManager][creditAccount];
        (, bool[2] memory claimable) = withdrawals.status({isEmergency: _isEmergency(creditManager), forceClaim: false});

        unchecked {
            for (uint8 i; i < 2; ++i) {
                if (claimable[i]) (tokenMasks[i], amounts[i]) = withdrawals[i].tokenMaskAndAmount();
            }
        }
    }

    /// @inheritdoc IWithdrawalManager
    function addScheduledWithdrawal(address creditAccount, address token, address to, uint256 amount, uint8 tokenIndex)
        external
        override
        creditManagerOnly
    {
        ScheduledWithdrawal[2] memory withdrawals = _scheduled[msg.sender][creditAccount];
        (bool found, bool claim, uint8 slot) = withdrawals.findFreeSlot();
        if (!found) revert NoFreeWithdrawalSlotsException();
        if (claim) _executeWithdrawal(msg.sender, creditAccount, withdrawals[slot], true);

        uint40 maturity = uint40(block.timestamp) + delay;
        _scheduled[msg.sender][creditAccount][slot] =
            ScheduledWithdrawal({tokenIndex: tokenIndex, to: to, maturity: maturity, amount: amount});
        emit AddScheduledWithdrawal(creditAccount, token, to, amount, maturity);
    }

    /// @inheritdoc IWithdrawalManager
    function cancelScheduledWithdrawals(address creditAccount, bool forceClaim)
        external
        override
        creditManagerOnly
        returns (uint256 tokensToEnable)
    {
        ScheduledWithdrawal[2] memory withdrawals = _scheduled[msg.sender][creditAccount];
        (bool[2] memory initialized, bool[2] memory claimable) =
            withdrawals.status({isEmergency: _isEmergency(msg.sender), forceClaim: forceClaim});

        unchecked {
            for (uint8 i; i < 2; ++i) {
                if (initialized[i]) {
                    tokensToEnable |= _executeWithdrawal(msg.sender, creditAccount, withdrawals[i], claimable[i]);
                    _scheduled[msg.sender][creditAccount][i] = withdrawals[i];
                }
            }
        }
    }

    /// @inheritdoc IWithdrawalManager
    function claimScheduledWithdrawals(address creditManager, address creditAccount) external override {
        ScheduledWithdrawal[2] memory withdrawals = _scheduled[creditManager][creditAccount];
        (, bool[2] memory claimable) = withdrawals.status({isEmergency: _isEmergency(creditManager), forceClaim: false});
        if (!(claimable[0] || claimable[1])) revert NothingToClaimException();

        unchecked {
            for (uint8 i; i < 2; ++i) {
                if (claimable[i]) {
                    _executeWithdrawal(creditManager, creditAccount, withdrawals[i], true);
                    _scheduled[creditManager][creditAccount][i] = withdrawals[i];
                }
            }
        }

        if (withdrawals.bothSlotsEmpty()) {
            ICreditManagerV3(creditManager).disableWithdrawalFlag(creditAccount);
        }
    }

    /// @dev Claims or cancels scheduled withdrawal, clears withdrawal slot in memory
    function _executeWithdrawal(
        address creditManager,
        address creditAccount,
        ScheduledWithdrawal memory withdrawal,
        bool isClaim
    ) internal returns (uint256 tokensToEnable) {
        (uint256 tokenMask, uint256 amount) = withdrawal.tokenMaskAndAmount();
        (address token,) = ICreditManagerV3(creditManager).collateralTokensByMask(tokenMask);

        address to = isClaim ? withdrawal.to : creditAccount;
        // FIXME: this might fail if `to` is blacklisted in `token`
        // this might cause issues during non-emergency liquidations
        IERC20(token).safeTransfer(to, amount);

        if (isClaim) {
            emit ClaimScheduledWithdrawal(creditAccount, token, to, amount);
        } else {
            tokensToEnable = tokenMask;
            emit CancelScheduledWithdrawal(creditAccount, token, amount);
        }

        withdrawal.clear();
    }

    /// @dev Returns true if facade connected to a given credit manager is paused
    function _isEmergency(address creditManager) internal view returns (bool) {
        return Pausable(ICreditManagerV3(creditManager).creditFacade()).paused();
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
