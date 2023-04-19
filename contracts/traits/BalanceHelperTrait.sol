// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title BalanceHelperTrait
/// @notice Saves size by providing internal call for balanceOf
abstract contract BalanceHelperTrait {
    function _balanceOf(address token, address holder) internal view returns (uint256) {
        return IERC20(token).balanceOf(holder);
    }
}
