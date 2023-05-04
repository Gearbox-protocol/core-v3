// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IERC20HelperTrait
/// @notice Saves size by providing internal call for balanceOf
abstract contract IERC20HelperTrait {
    using SafeERC20 for IERC20;

    function _balanceOf(address token, address holder) internal view returns (uint256) {
        return IERC20(token).balanceOf(holder);
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        IERC20(token).safeTransferFrom(from, to, amount);
    }
}
