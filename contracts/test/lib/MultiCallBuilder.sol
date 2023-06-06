// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {MultiCall} from "../../interfaces/ICreditFacadeV3.sol";

library MultiCallBuilder {
    function build() internal pure returns (MultiCall[] memory calls) {}

    function build(MultiCall memory call1) internal pure returns (MultiCall[] memory calls) {
        calls = new MultiCall[](1);
        calls[0] = call1;
    }

    function build(MultiCall memory call1, MultiCall memory call2) internal pure returns (MultiCall[] memory calls) {
        calls = new MultiCall[](2);
        calls[0] = call1;
        calls[1] = call2;
    }

    function build(MultiCall memory call1, MultiCall memory call2, MultiCall memory call3)
        internal
        pure
        returns (MultiCall[] memory calls)
    {
        calls = new MultiCall[](3);
        calls[0] = call1;
        calls[1] = call2;
        calls[2] = call3;
    }
}
