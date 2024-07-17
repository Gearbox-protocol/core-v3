// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {CreditAccountV3} from "../credit/CreditAccountV3.sol";
import {IAccountFactoryV3} from "../interfaces/IAccountFactoryV3.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {
    CallerNotCreditManagerException,
    CreditAccountIsInUseException,
    CreditManagerNotAddedException,
    MasterCreditAccountAlreadyDeployedException
} from "../interfaces/IExceptions.sol";

/// @dev   Struct holding factory and queue params for a credit manager
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

/// @title  Account factory V3
/// @notice Reusable credit accounts factory.
///         - Account deployment is cheap thanks to the clones proxy pattern.
///         - Accounts are reusable: new accounts are only deployed when the queue of reusable accounts is empty
///         (a separate queue is maintained for each credit manager).
///         - When account is returned to the factory, it is only added to the queue after a certain delay, which
///         allows DAO to rescue funds that might have been accidentally left upon account closure, and serves
///         as protection against potential attacks involving reopening an account right after closing it.
contract AccountFactoryV3 is IAccountFactoryV3, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Contract type
    bytes32 public constant override contractType = "AF";

    /// @notice Delay after which returned credit accounts can be reused
    uint40 public constant override delay = 3 days;

    /// @dev Set of added credit managers
    EnumerableSet.AddressSet internal _creditManagersSet;

    /// @dev Mapping credit manager => factory params
    mapping(address => FactoryParams) internal _factoryParams;

    /// @dev Mapping (credit manager, index) => queued account
    mapping(address => mapping(uint256 => QueuedAccount)) internal _queuedAccounts;

    /// @dev Ensures that function can only be called by added credit managers
    modifier creditManagerOnly() {
        _revertIfCallerIsNotCreditManager();
        _;
    }

    /// @notice Constructor
    /// @param  owner_ Contract owner
    /// @dev    Reverts if `owner_` is zero address
    constructor(address owner_) {
        transferOwnership(owner_);
    }

    /// @notice Whether `creditManager` is added
    function isCreditManagerAdded(address creditManager) external view returns (bool) {
        return _creditManagersSet.contains(creditManager);
    }

    /// @notice Returns the list of added credit managers
    function creditManagers() external view override returns (address[] memory) {
        return _creditManagersSet.values();
    }

    /// @notice Provides a reusable credit account from the queue to the credit manager.
    ///         If there are no accounts that can be reused in the queue, deploys a new one.
    /// @return creditAccount Address of the provided credit account
    /// @dev    Parameters are ignored and only kept for backward compatibility
    /// @dev    Reverts if caller is not an added credit manager
    /// @custom:expects Credit manager sets account's borrower to non-zero address after calling this function
    /// @custom:tests U:[AF-1], U:[AF-2A], U:[AF-2B]
    function takeCreditAccount(uint256, uint256) external override creditManagerOnly returns (address creditAccount) {
        FactoryParams storage fp = _factoryParams[msg.sender];

        uint256 head = fp.head;
        if (head == fp.tail || block.timestamp < _queuedAccounts[msg.sender][head].reusableAfter) {
            creditAccount = Clones.clone(fp.masterCreditAccount);
            emit DeployCreditAccount({creditAccount: creditAccount, creditManager: msg.sender});
        } else {
            creditAccount = _queuedAccounts[msg.sender][head].creditAccount;
            delete _queuedAccounts[msg.sender][head];
            unchecked {
                ++fp.head;
            }
        }
        emit TakeCreditAccount({creditAccount: creditAccount, creditManager: msg.sender});
    }

    /// @notice Returns a used credit account to the queue
    /// @param  creditAccount Address of the returned credit account
    /// @dev    Reverts if caller is not an added credit manager
    /// @custom:expects Credit account is connected to the calling credit manager
    /// @custom:expects Credit manager sets account's borrower to zero-address before calling this function
    /// @custom:tests U:[AF-1], U:[AF-3]
    function returnCreditAccount(address creditAccount) external override creditManagerOnly {
        FactoryParams storage fp = _factoryParams[msg.sender];
        _queuedAccounts[msg.sender][fp.tail] =
            QueuedAccount({creditAccount: creditAccount, reusableAfter: uint40(block.timestamp) + delay});
        unchecked {
            ++fp.tail;
        }
        emit ReturnCreditAccount({creditAccount: creditAccount, creditManager: msg.sender});
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Adds a credit manager to the factory and deploys the master credit account for it
    /// @param  creditManager Credit manager address
    /// @dev    Reverts if caller is not owner
    /// @dev    Reverts if credit manager is already added
    /// @custom:tests U:[AF-1], U:[AF-4A], U:[AF-4B]
    function addCreditManager(address creditManager) external override onlyOwner {
        if (_factoryParams[creditManager].masterCreditAccount != address(0)) {
            revert MasterCreditAccountAlreadyDeployedException();
        }
        address masterCreditAccount = address(new CreditAccountV3(creditManager));
        _factoryParams[creditManager].masterCreditAccount = masterCreditAccount;
        _creditManagersSet.add(creditManager);
        emit AddCreditManager({creditManager: creditManager, masterCreditAccount: masterCreditAccount});
    }

    /// @notice Executes function call from the account to the target contract with provided data.
    ///         Allows to rescue funds that were accidentally left on the account upon closure.
    /// @param  creditAccount Credit account to execute the call from
    /// @param  target Contract to call
    /// @param  data Data to call the target contract with
    /// @dev    Reverts if caller is not owner
    /// @dev    Reverts if account's credit manager is not added
    /// @dev    Reverts if account has non-zero borrower in its credit manager
    /// @custom:tests U:[AF-1], U:[AF-5A], U:[AF-5B]
    function rescue(address creditAccount, address target, bytes calldata data) external override onlyOwner {
        address creditManager = CreditAccountV3(creditAccount).creditManager();
        if (!_creditManagersSet.contains(creditManager)) revert CreditManagerNotAddedException();

        if (ICreditManagerV3(creditManager).creditAccountInfo(creditAccount).borrower != address(0)) {
            revert CreditAccountIsInUseException();
        }

        CreditAccountV3(creditAccount).rescue(target, data);
        emit Rescue({creditAccount: creditAccount, target: target, data: data});
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Reverts if `msg.sender` is not an added credit manager
    function _revertIfCallerIsNotCreditManager() internal view {
        if (!_creditManagersSet.contains(msg.sender)) revert CallerNotCreditManagerException();
    }
}
