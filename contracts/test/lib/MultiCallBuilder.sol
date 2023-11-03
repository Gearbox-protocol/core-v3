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

    function build(MultiCall memory call1, MultiCall memory call2, MultiCall memory call3, MultiCall memory call4)
        internal
        pure
        returns (MultiCall[] memory calls)
    {
        calls = new MultiCall[](4);
        calls[0] = call1;
        calls[1] = call2;
        calls[2] = call3;
        calls[3] = call4;
    }

    function build(
        MultiCall memory call1,
        MultiCall memory call2,
        MultiCall memory call3,
        MultiCall memory call4,
        MultiCall memory call5
    ) internal pure returns (MultiCall[] memory calls) {
        calls = new MultiCall[](5);
        calls[0] = call1;
        calls[1] = call2;
        calls[2] = call3;
        calls[3] = call4;
        calls[4] = call5;
    }

    function build(
        MultiCall memory call1,
        MultiCall memory call2,
        MultiCall memory call3,
        MultiCall memory call4,
        MultiCall memory call5,
        MultiCall memory call6
    ) internal pure returns (MultiCall[] memory calls) {
        calls = new MultiCall[](6);
        calls[0] = call1;
        calls[1] = call2;
        calls[2] = call3;
        calls[3] = call4;
        calls[4] = call5;
        calls[5] = call6;
    }
}
