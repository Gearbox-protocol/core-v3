// SPDX-License-Identifier: BUSL-1.1
// Gearbox. Generalized leverage protocol that allows to take leverage and then use it across other DeFi protocols and platforms in a composable way.
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

struct WithdrawRequest {
    uint256 tokenMask;
    uint256 amount;
    uint40 availableAt;
}

/// @title WithdrawManager
/// @dev A contract used to enable successful liquidations when the borrower is blacklisted
///      while simultaneously allowing them to recover their funds under a different address
contract WithdrawManager is ACLNonReentrantTrait {
    /// @dev mapping from address to supported Credit Facade status
    mapping(address => bool) public isSupportedCreditManager;

    /// @dev mapping from (underlying, account) to amount available to claim
    mapping(address => mapping(address => uint256)) public claimable;

    /// @dev Contract version
    // uint256 public constant override version = 3_00;

    /// @dev Restricts calls to Credit Facades only
    modifier creditManagerOnly() {
        if (!isSupportedCreditManager[msg.sender]) {
            revert CallerNotCreditFacadeException();
        }
        _;
    }

    /// @param _addressProvider Address of the address provider

    constructor(address _addressProvider) ACLNonReentrantTrait(_addressProvider) {}
}
