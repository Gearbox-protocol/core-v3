// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;
pragma abicoder v1;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

import {ICreditAccountV3} from "../interfaces/ICreditAccountV3.sol";
import {CallerNotAccountFactoryException, CallerNotCreditManagerException} from "../interfaces/IExceptions.sol";

/// @title Credit account V3
contract CreditAccountV3 is ICreditAccountV3 {
    using SafeERC20 for IERC20;
    using Address for address;

    /// @inheritdoc IVersion
    uint256 public constant version = 3_00;

    /// @inheritdoc ICreditAccountV3
    address public immutable factory;

    /// @inheritdoc ICreditAccountV3
    address public immutable creditManager;

    /// @dev Ensures that function caller is account factory
    modifier factoryOnly() {
        if (msg.sender != factory) {
            revert CallerNotAccountFactoryException();
        }
        _;
    }

    /// @dev Ensures that function caller is credit manager
    modifier creditManagerOnly() {
        if (msg.sender != creditManager) {
            revert CallerNotCreditManagerException();
        }
        _;
    }

    /// @notice Constructor
    /// @param _creditManager Credit manager to connect this account to
    constructor(address _creditManager) {
        creditManager = _creditManager; // U:[CA-1]
        factory = msg.sender; // U:[CA-1]
    }

    /// @inheritdoc ICreditAccountV3
    function safeTransfer(address token, address to, uint256 amount)
        external
        creditManagerOnly // U:[CA-2]
    {
        IERC20(token).safeTransfer(to, amount); // U:[CA-3]
    }

    /// @inheritdoc ICreditAccountV3
    function execute(address target, bytes memory data)
        external
        creditManagerOnly // U:[CA-2]
        returns (bytes memory result)
    {
        result = target.functionCall(data); // U:[CA-4]
    }

    /// @inheritdoc ICreditAccountV3
    function rescue(address target, bytes memory data)
        external
        override
        factoryOnly // U:[CA-2]
    {
        target.functionCall(data); // U:[CA-5]
    }
}
