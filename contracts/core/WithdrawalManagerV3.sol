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
import {ETH_ADDRESS, IWithdrawalManagerV3} from "../interfaces/IWithdrawalManagerV3.sol";
import {UnsafeERC20} from "../libraries/UnsafeERC20.sol";
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

    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice WETH token address
    address public immutable override weth;

    /// @notice Mapping account => token => claimable amount
    mapping(address => mapping(address => uint256)) public override immediateWithdrawals;

    /// @notice Mapping from address to its status as an approved credit manager
    mapping(address => bool) public override isValidCreditManager;

    /// @dev Ensures that function caller is one of added credit managers
    modifier creditManagerOnly() {
        _ensureCallerIsCreditManager();
        _;
    }

    /// @notice Constructor
    /// @param _addressProvider Address of the address provider
    constructor(address _addressProvider) ACLTrait(_addressProvider) ContractsRegisterTrait(_addressProvider) {
        weth = IAddressProviderV3(_addressProvider).getAddressOrRevert(AP_WETH_TOKEN, NO_VERSION_CONTROL); // U:[WM-1]
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
        bool isETH = token == ETH_ADDRESS;

        _claimImmediateWithdrawal({account: msg.sender, token: isETH ? weth : token, to: to, unwrapWETH: isETH}); // U:[WM-4B,4C,4D]
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
        if (amount <= 1) return;
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

    // ------------- //
    // CONFIGURATION //
    // ------------- //

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
