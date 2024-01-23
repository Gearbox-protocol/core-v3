// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {PriceFeedType} from "@gearbox-protocol/sdk-gov/contracts/PriceFeedType.sol";
import {IPriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";

enum FlagState {
    FALSE,
    TRUE,
    REVERT
}

contract PriceFeedOnDemandMock {
    PriceFeedType public constant priceFeedType = PriceFeedType.REDSTONE_ORACLE;

    int256 private price;
    uint8 public immutable decimals;

    uint80 internal roundId;
    uint256 startedAt;
    uint256 updatedAt;
    uint80 internal answerInRound;

    FlagState internal _skipPriceCheck;

    constructor() {
        price = 100000000;
        decimals = 8;
        roundId = 80;
        answerInRound = 80;
        // set to quite far in the future
        startedAt = block.timestamp + 36500 days;
        updatedAt = block.timestamp + 36500 days;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80, // roundId,
            int256, // answer,
            uint256, // startedAt,
            uint256, // updatedAt,
            uint80 //answeredInRound
        )
    {
        return (roundId, price, startedAt, updatedAt, answerInRound);
    }

    function updatePrice(bytes calldata data) external {}
}
