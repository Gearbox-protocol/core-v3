// SPDX-License-Identifier: BUSL-1.1
// Gearbox. Generalized leverage protocol that allows to take leverage and then use it across other DeFi protocols and platforms in a composable way.
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICreditManagerV2} from "../interfaces/ICreditManagerV2.sol";

import {IWithdrawManager, CancellationType} from "../interfaces/IWithdrawManager.sol";

// LIBS & TRAITS
import {BitMask} from "../libraries/BitMask.sol";
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

/// We keep token index to keep 2 slots structure
struct WithdrawRequest {
    uint8 tokenIndex;
    address to;
    uint40 availableAt;
    uint256 amount;
}

struct WithdrawPush {
    address creditManager;
    address creditAccount;
}

/// @title WithdrawManager
/// @dev A contract used to enable successful liquidations when the borrower is blacklisted
///      while simultaneously allowing them to recover their funds under a different address
contract WithdrawManager is IWithdrawManager, ACLNonReentrantTrait {
    using SafeERC20 for IERC20;
    using BitMask for uint256;

    mapping(address => bool) public isSupportedCreditManager;

    /// @dev mapping from token => to => amount available to claim
    mapping(address => mapping(address => uint256)) public claimable;

    /// @dev mapping from creditManager => creditAccount => WithdrawRequest[2] to keep 2 requests for withdraw
    mapping(address => mapping(address => WithdrawRequest[2])) public delayed;

    uint40 public delay;

    /// @dev Contract version
    uint256 public constant override version = 3_00;

    /// @dev Restricts calls to Credit Facades only
    modifier creditManagerOnly() {
        if (!isSupportedCreditManager[msg.sender]) {
            revert CallerNotCreditFacadeException();
        }
        _;
    }

    /// TODO: add CM   to list

    /// @param _addressProvider Address of the address provider

    constructor(address _addressProvider) ACLNonReentrantTrait(_addressProvider) {}

    /// @dev Increases the token balance available to claim by the account
    /// @param token Underlying to increase balance for
    /// @param to Account to increase balance for
    /// @param amount Incremented amount
    /// @notice Can only be called by Credit Facades when liquidating a blacklisted borrower
    ///         Expects the token to be transferred directly to this contract in the same transaction
    function addImmediateWithdrawal(
        address to,
        address token,
        uint256 amount // add check amount >0
    ) external override creditManagerOnly {
        claimable[token][to] += amount;
        emit IncreaseClaimableBalance(token, to, amount);
    }

    function addDelayedWithdrawal(address creditAccount, address to, address token, uint256 tokenMask, uint256 amount)
        external
        override
        creditManagerOnly
    {
        (bool hasFreeSlot, uint256 slot) = _push(msg.sender, creditAccount, false, false);
        if (!hasFreeSlot) {
            revert NoFreeQithdrawalSlotsException();
        }

        uint40 availableAt = uint40(block.timestamp) + delay;

        uint8 tokenIndex = tokenMask.calcIndex();

        delayed[msg.sender][creditAccount][slot] =
            WithdrawRequest({tokenIndex: tokenIndex, amount: amount, to: to, availableAt: availableAt});

        emit ScheduleDelayedWithdrawal(to, token, amount, availableAt);
    }

    /// @dev Transfer the sender's current claimable balance in token to a specified address
    /// @param token Underlying to transfer
    /// @param to Recipient address
    function claim(address token, address to) external override {
        uint256 amount = claimable[token][msg.sender];
        if (amount < 2) {
            revert NothingToClaimException();
        }
        claimable[token][msg.sender] = 0;
        IERC20(token).safeTransfer(to, amount);
        emit Claim(token, msg.sender, to, amount);
    }

    function push(address creditManager, address creditAccount) external {
        _push(creditManager, creditAccount, false, true);
    }

    function _push(address creditManager, address creditAccount, bool pushBeforeDeadline, bool clearFlag)
        internal
        returns (bool hasFreeSlot, uint256 slot)
    {
        WithdrawRequest[2] storage reqs = delayed[creditManager][creditAccount];
        bool isFreeSlot1 = _pushRequest(creditManager, reqs[0], pushBeforeDeadline);
        bool isFreeSlot2 = _pushRequest(creditManager, reqs[1], pushBeforeDeadline);

        hasFreeSlot = isFreeSlot1 || isFreeSlot2;
        slot = isFreeSlot1 ? 0 : 1;

        if (clearFlag && isFreeSlot1 && isFreeSlot2) {
            ICreditManagerV2(creditManager).disableWithdrawalFlag(creditAccount);
        }
    }

    function _pushRequest(address creditManager, WithdrawRequest storage req, bool pushBeforeDeadline)
        internal
        returns (bool free)
    {
        if (req.availableAt <= 1) {
            return true;
        }
        if (pushBeforeDeadline || req.availableAt > block.timestamp) {
            address token = _executeWithdrawal(creditManager, req, req.to);
            emit PayDelayedWithdrawal(req.to, token, req.amount);
            return true;
        }

        return false;
    }

    function _executeWithdrawal(address creditManager, WithdrawRequest storage req, address to)
        internal
        returns (address token)
    {
        (token,) = ICreditManagerV2(creditManager).collateralTokensByMask(1 << req.tokenIndex);
        IERC20(token).safeTransfer(to, req.amount);
        req.availableAt = 1;
        req.amount = 1;
    }

    function _returnWithdrawal(WithdrawRequest storage req, address creditManager, address creditAccount)
        internal
        returns (uint256 tokensToEnable)
    {
        if (req.availableAt > 1) {
            address token = _executeWithdrawal(creditManager, req, creditAccount);
            tokensToEnable = 1 << req.tokenIndex;
            emit CancelDelayedWithdrawal(req.to, token, req.amount);
        }
    }

    function cancelWithdrawals(address creditAccount, CancellationType ctype)
        external
        override
        creditManagerOnly
        returns (uint256 tokensToEnable)
    {
        if (ctype == CancellationType.PUSH_WITHDRAWALS) {
            _push(msg.sender, creditAccount, true, false);
        } else {
            WithdrawRequest[2] storage reqs = delayed[msg.sender][creditAccount];
            tokensToEnable |= _returnWithdrawal(reqs[0], msg.sender, creditAccount);
            tokensToEnable |= _returnWithdrawal(reqs[1], msg.sender, creditAccount);
        }
    }

    function pushAndClaim(WithdrawPush[] calldata pushes) external {
        uint256 len = pushes.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                _push(pushes[i].creditManager, pushes[i].creditAccount, false, true);
            }
        }
    }
}
