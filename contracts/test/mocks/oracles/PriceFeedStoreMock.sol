/*
// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IUpdatablePriceFeed} from "../../../interfaces/base/IPriceFeed.sol";
import {IPriceFeedStore, PriceUpdate} from "../../../interfaces/base/IPriceFeedStore.sol";

contract PriceFeedStoreMock is IPriceFeedStore {
    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "PRICE_FEED_STORE::MOCK";

    mapping(address => uint32) internal _stalenessPeriods;

    function setStalenessPeriod(address priceFeed, uint32 stalenessPeriod) external {
        _stalenessPeriods[priceFeed] = stalenessPeriod;
    }

    function getStalenessPeriod(address priceFeed) external view returns (uint32) {
        return _stalenessPeriods[priceFeed];
    }

    function updatePrices(PriceUpdate[] calldata updates) external {
        for (uint256 i; i < updates.length; i++) {
            IUpdatablePriceFeed(updates[i].priceFeed).updatePrice(updates[i].data);
        }
    }
}
*/
