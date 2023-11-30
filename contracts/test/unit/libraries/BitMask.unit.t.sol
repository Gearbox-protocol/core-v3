// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IncorrectParameterException} from "../../../interfaces/IExceptions.sol";
import {BitMask} from "../../../libraries/BitMask.sol";

import {TestHelper} from "../../lib/helper.sol";

/// @title BitMask logic test
/// @notice U:[BM]: Unit tests for bit mask library
contract BitMaskUnitTest is TestHelper {
    using BitMask for uint256;

    /// @notice U:[BM-1]: `calcIndex` reverts for zero value
    function test_U_BM_01_calcIndex_reverts_for_zero_value() public {
        vm.expectRevert(IncorrectParameterException.selector);
        uint256(0).calcIndex();
    }

    /// @notice U:[BM-2]: `calcIndex` works correctly
    function test_U_BM_02_calcIndex_works_correctly() public {
        for (uint256 i = 0; i < 256; ++i) {
            uint256 mask = 1 << i;
            assertEq(mask.calcIndex(), i, "Incorrect index");
        }
    }

    /// @notice U:[BM-3]: `calcEnabledTokens` works correctly
    function test_U_BM_03_calcEnabledTokens_works_correctly(uint8 bitsToEnable, uint256 randomValue) public {
        uint256 bitMask;

        for (uint256 i; i < bitsToEnable;) {
            randomValue = uint256(keccak256(abi.encodePacked(randomValue)));
            uint256 randMask = 1 << uint8(randomValue % 255);
            if (randMask & bitMask == 0) {
                bitMask |= randMask;
                ++i;
            }
        }

        assertEq(bitMask.calcEnabledTokens(), bitsToEnable, "Incorrect bits computation");
    }

    /// @notice U:[BM-4]: `enable` & `disable` works correctly
    function test_U_BM_04_enable_and_disable_works_correctly(uint8 bit) public {
        uint256 mask;
        mask = mask.enable(1 << bit);
        assertEq(mask, 1 << bit, "Enable doesn't work");

        mask = mask.disable(1 << bit);
        assertEq(mask, 0, "Disable doesn't work");
    }

    /// @notice U:[BM-5]: `enableDisable` works correctly
    function test_U_BM_05_enableDisable_works_correctly(uint8 bit) public {
        uint256 mask;

        mask = mask.enableDisable(1 << bit, 0);
        assertEq(mask, 1 << bit, "Enable doesn't work");

        mask = mask.enableDisable(0, 1 << bit);
        assertEq(mask, 0, "Disable doesn't work");
    }

    /// @notice U:[BM-6]: `enable` & `disable` works correctly
    function test_U_BM_06_enable_and_disable_works_correctly(uint8 bit) public {
        uint256 mask;
        mask = mask.enable(1 << bit, 0);
        assertEq(mask, 0, "Enable doesn't work");

        mask = mask.enable(1 << bit, 1 << bit);
        assertEq(mask, 1 << bit, "Enable doesn't work");

        mask = mask.disable(1 << bit, 0);
        assertEq(mask, 1 << bit, "Disable doesn't work");

        mask = mask.disable(1 << bit, 1 << bit);
        assertEq(mask, 0, "Disable doesn't work");
    }

    /// @notice U:[BM-7]: `enableWithSkip` works correctly
    function test_U_BM_07_enableWithSkip_works_correctly(uint8 bit) public {
        uint256 mask;

        mask = mask.enableDisable(1 << bit, 0, 0);
        assertEq(mask, 0, "Enable doesn't work");

        mask = mask.enableDisable(1 << bit, 0, 1 << bit);
        assertEq(mask, 1 << bit, "Enable doesn't work");

        mask = mask.enableDisable(0, 1 << bit, 0);
        assertEq(mask, 1 << bit, "Disable doesn't work");

        mask = mask.enableDisable(0, 1 << bit, 1 << bit);
        assertEq(mask, 0, "Disable doesn't work");
    }
}
