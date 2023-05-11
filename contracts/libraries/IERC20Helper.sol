// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IERC20HelperTrait
/// @notice Saves size by providing internal call for balanceOf
library IERC20Helper {
    function balanceOf(address token, address holder) internal view returns (uint256) {
        return IERC20(token).balanceOf(holder);
    }

    function unsafeTransfer(IERC20 token, address to, uint256 amount) internal returns (bool success) {
        return _unsafeCall(address(token), abi.encodeCall(IERC20.transfer, (to, amount)));
    }

    function unsafeTransferFrom(IERC20 token, address from, address to, uint256 amount)
        internal
        returns (bool success)
    {
        return _unsafeCall(address(token), abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
    }

    function _unsafeCall(address addr, bytes memory data) private returns (bool) {
        (bool success, bytes memory returndata) = addr.call(data);
        return success && (returndata.length == 0 || abi.decode(returndata, (bool)));
    }
}
