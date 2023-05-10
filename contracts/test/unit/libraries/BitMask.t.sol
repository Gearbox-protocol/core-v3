// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IncorrectParameterException} from "../../../interfaces/IExceptions.sol";
import {BitMask} from "../../../libraries/BitMask.sol";

import {TestHelper} from "../../lib/helper.sol";

/// @title BitMask logic test
/// @notice [BM]: Unit tests for bit mask library
contract BitMaskTest is TestHelper {
    using BitMask for uint256;

    /// @notice [BM-1]: `calcIndex` reverts for zero value
    function test_BM_01_calcIndex_reverts_for_zero_value() public {
        vm.expectRevert(IncorrectParameterException.selector);
        uint256(0).calcIndex();
    }

    /// @notice [BM-2]: `calcIndex` works correctly
    function test_BM_02_calcIndex_works_correctly() public {
        for (uint256 i = 0; i < 256; ++i) {
            uint256 mask = 1 << i;
            assertEq(mask.calcIndex(), i, "Incorrect index");
        }
    }
}
