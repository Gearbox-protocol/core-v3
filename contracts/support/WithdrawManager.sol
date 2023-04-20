// SPDX-License-Identifier: BUSL-1.1
// Gearbox. Generalized leverage protocol that allows to take leverage and then use it across other DeFi protocols and platforms in a composable way.
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICreditManagerV2} from "../interfaces/ICreditManagerV2.sol";

import {IWithdrawManager, ClaimAvailability, CancellationType} from "../interfaces/IWithdrawManager.sol";
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

struct WithdrawRequest {
    address token;
    uint256 amount;
    address to;
    uint40 availableAt;
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
    /// @dev mapping from address to supported Credit Facade status

    mapping(address => bool) public isSupportedCreditManager;

    /// @dev mapping from token => holder => amount available to claim
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

    /// @param _addressProvider Address of the address provider

    constructor(address _addressProvider) ACLNonReentrantTrait(_addressProvider) {}

    /// @dev Increases the underlying balance available to claim by the account
    /// @param underlying Underlying to increase balance for
    /// @param holder Account to increase balance for
    /// @param amount Incremented amount
    /// @notice Can only be called by Credit Facades when liquidating a blacklisted borrower
    ///         Expects the underlying to be transferred directly to this contract in the same transaction
    function addWithdrawal(
        address creditAccount,
        address holder,
        address underlying,
        uint256 amount, // add check amount >0
        ClaimAvailability availability
    ) external override creditManagerOnly {
        if (availability == ClaimAvailability.IMMEDIATE) {
            _addImmediateClaimable(holder, underlying, amount);
        } else {
            _addDelayedClaimable(msg.sender, creditAccount, holder, underlying, amount);
        }
    }

    function _addImmediateClaimable(address holder, address underlying, uint256 amount) internal {
        claimable[underlying][holder] += amount;
        emit IncreaseClaimableBalance(underlying, holder, amount);
    }

    function _addDelayedClaimable(
        address creditManager,
        address creditAccount,
        address to,
        address token,
        uint256 amount
    ) internal {
        (bool hasFreeSlot, uint256 slot) = _push(creditManager, creditAccount, false, false);
        if (!hasFreeSlot) {
            revert NoFreeQithdrawalSlotsException();
        }

        uint40 availableAt = uint40(block.timestamp) + delay;

        delayed[creditManager][creditAccount][slot] =
            WithdrawRequest({token: token, amount: amount, to: to, availableAt: availableAt});

        // emit IncreaseClaimableBalance(underlying, holder, amount);
    }

    /// @dev Transfer the sender's current claimable balance in underlying to a specified address
    /// @param underlying Underlying to transfer
    /// @param to Recipient address
    function claim(address underlying, address to) external override {
        uint256 amount = claimable[underlying][msg.sender];
        if (amount < 2) {
            revert NothingToClaimException();
        }
        claimable[underlying][msg.sender] = 0;
        IERC20(underlying).safeTransfer(to, amount);
        emit Claim(underlying, msg.sender, to, amount);
    }

    function push(address creditManager, address creditAccount) external {
        _push(creditManager, creditAccount, false, true);
    }

    function _push(address creditManager, address creditAccount, bool pushBeforeDeadline, bool clearFlag)
        internal
        returns (bool hasFreeSlot, uint256 slot)
    {
        WithdrawRequest[2] storage reqs = delayed[creditManager][creditAccount];
        bool isFreeSlot1 = _pushRequest(reqs[0], pushBeforeDeadline);
        bool isFreeSlot2 = _pushRequest(reqs[1], pushBeforeDeadline);

        hasFreeSlot = isFreeSlot1 || isFreeSlot2;
        slot = isFreeSlot1 ? 0 : 1;

        if (clearFlag && isFreeSlot1 && isFreeSlot2) {
            ICreditManagerV2(creditManager).disableWithdrawalFlag(creditAccount);
        }
    }

    function _pushRequest(WithdrawRequest storage req, bool pushBeforeDeadline) internal returns (bool free) {
        if (req.availableAt <= 1) {
            return true;
        }
        if (pushBeforeDeadline || req.availableAt > block.timestamp) {
            IERC20(req.token).safeTransfer(req.to, req.amount);
            req.availableAt = 1;
            req.amount = 1;
            return true;
        }

        return false;
    }

    function _executeWithdrawal(WithdrawRequest storage req, address to) internal {
        IERC20(req.token).safeTransfer(to, req.amount);
        req.availableAt = 1;
        req.amount = 1;
    }

    function _returnWithdrawal(WithdrawRequest storage req, address creditManager, address creditAccount)
        internal
        returns (uint256 tokensToEnable)
    {
        if (req.availableAt > 1) {
            _executeWithdrawal(req, creditAccount);
            tokensToEnable = ICreditManagerV2(creditManager).getTokenMaskOrRevert(req.token);
        }
        // EVENT HERE
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

    function pushAndClaim(address[] calldata tokens, WithdrawPush[] calldata pushes, address to) external {}
}
