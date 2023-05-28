// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

/// @title Credit account base interface
/// @notice Functions shared accross newer and older versions
interface ICreditAccountBase is IVersion {
    function creditManager() external view returns (address);
    function safeTransfer(address token, address to, uint256 amount) external;
    function execute(address target, bytes memory data) external returns (bytes memory result);
}

/// @title Credit account V3 interface
interface ICreditAccountV3 is ICreditAccountBase {
    /// @notice Account factory this account was deployed with
    function factory() external view returns (address);

    /// @notice Credit manager this account is connected to
    function creditManager() external view override returns (address);

    /// @notice Transfers tokens from the credit account, can only be called by the credit manager
    /// @param token Token to transfer
    /// @param to Transfer recipient
    /// @param amount Amount to transfer
    function safeTransfer(address token, address to, uint256 amount) external override;

    /// @notice Executes function call from the account to the target contract with provided data,
    ///         can only be called by the credit manager
    /// @param target Contract to call
    /// @param data Data to call the target contract with
    /// @return result Call result
    function execute(address target, bytes memory data) external override returns (bytes memory result);

    /// @notice Executes function call from the account to the target contract with provided data,
    ///         can only be called by the factory.
    ///         Allows to rescue funds that were accidentally left on the account upon closure.
    /// @param target Contract to call
    /// @param data Data to call the target contract with
    function rescue(address target, bytes memory data) external;
}
