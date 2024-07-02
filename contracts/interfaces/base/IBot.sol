// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

/// @title Bot interface
/// @notice Minimal interface contracts must conform to in order to be used as bots in Gearbox V3
/// @dev Since bots might be developed by third-parties, there're no requirements on version or type
interface IBot {
    /// @notice Mask of permissions required for bot operation, see `ICreditFacadeV3Multicall`
    function requiredPermissions() external view returns (uint192);
}
