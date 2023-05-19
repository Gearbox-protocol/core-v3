// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;
pragma abicoder v1;

import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {CreditAccountV3} from "../credit/CreditAccountV3.sol";
import {ACLTrait} from "../traits/ACLTrait.sol";

import {IAccountFactory} from "../interfaces/IAccountFactory.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

/// @dev Struct storing per-CreditManager data on account usage queue
struct CreditManagerFactory {
    /// @dev Address of the contract being cloned to create new Credit Accounts
    address masterCreditAccount;
    /// @dev Id of the next reused Credit Account in the used account queue, i.e.
    ///      the front of the reused CA queue
    uint32 head;
    /// @dev Id of the last returned Credit Account in the used account queue, i.e.
    ///      the back of the reused CA queue
    uint32 tail;
    /// @dev Min used account queue size in order to start reusing accounts
    uint16 minUsedInQueue;
}

/// @title Disposable credit accounts factory
contract AccountFactoryV3 is IAccountFactory, ACLTrait, ContractsRegisterTrait {
    /// @dev Mapping from Credit Manager to their Credit Account queue data
    mapping(address => CreditManagerFactory) public masterCreditAccounts;

    /// @dev Mapping from Credit Manager to their used account queue
    mapping(address => address[]) public usedCreditAccounts;

    /// @dev Contract version
    uint256 public constant version = 3_00;

    /// @param addressProvider Address of address repository
    constructor(address addressProvider) ACLTrait(addressProvider) ContractsRegisterTrait(addressProvider) {}

    /// @dev Provides a new credit account to a Credit Manager
    /// @return creditAccount Address of credit account
    function takeCreditAccount(uint256, uint256) external override returns (address creditAccount) {
        CreditManagerFactory storage cmf = masterCreditAccounts[msg.sender];
        address masterCreditAccount = cmf.masterCreditAccount;

        if (masterCreditAccount == address(0)) {
            revert CallerNotCreditManagerException();
        }

        ///  A used Credit Account is only given to a user if there is a sufficiently
        ///  large number of other accounts opened before it. The minimal number of
        ///  accounts to cycle through before a particular account is reusable is determined
        ///  by minUsedInQueue for each Credit Manager.
        ///  This is done to make it hard for a user to intentionally reopen an account
        ///  that they closed shortly prior, as this can potentially be used as an element
        ///  in an attack.
        uint256 totalUsed = cmf.tail - cmf.head;
        if (totalUsed < cmf.minUsedInQueue) {
            creditAccount = Clones.clone(masterCreditAccount);
            emit DeployCreditAccount(creditAccount);
        } else {
            creditAccount = usedCreditAccounts[msg.sender][cmf.head];
            ++cmf.head;
            emit ReuseCreditAccount(creditAccount);
        }
    }

    /// @dev Returns a Credit Account from the Credit Manager into the used account queue
    /// @param usedAccount Credit Account to return
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

    /// @dev Adds a new Credit Manager to the account factory and initializes its master Credit Account
    /// @param creditManager Address of the CA to add
    /// @param minUsedInQueue Minimal number of opened accounts before a CA is reusable
    function addCreditManager(address creditManager, uint16 minUsedInQueue)
        external
        configuratorOnly
        registeredCreditManagerOnly(creditManager)
    {
        if (masterCreditAccounts[creditManager].masterCreditAccount != address(0)) {
            revert MasterCreditAccountAlreadyDeployed();
        }

        /// As `creditManager` is an immutable field in a Credit Account,
        /// it will be copied as part of the code when the master Credit Account is cloned
        masterCreditAccounts[creditManager] = CreditManagerFactory({
            masterCreditAccount: address(new CreditAccountV3(creditManager)),
            head: 0,
            tail: 0,
            minUsedInQueue: minUsedInQueue
        });

        emit AddCreditManager(creditManager);
    }
}
