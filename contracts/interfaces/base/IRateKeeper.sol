// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";

/// @title Rate keeper interface
/// @notice Generic interface for a contract that can provide rates to the quota keeper
interface IRateKeeper is IVersion {
    /// @notice Pool rates are provided for
    function pool() external view returns (address);

    /// @notice Adds token to the rate keeper
    /// @dev Must add token to the quota keeper in case it's not already there
    function addToken(address token) external;

    /// @notice Whether token is added to the rate keeper
    function isTokenAdded(address token) external view returns (bool);

    /// @notice Returns quota rates for a list of tokens, must return non-zero rates for added tokens
    ///         and revert if some tokens are not recognized
    function getRates(address[] calldata tokens) external view returns (uint16[] memory);
}
