// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {CreditAccount} from "../credit/CreditAccount.sol";
import {ACLTrait} from "../traits/ACLTrait.sol";

import {IAccountFactory} from "../interfaces/IAccountFactory.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

import "forge-std/console.sol";

/// @title Disposable credit accounts factory
contract AccountFactoryV2 is IAccountFactory, ACLTrait, ContractsRegisterTrait {
    /// @dev Address of master credit account for cloning
    mapping(address => address) public masterCreditAccounts;

    /// @dev Contract version
    uint256 public constant version = 3_00;

    error MasterCreditAccountAlreadyDeployed();

    /// @param addressProvider Address of address repository
    constructor(address addressProvider) ACLTrait(addressProvider) ContractsRegisterTrait(addressProvider) {}

    /// @dev Provides a new credit account to a Credit Manager
    /// @return creditAccount Address of credit account
    function takeCreditAccount(uint256, uint256) external override returns (address creditAccount) {
        address masterCreditAccount = _getMasterCreditAccountOrRevert();
        // Create a new credit account if there are none in stock
        creditAccount = Clones.clone(masterCreditAccount); // T:[AF-2]

        // emit InitializeCreditAccount(result, msg.sender); // T:[AF-5]
    }

    function returnCreditAccount(address usedAccount) external override {
        // Do nothing for disposable CA
    }

    // CONFIGURATION

    function addCreditManager(address creditManager)
        external
        configuratorOnly
        registeredCreditManagerOnly(creditManager)
    {
        if (masterCreditAccounts[creditManager] != address(0)) {
            revert MasterCreditAccountAlreadyDeployed();
        }

        masterCreditAccounts[creditManager] = address(new CreditAccount(creditManager));
    }

    function _getMasterCreditAccountOrRevert() internal view returns (address masterCA) {
        masterCA = masterCreditAccounts[msg.sender];
        console.log(msg.sender);
        console.log(masterCA);
        if (masterCA == address(0)) {
            revert CallerNotCreditManagerException();
        }
    }
}
