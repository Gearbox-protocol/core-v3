// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;
pragma abicoder v1;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ICreditAccount} from "../../../interfaces/ICreditAccount.sol";

interface CreditAccountMockEvents {
    event TransferCall(address token, address to, uint256 amount);

    event ExecuteCall(address destination, bytes data);
}

contract CreditAccountMock is ICreditAccount, CreditAccountMockEvents {
    using Address for address;

    address public creditManager;

    // Contract version
    uint256 public constant version = 3_00;

    bytes public return_executeResult;

    mapping(address => uint8) public revertsOnTransfer;

    function setRevertOnTransfer(address token, uint8 times) external {
        revertsOnTransfer[token] = times;
    }

    function safeTransfer(address token, address to, uint256 amount) external {
        if (revertsOnTransfer[token] > 0) {
            revertsOnTransfer[token]--;
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
