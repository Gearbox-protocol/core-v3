// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;
pragma abicoder v1;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICreditAccount} from "../interfaces/ICreditAccount.sol";

import "../interfaces/IExceptions.sol";

/// @title Credit AccountV3
contract CreditAccountV3 is ICreditAccount {
    using SafeERC20 for IERC20;
    using Address for address;
    /// @dev Address of the currently connected Credit Manager

    address public immutable creditManager;

    // Contract version
    uint256 public constant version = 3_00;

    /// @dev Restricts operations to the connected Credit Manager only
    modifier creditManagerOnly() {
        if (msg.sender != creditManager) {
            revert CallerNotCreditManagerException();
        }
        _;
    }

    constructor(address _creditManager) {
        creditManager = _creditManager;
    }

    /// @dev Transfers tokens from the credit account to a provided address. Restricted to the current Credit Manager only.
    /// @param token Token to be transferred from the Credit Account.
    /// @param to Address of the recipient.
    /// @param amount Amount to be transferred.
    function safeTransfer(address token, address to, uint256 amount)
        external
        creditManagerOnly // T:[CA-2]
    {
        IERC20(token).safeTransfer(to, amount); // T:[CA-6]
    }

    /// @dev Executes a call to a 3rd party contract with provided data. Restricted to the current Credit Manager only.
    /// @param destination Contract address to be called.
    /// @param data Data to call the contract with.
    function execute(address destination, bytes memory data) external creditManagerOnly returns (bytes memory) {
        return destination.functionCall(data); // T: [CM-48]
    }
}
