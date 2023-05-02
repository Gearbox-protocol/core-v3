// SPDX-License-Identifier: GPL-2.0-or-later
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IAddressProvider} from "@gearbox-protocol/core-v2/contracts/interfaces/IAddressProvider.sol";

import {IAdapter} from "../interfaces/IAdapter.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {CallerNotCreditFacadeException} from "../interfaces/IExceptions.sol";
import {IPool4626} from "../interfaces/IPool4626.sol";
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";

/// @title Abstract adapter
/// @dev Inheriting adapters MUST use provided internal functions to perform all operations with credit accounts
abstract contract AbstractAdapter is IAdapter, ACLNonReentrantTrait {
    /// @notice Credit manager the adapter is connected to
    ICreditManagerV3 public immutable override creditManager;

    /// @notice Address provider
    IAddressProvider public immutable override addressProvider;

    /// @notice Address of the adapted contract
    address public immutable override targetContract;

    /// @notice Constructor
    /// @param _creditManager Credit manager to connect this adapter to
    /// @param _targetContract Address of the adapted contract
    constructor(address _creditManager, address _targetContract)
        ACLNonReentrantTrait(address(IPool4626(ICreditManagerV3(_creditManager).pool()).addressProvider())) // F: [AA-1]
        nonZeroAddress(_targetContract) // F: [AA-1]
    {
        creditManager = ICreditManagerV3(_creditManager); // F: [AA-2]
        addressProvider = IAddressProvider(IPool4626(creditManager.pool()).addressProvider()); // F: [AA-2]
        targetContract = _targetContract; // F: [AA-2]
    }

    /// @dev Ensures that function is called by the credit facade
    /// @dev Inheriting adapters MUST use this modifier in all external functions that operate
    ///      on credit accounts to ensure they are called as part of the multicall
    modifier creditFacadeOnly() {
        if (msg.sender != creditManager.creditFacade()) {
            revert CallerNotCreditFacadeException(); // F: [AA-3]
        }
        _;
    }

    /// @dev Returns the credit account that will execute an external call to the target contract
    /// @dev Inheriting adapters MUST use this function to find the address of the account they operate on
    function _creditAccount() internal view returns (address) {
        return creditManager.externalCallCreditAccountOrRevert(); // F: [AA-4]
    }

    /// @dev Checks that token is registered as collateral in the credit manager and returns its mask
    function _getMaskOrRevert(address token) internal view returns (uint256 tokenMask) {
        tokenMask = creditManager.getTokenMaskOrRevert(token); // F: [AA-5]
    }

    /// @dev Approves target contract to spend given token from the credit account
    /// @param token Token to approve
    /// @param amount Amount to approve
    /// @dev Reverts if token is not registered as collateral in the credit manager
    function _approveToken(address token, uint256 amount) internal {
        creditManager.approveCreditAccount(token, amount); // F: [AA-6]
    }

    /// @dev Executes an external call from the credit account to the target contract
    /// @param callData Data to call the target contract with
    /// @return result Call result
    function _execute(bytes memory callData) internal returns (bytes memory result) {
        return creditManager.executeOrder(callData); // F: [AA-7]
    }

    /// @dev Executes a swap operation on the target contract without input token approval
    /// @param tokenIn Input token that credit account spends in the call
    /// @param tokenOut Output token that credit account receives after the call
    /// @param callData Data to call the target contract with
    /// @param disableTokenIn Whether `tokenIn` should be disabled after the call
    ///        (for operations that spend the entire account's balance of the input token)
    /// @return tokensToEnable Bit mask of tokens that should be enabled after the call
    /// @return tokensToDisable Bit mask of tokens that should be disabled after the call
    /// @return result Call result
    /// @dev Reverts if `tokenIn` or `tokenOut` are not registered as collateral in the credit manager
    function _executeSwapNoApprove(address tokenIn, address tokenOut, bytes memory callData, bool disableTokenIn)
        internal
        returns (uint256 tokensToEnable, uint256 tokensToDisable, bytes memory result)
    {
        tokensToEnable = _getMaskOrRevert(tokenOut); // F: [AA-8, AA-10]
        uint256 tokenInMask = _getMaskOrRevert(tokenIn); // F: [AA-10]
        if (disableTokenIn) tokensToDisable = tokenInMask; // F: [AA-8]
        result = _execute(callData); // F: [AA-8]
    }

    /// @dev Executes a swap operation on the target contract with maximum input token approval,
    ///      and resets this approval to 1 after the call
    /// @param tokenIn Input token that credit account spends in the call
    /// @param tokenOut Output token that credit account receives after the call
    /// @param callData Data to call the target contract with
    /// @param disableTokenIn Whether `tokenIn` should be disabled after the call
    ///        (for operations that spend the entire account's balance of the input token)
    /// @return tokensToEnable Bit mask of tokens that should be enabled after the call
    /// @return tokensToDisable Bit mask of tokens that should be disabled after the call
    /// @return result Call result
    /// @dev Reverts if `tokenIn` or `tokenOut` are not registered as collateral in the credit manager
    function _executeSwapSafeApprove(address tokenIn, address tokenOut, bytes memory callData, bool disableTokenIn)
        internal
        returns (uint256 tokensToEnable, uint256 tokensToDisable, bytes memory result)
    {
        tokensToEnable = _getMaskOrRevert(tokenOut); // F: [AA-9, AA-10]
        if (disableTokenIn) tokensToDisable = _getMaskOrRevert(tokenIn); // F: [AA-9, AA-10]
        _approveToken(tokenIn, type(uint256).max); // F: [AA-9, AA-10]
        result = _execute(callData); // F: [AA-9]
        _approveToken(tokenIn, 1); // F: [AA-9]
    }
}
