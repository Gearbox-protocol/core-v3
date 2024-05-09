// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {PriceFeedType} from "@gearbox-protocol/sdk-gov/contracts/PriceFeedType.sol";
import {IVersion} from "./IVersion.sol";

/// @title Price feed interface
interface IPriceFeed is IVersion {
    function priceFeedType() external view returns (PriceFeedType);

    function skipPriceCheck() external view returns (bool);

    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// @title Updatable price feed interface
interface IUpdatablePriceFeed is IPriceFeed {
    function updatable() external view returns (bool);

    function updatePrice(bytes calldata data) external;
}
