// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;
pragma abicoder v1;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {CreditAccountV3} from "../credit/CreditAccountV3.sol";
import {IDefaultAccountFactoryV3} from "../interfaces/IDefaultAccountFactoryV3.sol";
import {
    CallerNotCreditManagerException,
    MasterCreditAccountAlreadyDeployedException
} from "../interfaces/IExceptions.sol";

/// @title Default account factory V3
/// @notice Credit accounts factory.
///         - Account deployment is cheap thanks to the clones proxy pattern
///         - Each take deploys a new credit account
contract DefaultAccountFactoryV3 is IDefaultAccountFactoryV3 {
    /// @notice Contract version
    uint256 public constant override version = 3_11;

    /// @notice Contract type
    bytes32 public constant override contractType = "ACCOUNT_FACTORY::DEFAULT";

    /// @dev Mapping credit manager => master credit account used for cloning
    mapping(address => address) internal _masterCreditAccounts;

    /// @notice Constructor
    /// @dev `addressProvider` is unused and retained for deployment ABI compatibility
    constructor(address) {}

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

    /// @dev Account reuse is no longer supported. No-op is kept for `IAccountFactory` / CreditManager compatibility.
    function returnCreditAccount(address) external override {}

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
}
