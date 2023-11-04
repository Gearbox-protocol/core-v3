// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;
pragma abicoder v1;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {CreditAccountV3} from "../credit/CreditAccountV3.sol";
import {CreditManagerV3} from "../credit/CreditManagerV3.sol";
import {IAccountFactoryV3} from "../interfaces/IAccountFactoryV3.sol";
import {
    CallerNotCreditManagerException,
    CreditAccountIsInUseException,
    MasterCreditAccountAlreadyDeployedException
} from "../interfaces/IExceptions.sol";
import {ACLTrait} from "../traits/ACLTrait.sol";
import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";

/// @dev Struct holding factory and queue params for a credit manager
/// @param masterCreditAccount Address of the contract to clone to create new accounts for the credit manager
/// @param head Index of the next credit account to be taken from the queue in case it's already reusable
/// @param tail Index of the last credit account returned to the queue
struct FactoryParams {
    address masterCreditAccount;
    uint40 head;
    uint40 tail;
}

/// @dev Struct holding queued credit account address and timestamp after which it becomes reusable
struct QueuedAccount {
    address creditAccount;
    uint40 reusableAfter;
}

/// @title Account factory V3
/// @notice Reusable credit accounts factory.
///         - Account deployment is cheap thanks to the clones proxy pattern
///         - Accounts are reusable: new accounts are only deployed when the queue of reusable accounts is empty
///           (a separate queue is maintained for each credit manager)
///         - When account is returned to the factory, it is only added to the queue after a certain delay, which
///           allows DAO to rescue funds that might have been accidentally left upon account closure, and serves
///           as protection against potential attacks involving reopening an account right after closing it
contract AccountFactoryV3 is IAccountFactoryV3, ACLTrait, ContractsRegisterTrait {
    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice Delay after which returned credit accounts can be reused
    uint40 public constant override delay = 3 days;

    /// @dev Mapping credit manager => factory params
    mapping(address => FactoryParams) internal _factoryParams;

    /// @dev Mapping (credit manager, index) => queued account
    mapping(address => mapping(uint256 => QueuedAccount)) internal _queuedAccounts;

    /// @notice Constructor
    /// @param addressProvider Address provider contract address
    constructor(address addressProvider) ACLTrait(addressProvider) ContractsRegisterTrait(addressProvider) {}

    /// @notice Provides a reusable credit account from the queue to the credit manager.
    ///         If there are no accounts that can be reused in the queue, deploys a new one.
    /// @return creditAccount Address of the provided credit account
    /// @dev Parameters are ignored and only kept for backward compatibility
    /// @custom:expects Credit manager sets account's borrower to non-zero address after calling this function
    function takeCreditAccount(uint256, uint256) external override returns (address creditAccount) {
        FactoryParams storage fp = _factoryParams[msg.sender];

        address masterCreditAccount = fp.masterCreditAccount;
        if (masterCreditAccount == address(0)) {
            revert CallerNotCreditManagerException(); // U:[AF-1]
        }

        uint256 head = fp.head;
        if (head == fp.tail || block.timestamp < _queuedAccounts[msg.sender][head].reusableAfter) {
            creditAccount = Clones.clone(masterCreditAccount); // U:[AF-2A]
            emit DeployCreditAccount({creditAccount: creditAccount, creditManager: msg.sender}); // U:[AF-2A]
        } else {
            creditAccount = _queuedAccounts[msg.sender][head].creditAccount; // U:[AF-2B]
            delete _queuedAccounts[msg.sender][head]; // U:[AF-2B]
            unchecked {
                ++fp.head; // U:[AF-2B]
            }
        }

        emit TakeCreditAccount({creditAccount: creditAccount, creditManager: msg.sender}); // U:[AF-2A,2B]
    }

    /// @notice Returns a used credit account to the queue
    /// @param creditAccount Address of the returned credit account
    /// @custom:expects Credit account is connected to the calling credit manager
    /// @custom:expects Credit manager sets account's borrower to zero-address before calling this function
    function returnCreditAccount(address creditAccount) external override {
        FactoryParams storage fp = _factoryParams[msg.sender];

        if (fp.masterCreditAccount == address(0)) {
            revert CallerNotCreditManagerException(); // U:[AF-1]
        }

        _queuedAccounts[msg.sender][fp.tail] =
            QueuedAccount({creditAccount: creditAccount, reusableAfter: uint40(block.timestamp) + delay}); // U:[AF-3]
        unchecked {
            ++fp.tail; // U:[AF-3]
        }
        emit ReturnCreditAccount({creditAccount: creditAccount, creditManager: msg.sender}); // U:[AF-3]
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Adds a credit manager to the factory and deploys the master credit account for it
    /// @param creditManager Credit manager address
    function addCreditManager(address creditManager)
        external
        override
        configuratorOnly // U:[AF-1]
        registeredCreditManagerOnly(creditManager) // U:[AF-4A]
    {
        if (_factoryParams[creditManager].masterCreditAccount != address(0)) {
            revert MasterCreditAccountAlreadyDeployedException(); // U:[AF-4B]
        }
        address masterCreditAccount = address(new CreditAccountV3(creditManager)); // U:[AF-4C]
        _factoryParams[creditManager].masterCreditAccount = masterCreditAccount; // U:[AF-4C]
        emit AddCreditManager(creditManager, masterCreditAccount); // U:[AF-4C]
    }

    /// @notice Executes function call from the account to the target contract with provided data,
    ///         can only be called by configurator when account is not in use by anyone.
    ///         Allows to rescue funds that were accidentally left on the account upon closure.
    /// @param creditAccount Credit account to execute the call from
    /// @param target Contract to call
    /// @param data Data to call the target contract with
    function rescue(address creditAccount, address target, bytes calldata data)
        external
        configuratorOnly // U:[AF-1]
    {
        address creditManager = CreditAccountV3(creditAccount).creditManager();
        _ensureRegisteredCreditManager(creditManager); // U:[AF-5A]

        (,,,,,,, address borrower) = CreditManagerV3(creditManager).creditAccountInfo(creditAccount);
        if (borrower != address(0)) {
            revert CreditAccountIsInUseException(); // U:[AF-5B]
        }

        CreditAccountV3(creditAccount).rescue(target, data); // U:[AF-5C]

        emit Rescue(creditAccount, target, data);
    }
}
