// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IERC20HelperTrait
/// @notice Saves contract size by providing internal calls for ERC20 with some extra functionality
library IERC20Helper {
    /// @dev Returns the balance of an address in a token
    /// @param token Token to compute balance for
    /// @param holder Address to compute balance for
    function balanceOf(address token, address holder) internal view returns (uint256) {
        return IERC20(token).balanceOf(holder);
    }

    /// @dev Performs an ERC20 `transfer` that handles non-standard tokens and returns false on transfer failure
    /// @param token Token to transfer
    /// @param to Address to transfer to
    /// @param amount Amount to transfer
    function unsafeTransfer(IERC20 token, address to, uint256 amount) internal returns (bool success) {
        return _unsafeCall(address(token), abi.encodeCall(IERC20.transfer, (to, amount)));
    }

    /// @dev Performs an ERC20 `transferFrom` that handles non-standard tokens and returns false on transfer failure
    /// @param token Token to transfer
    /// @param from Address to transfer from
    /// @param to Address to transfer to
    /// @param amount Amount to transfer
    function unsafeTransferFrom(IERC20 token, address from, address to, uint256 amount)
        internal
        returns (bool success)
    {
        return _unsafeCall(address(token), abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
    }

    /// @dev Handles external calls that return nothing or a bool value
    /// @param addr Address to call
    /// @param data Data to pass to a call
    function _unsafeCall(address addr, bytes memory data) private returns (bool) {
        (bool success, bytes memory returndata) = addr.call(data);
        return success && (returndata.length == 0 || abi.decode(returndata, (bool)));
    }
}
