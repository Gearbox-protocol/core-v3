/*
// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.10;

contract PriceFeedFallbackMock {
    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "PRICE_FEED_FALLBACK_MOCK";

    int256 public price;
    uint8 public immutable decimals;

    bool public immutable changeStateInFallback;
    bool public fallbackStateFlag;

    uint80 internal roundId;
    uint256 startedAt;
    uint256 updatedAt;
    uint80 internal answerInRound;

    bool internal revertOnLatestRound;

    constructor(int256 _price, uint8 _decimals, bool _changeStateInFallback) {
        price = _price;
        decimals = _decimals;
        changeStateInFallback = _changeStateInFallback;
        roundId = 80;
        answerInRound = 80;
        // set to quite far in the future
        startedAt = block.timestamp + 36500 days;
        updatedAt = block.timestamp + 36500 days;
    }

    function setParams(uint80 _roundId, uint256 _startedAt, uint256 _updatedAt, uint80 _answerInRound) external {
        roundId = _roundId;
        startedAt = _startedAt;
        updatedAt = _updatedAt;
        answerInRound = _answerInRound;
    }

    function description() external pure returns (string memory) {
        return "price oracle";
    }

    function setPrice(int256 newPrice) external {
        price = newPrice;
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
        if (revertOnLatestRound) revert();

        return (roundId, price, startedAt, updatedAt, answerInRound);
    }

    fallback() external {
        if (changeStateInFallback) {
            fallbackStateFlag = true;
        }
    }
}
*/
