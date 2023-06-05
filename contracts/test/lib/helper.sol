// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {CollateralDebtData} from "../../interfaces/ICreditManagerV3.sol";
import "./constants.sol";

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
        a256 = new uint256[](len);

        unchecked {
            for (uint256 i; i < len; ++i) {
                a256[i] = a16[i];
            }
        }
    }

    function arrayOf(address v1) internal pure returns (address[] memory array) {
        array = new address[](1);
        array[0] = v1;
    }

    function arrayOf(address v1, address v2) internal pure returns (address[] memory array) {
        array = new address[](2);
        array[0] = v1;
        array[1] = v2;
    }

    function arrayOf(address v1, address v2, address v3) internal pure returns (address[] memory array) {
        array = new address[](3);
        array[0] = v1;
        array[1] = v2;
        array[2] = v3;
    }

    function arrayOf(address v1, address v2, address v3, address v4) internal pure returns (address[] memory array) {
        array = new address[](4);
        array[0] = v1;
        array[1] = v2;
        array[2] = v3;
        array[3] = v4;
    }

    function assertEq(uint16[] memory a1, uint16[] memory a2, string memory reason) internal {
        assertEq(a1.length, a2.length, string.concat(reason, "Arrays has different length"));

        assertEq(_copyU16toU256(a1), _copyU16toU256(a2), reason);
    }

    function assertEq(CollateralDebtData memory cdd1, CollateralDebtData memory cdd2) internal {
        assertEq(cdd1, cdd2, "");
    }

    function assertEq(CollateralDebtData memory cdd1, CollateralDebtData memory cdd2, string memory reason) internal {
        assertEq(cdd1.debt, cdd2.debt, string.concat(reason, "\nIncorrect debt"));
        assertEq(
            cdd1.cumulativeIndexNow, cdd2.cumulativeIndexNow, string.concat(reason, "\nIncorrect cumulativeIndexNow")
        );
        assertEq(
            cdd1.cumulativeIndexLastUpdate,
            cdd2.cumulativeIndexLastUpdate,
            string.concat(reason, "\nIncorrect cumulativeIndexLastUpdate")
        );
        assertEq(
            cdd1.cumulativeQuotaInterest,
            cdd2.cumulativeQuotaInterest,
            string.concat(reason, "\nIncorrect cumulativeQuotaInterest")
        );
        assertEq(cdd1.accruedInterest, cdd2.accruedInterest, string.concat(reason, "\nIncorrect accruedInterest"));
        assertEq(cdd1.accruedFees, cdd2.accruedFees, string.concat(reason, "\nIncorrect accruedFees"));
        assertEq(cdd1.totalDebtUSD, cdd2.totalDebtUSD, string.concat(reason, "\nIncorrect totalDebtUSD"));
        assertEq(cdd1.totalValue, cdd2.totalValue, string.concat(reason, "\nIncorrect totalValue"));
        assertEq(cdd1.totalValueUSD, cdd2.totalValueUSD, string.concat(reason, "\nIncorrect totalValueUSD"));
        assertEq(cdd1.twvUSD, cdd2.twvUSD, string.concat(reason, "\nIncorrect twvUSD"));
        assertEq(cdd1.enabledTokensMask, cdd2.enabledTokensMask, string.concat(reason, "\nIncorrect enabledTokensMask"));
        assertEq(cdd1.quotedTokensMask, cdd2.quotedTokensMask, string.concat(reason, "\nIncorrect quotedTokensMask"));
        assertEq(cdd1.quotedTokens, cdd2.quotedTokens, string.concat(reason, "\nIncorrect quotedTokens"));
        // assertEq(cdd1.quotedLts, cdd2.quotedLts, string.concat(reason, "\nIncorrect quotedLts"));
        // assertEq(cdd1.quotas, cdd2.quotas, string.concat(reason, "\nIncorrect quotas"));
        assertEq(cdd1._poolQuotaKeeper, cdd2._poolQuotaKeeper, string.concat(reason, "\nIncorrect _poolQuotaKeeper"));
    }

    function clone(CollateralDebtData memory src) internal pure returns (CollateralDebtData memory dst) {
        dst.debt = src.debt;
        dst.cumulativeIndexNow = src.cumulativeIndexNow;
        dst.cumulativeIndexLastUpdate = src.cumulativeIndexLastUpdate;
        dst.cumulativeQuotaInterest = src.cumulativeQuotaInterest;
        dst.accruedInterest = src.accruedInterest;
        dst.accruedFees = src.accruedFees;
        dst.totalDebtUSD = src.totalDebtUSD;
        dst.totalValue = src.totalValue;
        dst.totalValueUSD = src.totalValueUSD;
        dst.twvUSD = src.twvUSD;
        dst.enabledTokensMask = src.enabledTokensMask;
        dst.quotedTokensMask = src.quotedTokensMask;
        dst.quotedTokens = src.quotedTokens;
        // dst.quotedLts = src.quotedLts;
        // dst.quotas = src.quotas;
        dst._poolQuotaKeeper = src._poolQuotaKeeper;
    }

    function getHash(uint256 value, uint256 seed) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(value, seed)));
    }

    function boolToStr(bool value) internal pure returns (string memory) {
        return value ? "true" : "false";
    }
}
