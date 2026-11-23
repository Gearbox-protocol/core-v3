// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;
pragma abicoder v1;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {CreditAccountV3} from "../credit/CreditAccountV3.sol";
import {CreditManagerV3} from "../credit/CreditManagerV3.sol";
import {IDefaultAccountFactoryV3} from "../interfaces/IDefaultAccountFactoryV3.sol";
import {
    CallerNotCreditManagerException,
    MasterCreditAccountAlreadyDeployedException,
    CreditAccountIsInUseException
} from "../interfaces/IExceptions.sol";
import {IAddressProvider} from "../interfaces/base/IAddressProvider.sol";

import {AP_INSTANCE_MANAGER_PROXY, NO_VERSION_CONTROL} from "../libraries/Constants.sol";

/// @title Default account factory V3
/// @notice Credit accounts factory.
///         - Account deployment is cheap thanks to the clones proxy pattern
///         - Each take deploys a new credit account
contract DefaultAccountFactoryV3 is Ownable, IDefaultAccountFactoryV3 {
    /// @notice Contract version
    uint256 public constant override version = 3_11;

    /// @notice Contract type
    bytes32 public constant override contractType = "ACCOUNT_FACTORY::DEFAULT";

    /// @dev Mapping credit manager => master credit account used for cloning
    mapping(address => address) internal _masterCreditAccounts;

    /// @notice Constructor
    /// @param addressProvider_ Address provider contract address
    constructor(address addressProvider_) {
        transferOwnership(
            IAddressProvider(addressProvider_).getAddressOrRevert(AP_INSTANCE_MANAGER_PROXY, NO_VERSION_CONTROL)
        );
    }

    /// @notice Empty state serialization
    function serialize() external view override returns (bytes memory) {}

    /// @notice Deploys a new credit account for the calling credit manager
    /// @return creditAccount Address of the provided credit account
    /// @dev Parameters are ignored and only kept for backward compatibility
    /// @custom:expects Credit manager sets account's borrower to non-zero address after calling this function
    function takeCreditAccount(uint256, uint256) external override returns (address creditAccount) {
        address masterCreditAccount = _masterCreditAccounts[msg.sender];
        if (masterCreditAccount == address(0)) {
            revert CallerNotCreditManagerException(); // U:[AF-1]
        }

        creditAccount = Clones.clone(masterCreditAccount); // U:[AF-2]
        emit DeployCreditAccount({creditAccount: creditAccount, creditManager: msg.sender}); // U:[AF-2]
        emit TakeCreditAccount({creditAccount: creditAccount, creditManager: msg.sender}); // U:[AF-2]
    }

    /// @dev Account reuse is no longer supported, so this function is a no-op.
    function returnCreditAccount(address) external pure virtual override {}

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Adds a credit manager to the factory and deploys the master credit account for it
    /// @param creditManager Credit manager address
    function addCreditManager(address creditManager) external override {
        if (_masterCreditAccounts[creditManager] != address(0)) {
            revert MasterCreditAccountAlreadyDeployedException(); // U:[AF-4A]
        }
        address masterCreditAccount = address(new CreditAccountV3(creditManager)); // U:[AF-4B]
        _masterCreditAccounts[creditManager] = masterCreditAccount; // U:[AF-4B]
        emit AddCreditManager(creditManager, masterCreditAccount); // U:[AF-4B]
    }

    /// @notice Executes function call from the account to the target contract with provided data,
    ///         can only be called by configurator when account is not in use by anyone.
    ///         Allows to rescue funds that were accidentally left on the account upon closure.
    /// @param creditAccount Credit account to execute the call from
    /// @param target Contract to call
    /// @param data Data to call the target contract with
    function rescue(address creditAccount, address target, bytes calldata data)
        external
        override
        onlyOwner // U:[AF-1]

    {
        address creditManager = CreditAccountV3(creditAccount).creditManager();

        (,,,,,,, address borrower) = CreditManagerV3(creditManager).creditAccountInfo(creditAccount);
        if (borrower != address(0)) {
            revert CreditAccountIsInUseException(); // U:[AF-5A]
        }

        CreditAccountV3(creditAccount).rescue(target, data); // U:[AF-5B]
        emit Rescue(creditAccount, target, data); // U:[AF-5B]
    }
}
