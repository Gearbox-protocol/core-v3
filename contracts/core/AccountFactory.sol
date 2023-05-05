// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {CreditAccount} from "../credit/CreditAccount.sol";
import {ACLTrait} from "../traits/ACLTrait.sol";

import {IAccountFactory, TakeAccountAction} from "../interfaces/IAccountFactory.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

import "forge-std/console.sol";

struct CreditManagerFactory {
    address masterCreditAccount;
    uint32 head;
    uint32 tail;
    uint16 minUsedInQueue;
}

/// @title Disposable credit accounts factory
contract AccountFactoryV2 is IAccountFactory, ACLTrait, ContractsRegisterTrait {
    /// @dev Address of master credit account for cloning
    mapping(address => CreditManagerFactory) public masterCreditAccounts;

    mapping(address => address[]) public usedCreditAccounts;

    /// @dev Contract version
    uint256 public constant version = 3_00;

    error MasterCreditAccountAlreadyDeployed();

    /// @param addressProvider Address of address repository
    constructor(address addressProvider) ACLTrait(addressProvider) ContractsRegisterTrait(addressProvider) {}

    /// @dev Provides a new credit account to a Credit Manager
    /// @return creditAccount Address of credit account
    function takeCreditAccount(uint256 deployAction, uint256) external override returns (address creditAccount) {
        CreditManagerFactory storage cmf = masterCreditAccounts[msg.sender];
        address masterCreditAccount = cmf.masterCreditAccount;

        if (masterCreditAccount == address(0)) {
            revert CallerNotCreditManagerException();
        }
        uint256 totalUsed = cmf.tail - cmf.head;
        if (totalUsed < cmf.minUsedInQueue || deployAction == uint256(TakeAccountAction.DEPLOY_NEW_ONE)) {
            // Create a new credit account if there are none in stock
            creditAccount = Clones.clone(masterCreditAccount); // T:[AF-2]
            emit DeployCreditAccount(creditAccount);
        } else {
            creditAccount = usedCreditAccounts[msg.sender][cmf.head];
            ++cmf.head;
            emit ReuseCreditAccount(creditAccount);
        }

        // emit InitializeCreditAccount(result, msg.sender); // T:[AF-5]
    }

    function returnCreditAccount(address usedAccount) external override {
        CreditManagerFactory storage cmf = masterCreditAccounts[msg.sender];

        if (cmf.masterCreditAccount == address(0)) {
            revert CallerNotCreditManagerException();
        }

        usedCreditAccounts[msg.sender][cmf.tail] = usedAccount;
        ++cmf.tail;
        emit ReturnCreditAccount(usedAccount);
    }

    // CONFIGURATION

    function addCreditManager(address creditManager, uint16 minUsedInQueue)
        external
        configuratorOnly
        registeredCreditManagerOnly(creditManager)
    {
        if (masterCreditAccounts[creditManager].masterCreditAccount != address(0)) {
            revert MasterCreditAccountAlreadyDeployed();
        }

        masterCreditAccounts[creditManager] = CreditManagerFactory({
            masterCreditAccount: address(new CreditAccount(creditManager)),
            head: 0,
            tail: 0,
            minUsedInQueue: minUsedInQueue
        });

        emit AddCreditManager(creditManager);
    }
}
