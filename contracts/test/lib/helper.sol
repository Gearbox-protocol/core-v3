// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "./constants.sol";
import {Test} from "forge-std/Test.sol";

struct VarU256 {
    mapping(bytes32 => uint256) values;
    mapping(bytes32 => bool) isSet;
}

library Vars {
    function set(VarU256 storage v, string memory key, uint256 value) internal {
        bytes32 b32key = keccak256(bytes(key));
        v.values[b32key] = value;
        v.isSet[b32key] = true;
    }

    function get(VarU256 storage v, string memory key) internal view returns (uint256) {
        bytes32 b32key = keccak256(bytes(key));
        require(v.isSet[b32key], string.concat("Value ", key, " is undefined"));
        return v.values[b32key];
    }
}

contract TestHelper is Test {
    VarU256 internal vars;

    string caseName;

    constructor() {
        vm.label(USER, "USER");
        vm.label(FRIEND, "FRIEND");
        vm.label(LIQUIDATOR, "LIQUIDATOR");
        vm.label(INITIAL_LP, "INITIAL_LP");
        vm.label(DUMB_ADDRESS, "DUMB_ADDRESS");
        vm.label(ADAPTER, "ADAPTER");
    }

    function _testCaseErr(string memory err) internal view returns (string memory) {
        return _testCaseErr(caseName, err);
    }

    function _testCaseErr(string memory _caseName, string memory err) internal pure returns (string memory) {
        return string.concat("\nCase: ", _caseName, "\nError: ", err);
    }

    function arrayOf(uint256 v1) internal pure returns (uint256[] memory array) {
        array = new uint256[](1);
        array[0] = v1;
    }

    function arrayOf(uint256 v1, uint256 v2) internal pure returns (uint256[] memory array) {
        array = new uint256[](2);
        array[0] = v1;
        array[1] = v2;
    }

    function arrayOf(uint256 v1, uint256 v2, uint256 v3) internal pure returns (uint256[] memory array) {
        array = new uint256[](3);
        array[0] = v1;
        array[1] = v2;
        array[2] = v3;
    }

    function arrayOf(uint256 v1, uint256 v2, uint256 v3, uint256 v4) internal pure returns (uint256[] memory array) {
        array = new uint256[](4);
        array[0] = v1;
        array[1] = v2;
        array[2] = v3;
        array[3] = v4;
    }

    function arrayOfU16(uint16 v1) internal pure returns (uint16[] memory array) {
        array = new uint16[](1);
        array[0] = v1;
    }

    function arrayOfU16(uint16 v1, uint16 v2) internal pure returns (uint16[] memory array) {
        array = new uint16[](2);
        array[0] = v1;
        array[1] = v2;
    }

    function arrayOfU16(uint16 v1, uint16 v2, uint16 v3) internal pure returns (uint16[] memory array) {
        array = new uint16[](3);
        array[0] = v1;
        array[1] = v2;
        array[2] = v3;
    }

    function arrayOfU16(uint16 v1, uint16 v2, uint16 v3, uint16 v4) internal pure returns (uint16[] memory array) {
        array = new uint16[](4);
        array[0] = v1;
        array[1] = v2;
        array[2] = v3;
        array[3] = v4;
    }

    function _copyU16toU256(uint16[] memory a16) internal pure returns (uint256[] memory a256) {
        uint256 len = a16.length;
        uint256[] memory a256 = new uint256[](len);

        unchecked {
            for (uint256 i; i < len; ++i) {
                a256[i] = a16[i];
            }
        }
    }

    function assertEq(uint16[] memory a1, uint16[] memory a2, string memory reason) internal {
        assertEq(a1.length, a2.length, string.concat(reason, "Arrays has different length"));

        assertEq(_copyU16toU256(a1), _copyU16toU256(a2), reason);
    }
}
