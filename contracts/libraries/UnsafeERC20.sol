// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title UnsafeERC20 library
library UnsafeERC20 {
    /// @dev Same as OpenZeppelin's `safeTransfer`, but, instead of reverting, returns `false` when transfer fails
    function unsafeTransfer(IERC20 token, address to, uint256 amount) internal returns (bool success) {
        return _unsafeCall(address(token), abi.encodeCall(IERC20.transfer, (to, amount))); // U:[UE-1]
    }

    /// @dev Same as OpenZeppelin's `safeTransferFrom`, but, instead of reverting, returns `false` when transfer fails
    function unsafeTransferFrom(IERC20 token, address from, address to, uint256 amount)
        internal
        returns (bool success)
    {
        return _unsafeCall(address(token), abi.encodeCall(IERC20.transferFrom, (from, to, amount))); // U:[UE-2]
    }

    /// @dev Executes call to a function that returns either boolean value indicating call success or nothing
    ///      Returns `true` if call is successful (didn't revert, didn't return false) or `false` otherwise
    function _unsafeCall(address addr, bytes memory data) private returns (bool) {
        (bool success, bytes memory returndata) = addr.call(data);
        return success && (returndata.length == 0 || abi.decode(returndata, (bool)));
    }
}
