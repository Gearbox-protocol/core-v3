// SPDX-License-Identifier: GPL-2.0-or-later
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IAddressProvider} from "@gearbox-protocol/core-v2/contracts/interfaces/IAddressProvider.sol";

import {IAdapter} from "../interfaces/IAdapter.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {CallerNotCreditFacadeException} from "../interfaces/IExceptions.sol";
import {IPool4626} from "../interfaces/IPool4626.sol";
import {ACLTrait} from "../traits/ACLTrait.sol";

/// @title Abstract adapter
/// @dev Inheriting adapters MUST use provided internal functions to perform all operations with credit accounts
abstract contract AbstractAdapter is IAdapter, ACLTrait {
    /// @inheritdoc IAdapter
    ICreditManagerV3 public immutable override creditManager;

    /// @inheritdoc IAdapter
    IAddressProvider public immutable override addressProvider;

    /// @inheritdoc IAdapter
    address public immutable override targetContract;

    /// @notice Constructor
    /// @param _creditManager Credit manager to connect the adapter to
    /// @param _targetContract Address of the adapted contract
    constructor(address _creditManager, address _targetContract)
        ACLTrait(address(IPool4626(ICreditManagerV3(_creditManager).pool()).addressProvider())) // U:[AA-1A]
        nonZeroAddress(_targetContract) // U:[AA-1A]
    {
        creditManager = ICreditManagerV3(_creditManager); // U:[AA-1B]
        addressProvider = IAddressProvider(IPool4626(creditManager.pool()).addressProvider()); // U:[AA-1B]
        targetContract = _targetContract; // U:[AA-1B]
    }

    /// @dev Ensures that caller of the function is credit facade connected to the credit manager
    /// @dev Inheriting adapters MUST use this modifier in all external functions that operate on credit accounts
    modifier creditFacadeOnly() {
        if (msg.sender != creditManager.creditFacade()) {
            revert CallerNotCreditFacadeException();
        }
        _;
    }

    /// @dev Ensures that external call credit account is set and returns its address
    function _creditAccount() internal view returns (address) {
        return creditManager.getExternalCallCreditAccountOrRevert(); // U:[AA-2]
    }

    /// @dev Ensures that token is registered as collateral in the credit manager and returns its mask
    function _getMaskOrRevert(address token) internal view returns (uint256 tokenMask) {
        tokenMask = creditManager.getTokenMaskOrRevert(token); // U:[AA-3]
    }

    /// @dev Approves target contract to spend given token from the credit account
    ///      Reverts if external call credit account is not set or token is not registered as collateral
    /// @param token Token to approve
    /// @param amount Amount to approve
    function _approveToken(address token, uint256 amount) internal {
        creditManager.approveCreditAccount(token, amount); // U:[AA-4]
    }

    /// @dev Executes an external call from the credit account to the target contract
    ///      Reverts if external call credit account is not set
    /// @param callData Data to call the target contract with
    /// @return result Call result
    function _execute(bytes memory callData) internal returns (bytes memory result) {
        return creditManager.executeOrder(callData); // U:[AA-5]
    }

    /// @dev Executes a swap operation without input token approval
    ///      Reverts if external call credit account is not set or any of passed tokens is not registered as collateral
    /// @param tokenIn Input token that credit account spends in the call
    /// @param tokenOut Output token that credit account receives after the call
    /// @param callData Data to call the target contract with
    /// @param disableTokenIn Whether `tokenIn` should be disabled after the call
    ///        (for operations that spend the entire account's balance of the input token)
    /// @return tokensToEnable Bit mask of tokens that should be enabled after the call
    /// @return tokensToDisable Bit mask of tokens that should be disabled after the call
    /// @return result Call result
    function _executeSwapNoApprove(address tokenIn, address tokenOut, bytes memory callData, bool disableTokenIn)
        internal
        returns (uint256 tokensToEnable, uint256 tokensToDisable, bytes memory result)
    {
        tokensToEnable = _getMaskOrRevert(tokenOut); // U:[AA-6]
        uint256 tokenInMask = _getMaskOrRevert(tokenIn);
        if (disableTokenIn) tokensToDisable = tokenInMask; // U:[AA-6]
        result = _execute(callData); // U:[AA-6]
    }

    /// @dev Executes a swap operation with maximum input token approval, and revokes approval after the call
    ///      Reverts if external call credit account is not set or any of passed tokens is not registered as collateral
    /// @param tokenIn Input token that credit account spends in the call
    /// @param tokenOut Output token that credit account receives after the call
    /// @param callData Data to call the target contract with
    /// @param disableTokenIn Whether `tokenIn` should be disabled after the call
    ///        (for operations that spend the entire account's balance of the input token)
    /// @return tokensToEnable Bit mask of tokens that should be enabled after the call
    /// @return tokensToDisable Bit mask of tokens that should be disabled after the call
    /// @return result Call result
    /// @custom:expects Credit manager reverts when trying to approve non-collateral token
    function _executeSwapSafeApprove(address tokenIn, address tokenOut, bytes memory callData, bool disableTokenIn)
        internal
        returns (uint256 tokensToEnable, uint256 tokensToDisable, bytes memory result)
    {
        tokensToEnable = _getMaskOrRevert(tokenOut); // U:[AA-7]
        if (disableTokenIn) tokensToDisable = _getMaskOrRevert(tokenIn); // U:[AA-7]
        _approveToken(tokenIn, type(uint256).max); // U:[AA-7]
        result = _execute(callData); // U:[AA-7]
        _approveToken(tokenIn, 1); // U:[AA-7]
    }
}
