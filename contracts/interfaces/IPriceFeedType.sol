// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {PriceFeedType} from "@gearbox-protocol/integration-types/contracts/PriceFeedType.sol";

interface IPriceFeedType {
    /// @notice Price feed type
    function priceFeedType() external view returns (PriceFeedType);

    /// @notice Whether sanity checks on price feed result should be skipped
    function skipPriceCheck() external view returns (bool);
}
