// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

/// @title Phantom token interface
/// @notice Broadly speaking, by saying "phantom" we imply that token is not transferable. In Gearbox, we use such tokens
///         to track balances of non-tokenized positions in integrated protocols to allow those to be used as collateral.
interface IPhantomToken {
    /// @notice Returns phantom token's target contract and deposited token
    function getPhantomTokenInfo() external view returns (address target, address depositedToken);
}

/// @title Phantom token withdrawer interface
/// @notice Though only the `balanceOf()` function is needed for token to serve as collateral, some services can suffer
///         from its non-transferability, including liquidators or bots that don't have permissions for external calls.
///         To mitigate this, phantom token withdrawals from credit accounts automatically start with withdrawal of
///         deposited token from the integrated protocol via an adapter call defined by this interface.
/// @dev While theoretically possible, we assume that phantom tokens can't be nested
interface IPhantomTokenWithdrawer {
    /// @notice Withdraws phantom token for its deposited token
    function withdrawPhantomToken(address token, uint256 amount) external returns (bool useSafePrices);
}
