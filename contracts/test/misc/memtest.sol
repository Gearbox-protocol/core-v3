// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

struct Together {
    address a;
    uint256 b;
}

contract MemTest is Test {
    function generate_together(uint256 num) internal pure returns (Together[] memory result) {
        result = new Together[](num);
        for (uint256 i; i < num; ++i) {
            result[i] = Together(address(uint160(i)), i);
        }
    }

    function generate_sepatarely(uint256 num) internal pure returns (address[] memory addrs, uint256[] memory uints) {
        addrs = new address[](num);
        uints = new uint256[](num);

        for (uint256 i; i < num; ++i) {
            addrs[i] = address(uint160(i));
            uints[i] = i;
        }
    }

    function test_mem_test() public view {
        uint256 gas = gasleft();
        generate_together(1_00);
        console.log("generate_together: %d", gas - gasleft());
        gas = gasleft();
        generate_sepatarely(1_00);
        console.log("generate_sepatarely: %d", gas - gasleft());
    }
}

/// Results:
// Running 1 test for contracts/test/memtest.sol:MemTest
// [PASS] test_mem_test() (gas: 704106)
// Logs: [num = 1_000]
//   generate_together: 384225
//   generate_sepatarely: 315519
//
// Logs: [num = 100]
// generate_together: 34263
// generate_sepatarely: 27723
