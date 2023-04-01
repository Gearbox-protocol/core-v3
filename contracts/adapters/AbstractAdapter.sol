// SPDX-License-Identifier: GPL-2.0-or-later
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IAddressProvider} from "@gearbox-protocol/core-v2/contracts/interfaces/IAddressProvider.sol";
import {ICreditManagerV2} from "../interfaces/ICreditManagerV2.sol";
import {IPool4626} from "../interfaces/IPool4626.sol";
import "../interfaces/IExceptions.sol";

/// @title Abstract adapter
/// @dev Inheriting adapters MUST use provided internal functions to perform all operations with credit accounts
abstract contract AbstractAdapter is IAdapter, ACLNonReentrantTrait {
    /// @notice Credit Manager the adapter is connected to
    ICreditManagerV2 public immutable override creditManager;

    /// @notice Address provider
    IAddressProvider public immutable override addressProvider;

    /// @notice Address of the contract the adapter is interacting with
    address public immutable override targetContract;

    /// @notice Constructor
    /// @param _creditManager Credit Manager to connect this adapter to
    /// @param _targetContract Address of the contract this adapter should interact with
    constructor(address _creditManager, address _targetContract)
        ACLNonReentrantTrait(address(IPool4626(ICreditManagerV2(_creditManager).pool()).addressProvider()))
        nonZeroAddress(_targetContract) // F: [AA-2]
    {
        creditManager = ICreditManagerV2(_creditManager); // F: [AA-1]
        addressProvider = IAddressProvider(IPool4626(creditManager.pool()).addressProvider()); // F: [AA-1]
        targetContract = _targetContract; // F: [AA-1]
    }

    /// @dev Reverts if the caller of the function is not the Credit Facade
    /// @dev Adapter functions are only allowed to be called from within the multicall
    ///      Since at this point Credit Account is owned by the Credit Facade, all functions
    ///      of inheriting adapters that perform actions on account MUST have this modifier
    modifier creditFacadeOnly() {
        if (msg.sender != _creditFacade()) {
            revert CallerNotCreditFacadeException(); // F: [AA-5]
        }
        _;
    }

    /// @dev Returns the Credit Facade connected to the Credit Manager
    function _creditFacade() internal view returns (address) {
        return creditManager.creditFacade(); // F: [AA-3]
    }

    /// @dev Returns the Credit Account currently owned by the Credit Facade
    /// @dev Inheriting adapters MUST use this function to find the account address
    function _creditAccount() internal view returns (address) {
        return creditManager.getCreditAccountOrRevert(_creditFacade()); // F: [AA-4]
    }

    /// @dev Returns collateral token mask of given token in the Credit Manager
    /// @param token Token to get the mask for
    /// @return tokenMask Collateral token mask
    /// @dev Reverts if token is not registered as collateral token in the Credit Manager
    function _getMaskOrRevert(address token) internal view returns (uint256 tokenMask) {
        tokenMask = creditManager.tokenMasksMap(token); // F: [AA-6]
        if (tokenMask == 0) {
            revert TokenNotAllowedException(); // F: [AA-6]
        }
    }

    /// @dev Approves the target contract to spend given token from the Credit Account
    /// @param token Token to be approved
    /// @param amount Amount to be approved
    /// @dev Reverts if token is not registered as collateral token in the Credit Manager
    function _approveToken(address token, uint256 amount) internal {
        creditManager.approveCreditAccount(targetContract, token, amount); // F: [AA-7, AA-8]
    }

    /// @dev Enables a token in the Credit Account
    /// @param token Address of the token to enable
    /// @dev Reverts if token is not registered as collateral token in the Credit Manager
    function _enableToken(address token) internal {
        creditManager.checkAndEnableToken(token); // F: [AA-7, AA-9]
    }

    /// @dev Disables a token in the Credit Account
    /// @param token Address of the token to disable
    function _disableToken(address token) internal {
        creditManager.disableToken(token); // F: [AA-7, AA-10]
    }

    /// @dev Changes enabled tokens in the Credit Account
    /// @param tokensToEnable Bitmask of tokens that should be enabled
    /// @param tokensToDisable Bitmask of tokens that should be disabled
    /// @dev This function might be useful for adapters that work with limited set of tokens, whose masks can be
    ///      determined in the adapter constructor, thus saving gas by avoiding querying them during execution
    ///      and combining multiple enable/disable operations into a single one
    function _changeEnabledTokens(uint256 tokensToEnable, uint256 tokensToDisable) internal {
        creditManager.changeEnabledTokens(tokensToEnable, tokensToDisable); // F: [AA-7, AA-11]
    }

    /// @dev Executes an arbitrary call from the Credit Account to the target contract
    /// @param callData Data to call the target contract with
    /// @return result Call output
    function _execute(bytes memory callData) internal returns (bytes memory result) {
        return creditManager.executeOrder(targetContract, callData); // F: [AA-7, AA-12]
    }

    /// @dev Executes a swap operation on the target contract from the Credit Account
    ///      without explicit approval to spend `tokenIn`
    /// @param tokenIn The token that the call is expected to spend
    /// @param tokenOut The token that the call is expected to produce
    /// @param callData Data to call the target contract with
    /// @param disableTokenIn Whether the input token should be disabled afterwards
    ///        (for operations that spend the entire balance)
    /// @return result Call output
    /// @dev Reverts if tokenIn or tokenOut are not registered as collateral in the Credit Manager
    function _executeSwapNoApprove(address tokenIn, address tokenOut, bytes memory callData, bool disableTokenIn)
        internal
        returns (bytes memory result)
    {
        _getMaskOrRevert(tokenIn); // F: [AA-15]
        result = _executeSwap(tokenIn, tokenOut, callData, disableTokenIn); // F: [AA-7, AA-13]
    }

    /// @dev Executes a swap operation on the target contract from the Credit Account
    ///      with maximal `tokenIn` allowance, and then sets the allowance to 1
    /// @param tokenIn The token that the call is expected to spend
    /// @param tokenOut The token that the call is expected to produce
    /// @param callData Data to call the target contract with
    /// @param disableTokenIn Whether the input token should be disabled afterwards
    ///        (for operations that spend the entire balance)
    /// @return result Call output
    /// @dev Reverts if tokenIn or tokenOut are not registered as collateral in the Credit Manager
    function _executeSwapSafeApprove(address tokenIn, address tokenOut, bytes memory callData, bool disableTokenIn)
        internal
        returns (bytes memory result)
    {
        _approveToken(tokenIn, type(uint256).max); // F: [AA-14, AA-15]
        result = _executeSwap(tokenIn, tokenOut, callData, disableTokenIn); // F: [AA-7, AA-14]
        _approveToken(tokenIn, 1); // F: [AA-14]
    }

    /// @dev Implementation of `_executeSwap...` operations
    /// @dev Kept private as only the internal wrappers are intended to be used
    ///      by inheritors
    function _executeSwap(address tokenIn, address tokenOut, bytes memory callData, bool disableTokenIn)
        private
        returns (bytes memory result)
    {
        result = _execute(callData); // F: [AA-13, AA-14]
        if (disableTokenIn) {
            _disableToken(tokenIn); // F: [AA-13, AA-14]
        }
        _enableToken(tokenOut); // F: [AA-13, AA-14, AA-15]
    }
}
