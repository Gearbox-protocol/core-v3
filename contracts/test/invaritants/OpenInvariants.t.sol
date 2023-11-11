// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {GearboxInstance} from "./Deployer.sol";
import {Handler} from "./Handler.sol";

import "forge-std/Test.sol";
import "../lib/constants.sol";

contract InvariantGearboxTest is Test {
    GearboxInstance gi;
    Handler handler;

    function setUp() public {
        gi = new GearboxInstance();
        gi._setUp();
        handler = new Handler(gi);
        targetContract(address(handler));
    }

    // function invariant_example() external {}
}
