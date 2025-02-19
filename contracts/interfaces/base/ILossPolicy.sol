// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";
import {IStateSerializer} from "./IStateSerializer.sol";

/// @title Loss policy interface
/// @notice Generic interface for a loss policy that dictates conditions under which a bad debt liquidation can proceed.
/// @dev Loss policies must have type `LOSS_POLICY::{POSTFIX}`
interface ILossPolicy is IVersion, IStateSerializer {
    /// @notice Parameters passed to the loss policy
    /// @param totalDebtUSD Account's total debt in USD
    /// @param twvUSD Account's total weighted value in USD
    /// @param extraData Optional field that can be used to pass some off-chain data specific to implementation
    struct Params {
        uint256 totalDebtUSD;
        uint256 twvUSD;
        bytes extraData;
    }

    /// @notice Access mode for loss liquidations
    enum AccessMode {
        Permissionless,
        Permissioned,
        Forbidden
    }

    /// @notice Emitted when the loss policy access mode is set
    event SetAccessMode(AccessMode mode);

    /// @notice Emitted when the loss policy checks are enabled or disabled
    event SetChecksEnabled(bool enabled);

    /// @notice Whether `creditAccount` can be liquidated with loss by `caller`
    function isLiquidatableWithLoss(address creditAccount, address caller, Params calldata params)
        external
        returns (bool);

    /// @notice Returns current access mode
    function accessMode() external view returns (AccessMode);

    /// @notice Returns whether policy checks are enabled
    function checksEnabled() external view returns (bool);

    /// @notice Sets access mode for loss liquidations
    function setAccessMode(AccessMode mode) external;

    /// @notice Enables or disables policy checks
    function setChecksEnabled(bool enabled) external;
}
