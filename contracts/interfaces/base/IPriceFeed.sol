// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";

/// @title Price feed interface
/// @notice Interface for Chainlink-like price feeds that can be plugged into Gearbox's price oracle
interface IPriceFeed is IVersion {
    /// @notice Whether price feed implements its own staleness and sanity checks
    function skipPriceCheck() external view returns (bool);

    /// @notice Scale decimals of price feed answers
    function decimals() external view returns (uint8);

    /// @notice Price feed description
    function description() external view returns (string memory);

    /// @notice Price feed answer in standard Chainlink format, only `answer` and `updatedAt` fields are used
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// @title Updatable price feed interface
/// @notice Extended version of `IPriceFeed` for pull oracles that allow on-demand updates
interface IUpdatablePriceFeed is IPriceFeed {
    /// @notice Emitted when price is updated
    event UpdatePrice(uint256 price);

    /// @notice Whether price feed is updatable
    function updatable() external view returns (bool);

    /// @notice Performs on-demand price update
    function updatePrice(bytes calldata data) external;
}
