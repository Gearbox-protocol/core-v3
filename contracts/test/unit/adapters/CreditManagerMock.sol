// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

interface CreditManagerMockEvents {
    event Approve(address token, uint256 amount);
    event Execute();
}

contract CreditManagerMock is CreditManagerMockEvents {
    address public addressProvider;
    address public creditFacade;

    address public getExternalCallCreditAccountOrRevert;
    mapping(address => uint256) public getTokenMaskOrRevert;

    bytes _result;

    constructor(address _addressProvider, address _creditFacade) {
        addressProvider = _addressProvider;
        creditFacade = _creditFacade;
    }

    function approveCreditAccount(address token, uint256 amount) external {
        emit Approve(token, amount);
    }

    function executeOrder(bytes memory) external returns (bytes memory result) {
        emit Execute();
        return _result;
    }

    function setExternalCallCreditAccount(address creditAccount) external {
        getExternalCallCreditAccountOrRevert = creditAccount;
    }

    function setMask(address token, uint256 mask) external {
        getTokenMaskOrRevert[token] = mask;
    }

    function setExecuteOrderResult(bytes memory result) external {
        _result = result;
    }
}
