// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";

struct PriceUpdate {
    address priceFeed;
    bytes data;
}

interface IPriceFeedStore {
    function getStalenessPeriod(address priceFeed) external view returns (uint32);
    function updatePrices(PriceUpdate[] calldata updates) external;
}
