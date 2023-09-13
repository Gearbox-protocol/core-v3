// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

struct Tuple {
    address a;
    uint256 b;
}

contract ArrayAllocGasTest is Test {
    function test_G_AA_01_array_of_tuples_allocation_gas_usage() public view {
        uint256 gas = gasleft();
        _allocate_array_of_tuples(1_000);
        console.log("allocate_array_of_tupls: %d", gas - gasleft()); // 384225
    }

    function test_G_AA_02_tuple_of_arrays_allocation_gas_usage() public view {
        uint256 gas = gasleft();
        _allocate_tuple_of_arrays(1_000);
        console.log("allocate_tuple_of_arrays: %d", gas - gasleft()); // 276311
    }

    function _allocate_array_of_tuples(uint256 num) internal pure returns (Tuple[] memory result) {
        result = new Tuple[](num);
        for (uint256 i; i < num; ++i) {
            result[i] = Tuple(address(uint160(i)), i);
        }
    }

    function _allocate_tuple_of_arrays(uint256 num)
        internal
        pure
        returns (address[] memory addrs, uint256[] memory uints)
    {
        addrs = new address[](num);
        uints = new uint256[](num);

        for (uint256 i; i < num; ++i) {
            addrs[i] = address(uint160(i));
            uints[i] = i;
        }
    }
}
