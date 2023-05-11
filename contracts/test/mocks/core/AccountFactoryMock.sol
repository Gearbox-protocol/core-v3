// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;
//pragma abicoder v1;

import {IAccountFactory, TakeAccountAction} from "../../../interfaces/IAccountFactory.sol";
import {CreditAccountMock} from "../credit/CreditAccountMock.sol";

// EXCEPTIONS

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

/// @title Disposable credit accounts factory
contract AccountFactoryMock is Test, IAccountFactory {
    /// @dev Contract version
    uint256 public version = 3_00;

    address public usedAccount;
    address public newCreditAccount;

    address public returnedAccount;

    constructor() {
        usedAccount = address(new CreditAccountMock());
        newCreditAccount = makeAddr("NEW_CREDIT_ACCOUNT");

        vm.label(usedAccount, "CREDIT_ACCOUNT");
    }

    function setVersion(uint256 _version) external {
        version = _version;
    }

    /// @dev Provides a new credit account to a Credit Manager
    /// @return creditAccount Address of credit account
    function takeCreditAccount(uint256 deployAction, uint256) external override returns (address creditAccount) {
        return (deployAction == uint256(TakeAccountAction.DEPLOY_NEW_ONE)) ? newCreditAccount : usedAccount;
    }

    function returnCreditAccount(address _usedAccount) external override {
        returnedAccount = _usedAccount;
    }
}
