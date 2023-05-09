// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "./constants.sol";
import {Test} from "forge-std/Test.sol";

contract TestHelper is Test {
    constructor() {
        vm.label(USER, "USER");
        vm.label(FRIEND, "FRIEND");
        vm.label(LIQUIDATOR, "LIQUIDATOR");
        vm.label(INITIAL_LP, "INITIAL_LP");
        vm.label(DUMB_ADDRESS, "DUMB_ADDRESS");
        vm.label(ADAPTER, "ADAPTER");
    }

    function _testCaseErr(string memory caseName, string memory err) internal pure returns (string memory) {
        return string.concat("\nCase: ", caseName, "\nError: ", err);
    }
}
