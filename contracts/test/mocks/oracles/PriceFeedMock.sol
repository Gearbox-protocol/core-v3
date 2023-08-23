// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.10;

import {PriceFeedType} from "@gearbox-protocol/sdk-gov/contracts/PriceFeedType.sol";
import {IPriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";

enum FlagState {
    FALSE,
    TRUE,
    REVERT
}

/// @title Price feed mock
/// @notice Used for test purposes only
contract PriceFeedMock is IPriceFeed {
    PriceFeedType public constant override priceFeedType = PriceFeedType.CHAINLINK_ORACLE;

    int256 private price;
    uint8 public immutable override decimals;

    uint80 internal roundId;
    uint256 startedAt;
    uint256 updatedAt;
    uint80 internal answerInRound;

    FlagState internal _skipPriceCheck;

    bool internal revertOnLatestRound;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        decimals = _decimals;
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

        _skipPriceCheck = FlagState.REVERT;
    }

    function description() external pure override returns (string memory) {
        return "price oracle";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function setPrice(int256 newPrice) external {
        price = newPrice;
    }

    function latestRoundData()
        external
        view
        override
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

    // function priceFeedType() external view override returns (PriceFeedType) {
    //     return _priceFeedType;
    // }

    function skipPriceCheck() external view override returns (bool) {
        return flagState(_skipPriceCheck);
    }

    function flagState(FlagState f) internal pure returns (bool value) {
        if (f == FlagState.REVERT) revert();
        return f == FlagState.TRUE;
    }

    function setSkipPriceCheck(FlagState f) external {
        _skipPriceCheck = f;
    }

    function setRevertOnLatestRound(bool value) external {
        revertOnLatestRound = value;
    }
}
