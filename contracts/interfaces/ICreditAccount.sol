// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

interface ICreditAccount is IVersion {
    /// @dev Transfers tokens from the credit account to a provided address. Restricted to the current Credit Manager only.
    /// @param token Token to be transferred from the Credit Account.
    /// @param to Address of the recipient.
    /// @param amount Amount to be transferred.
    function safeTransfer(address token, address to, uint256 amount) external;

    /// @dev Executes a call to a 3rd party contract with provided data. Restricted to the current Credit Manager only.
    /// @param destination Contract address to be called.
    /// @param data Data to call the contract with.
    function execute(address destination, bytes memory data) external returns (bytes memory);

    /// @dev Returns the address of the currently connected Credit Manager
    function creditManager() external view returns (address);
}
