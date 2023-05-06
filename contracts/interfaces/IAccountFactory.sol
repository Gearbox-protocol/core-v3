// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

enum TakeAccountAction {
    TAKE_USED_ONE,
    DEPLOY_NEW_ONE
}

interface IAccountFactoryEvents {
    /// @dev Emits when a new Credit Account is created
    event DeployCreditAccount(address indexed creditAccount);

    event ReuseCreditAccount(address indexed creditAccount);

    event ReturnCreditAccount(address indexed creditAccount);

    event AddCreditManager(address indexed creditManager);
}

interface IAccountFactory is IAccountFactoryEvents, IVersion {
    /// @dev Provides a new credit account to a Credit Manager
    function takeCreditAccount(uint256, uint256) external returns (address);

    /// @dev Retrieves the Credit Account from the Credit Manager and adds it to the stock
    /// @param usedAccount Address of returned credit account
    function returnCreditAccount(address usedAccount) external;
}
