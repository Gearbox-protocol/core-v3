// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;
//pragma abicoder v1;

import {IAccountFactoryV3} from "../../../interfaces/IAccountFactoryV3.sol";
import {CreditAccountMock} from "../credit/CreditAccountMock.sol";

// EXCEPTIONS

import {Test} from "forge-std/Test.sol";

/// @title Disposable credit accounts factory
contract AccountFactoryMock is Test, IAccountFactoryV3 {
    /// @dev Contract version
    uint256 public version;

    bytes32 public constant override contractType = "AF_MOCK";

    address public usedAccount;

    address public returnedAccount;

    constructor(uint256 _version) {
        usedAccount = address(new CreditAccountMock());

        version = _version;
    }

    /// @dev Provides a new credit account to a Credit Manager
    /// @return creditAccount Address of credit account
    function takeCreditAccount(uint256, uint256) external view override returns (address creditAccount) {
        return usedAccount;
    }

    function returnCreditAccount(address creditAccount) external override {
        returnedAccount = creditAccount;
    }

    function delay() external pure override returns (uint40) {}

    function addCreditManager(address) external pure override {}

    function rescue(address, address, bytes calldata) external pure override {}
}
