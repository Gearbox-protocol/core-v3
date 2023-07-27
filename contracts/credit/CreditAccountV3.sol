// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;
pragma abicoder v1;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {ICreditAccountV3} from "../interfaces/ICreditAccountV3.sol";
import {CallerNotAccountFactoryException, CallerNotCreditManagerException} from "../interfaces/IExceptions.sol";

/// @title Credit account V3
contract CreditAccountV3 is ICreditAccountV3 {
    using SafeERC20 for IERC20;
    using Address for address;

    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice Account factory this account was deployed with
    address public immutable override factory;

    /// @notice Credit manager this account is connected to
    address public immutable override creditManager;

    /// @dev Ensures that function caller is account factory
    modifier factoryOnly() {
        if (msg.sender != factory) {
            revert CallerNotAccountFactoryException();
        }
        _;
    }

    /// @dev Ensures that function caller is credit manager
    modifier creditManagerOnly() {
        _revertIfNotCreditManager();
        _;
    }

    /// @dev Reverts if `msg.sender` is not credit manager
    function _revertIfNotCreditManager() internal view {
        if (msg.sender != creditManager) {
            revert CallerNotCreditManagerException();
        }
    }

    /// @notice Constructor
    /// @param _creditManager Credit manager to connect this account to
    constructor(address _creditManager) {
        creditManager = _creditManager; // U:[CA-1]
        factory = msg.sender; // U:[CA-1]
    }

    /// @notice Transfers tokens from the credit account, can only be called by the credit manager
    /// @param token Token to transfer
    /// @param to Transfer recipient
    /// @param amount Amount to transfer
    function safeTransfer(address token, address to, uint256 amount)
        external
        override
        creditManagerOnly // U:[CA-2]
    {
        IERC20(token).safeTransfer(to, amount); // U:[CA-3]
    }

    /// @notice Executes function call from the account to the target contract with provided data,
    ///         can only be called by the credit manager
    /// @param target Contract to call
    /// @param data Data to call the target contract with
    /// @return result Call result
    function execute(address target, bytes calldata data)
        external
        override
        creditManagerOnly // U:[CA-2]
        returns (bytes memory result)
    {
        result = target.functionCall(data); // U:[CA-4]
    }

    /// @notice Executes function call from the account to the target contract with provided data,
    ///         can only be called by the factory.
    ///         Allows to rescue funds that were accidentally left on the account upon closure.
    /// @param target Contract to call
    /// @param data Data to call the target contract with
    function rescue(address target, bytes calldata data)
        external
        override
        factoryOnly // U:[CA-2]
    {
        target.functionCall(data); // U:[CA-5]
    }
}
