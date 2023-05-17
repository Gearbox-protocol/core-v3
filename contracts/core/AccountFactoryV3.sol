// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;
pragma abicoder v1;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

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

struct FactoryParams {
    address masterCreditAccount;
    uint40 head;
    uint40 tail;
}

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
///           allows DAO to rescue funds that might have been accidentally left upon account closure
contract AccountFactoryV3 is IAccountFactoryV3, ACLTrait, ContractsRegisterTrait {
    /// @inheritdoc IVersion
    uint256 public constant override version = 3_00;

    /// @inheritdoc IAccountFactoryV3
    uint40 public constant override delay = 3 days;

    /// @dev Mapping credit manager => factory params
    mapping(address => FactoryParams) internal _factoryParams;

    /// @dev Mapping credit manager => queued accounts
    mapping(address => QueuedAccount[]) internal _queuedAccounts;

    /// @notice Constructor
    /// @param addressProvider Address provider contract address
    constructor(address addressProvider) ACLTrait(addressProvider) ContractsRegisterTrait(addressProvider) {}

    /// @inheritdoc IAccountFactoryV3
    function takeCreditAccount(uint256, uint256) external override returns (address creditAccount) {
        FactoryParams storage fp = _factoryParams[msg.sender];

        address masterCreditAccount = fp.masterCreditAccount;
        if (masterCreditAccount == address(0)) {
            revert CallerNotCreditManagerException();
        }

        uint256 head = fp.head;
        if (head < fp.tail && block.timestamp >= _queuedAccounts[msg.sender][head].reusableAfter) {
            creditAccount = _queuedAccounts[msg.sender][head].creditAccount;
            delete _queuedAccounts[msg.sender][head];
            unchecked {
                ++fp.head;
            }
        } else {
            creditAccount = Clones.clone(masterCreditAccount);
            emit DeployCreditAccount({creditAccount: creditAccount, creditManager: msg.sender});
        }

        emit TakeCreditAccount({creditAccount: creditAccount, creditManager: msg.sender});
    }

    /// @inheritdoc IAccountFactoryV3
    function returnCreditAccount(address creditAccount) external override {
        FactoryParams storage fp = _factoryParams[msg.sender];

        if (fp.masterCreditAccount == address(0)) {
            revert CallerNotCreditManagerException();
        }

        _queuedAccounts[msg.sender][fp.tail] =
            QueuedAccount({creditAccount: creditAccount, reusableAfter: uint40(block.timestamp) + delay});
        unchecked {
            ++fp.tail;
        }
        emit ReturnCreditAccount({creditAccount: creditAccount, creditManager: msg.sender});
    }

    /// ------------- ///
    /// CONFIGURATION ///
    /// ------------- ///

    /// @inheritdoc IAccountFactoryV3
    function addCreditManager(address creditManager)
        external
        override
        configuratorOnly
        registeredCreditManagerOnly(creditManager)
    {
        if (_factoryParams[creditManager].masterCreditAccount != address(0)) {
            revert MasterCreditAccountAlreadyDeployedException();
        }
        address masterCreditAccount = address(new CreditAccountV3(creditManager));
        _factoryParams[creditManager].masterCreditAccount = masterCreditAccount;
        emit AddCreditManager(creditManager, masterCreditAccount);
    }

    /// @inheritdoc IAccountFactoryV3
    function rescue(address creditAccount, address target, bytes calldata data) external configuratorOnly {
        address creditManager = CreditAccountV3(creditAccount).creditManager();
        _checkRegisteredCreditManagerOnly(creditManager);

        (,,,,, address borrower) = CreditManagerV3(creditManager).creditAccountInfo(creditAccount);
        if (borrower != address(0)) {
            revert CreditAccountIsInUseException();
        }

        CreditAccountV3(creditAccount).rescue(target, data);
    }
}
