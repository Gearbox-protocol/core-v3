// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;
pragma abicoder v1;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ICreditAccountBase} from "../../../interfaces/ICreditAccountV3.sol";

interface CreditAccountMockEvents {
    event TransferCall(address token, address to, uint256 amount);

    event ExecuteCall(address destination, bytes data);
}

contract CreditAccountMock is ICreditAccountBase, CreditAccountMockEvents {
    using Address for address;

    address public creditManager;

    // Contract version
    uint256 public constant version = 3_00;

    bytes public return_executeResult;

    mapping(address => mapping(address => bool)) public revertsOnTransfer;

    function setRevertOnTransfer(address token, address to) external {
        revertsOnTransfer[token][to] = true;
    }

    function safeTransfer(address token, address to, uint256 amount) external {
        if (revertsOnTransfer[token][to]) {
            revert("Token transfer reverted");
        }

        if (token.isContract()) IERC20(token).transfer(to, amount);
        emit TransferCall(token, to, amount);
    }

    function execute(address destination, bytes memory data) external returns (bytes memory) {
        emit ExecuteCall(destination, data);
        return return_executeResult;
    }

    function setReturnExecuteResult(bytes calldata _result) external {
        return_executeResult = _result;
    }
}
