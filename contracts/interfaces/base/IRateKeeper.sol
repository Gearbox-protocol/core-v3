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

    /// @notice Whether token is added to the rate keeper
    function isTokenAdded(address token) external view returns (bool);

    /// @notice Returns quota rates for a list of tokens, must revert for unrecognized tokens
    function getRates(address[] calldata tokens) external view returns (uint16[] memory);
}
