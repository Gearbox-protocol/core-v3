// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

abstract contract HandlerBase is Test {
    struct Ctx {
        bool skipTime;
        uint256 timeDelta;
    }

    uint256 public immutable initialTimestamp;
    uint256 _maxTimeDelta;

    modifier applyContext(Ctx memory ctx) {
        if (ctx.skipTime) {
            ctx.timeDelta = bound(ctx.timeDelta, 0, _maxTimeDelta);
            vm.warp(block.timestamp + ctx.timeDelta);
        }
        _;
    }

    constructor(uint256 maxTimeDelta) {
        initialTimestamp = block.timestamp;
        _maxTimeDelta = maxTimeDelta;
    }

    function _get(address[] memory array, uint256 index) internal view returns (address) {
        uint256 num = array.length;
        require(num != 0, "HandlerBase: Empty array");
        index = bound(index, 0, num - 1);
        return array[index];
    }
}
