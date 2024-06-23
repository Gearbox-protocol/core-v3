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
    /// @notice U:[BM-1]: `calcEnabledTokens` works correctly

    function test_U_BM_01_calcEnabledTokens_works_correctly(uint8 bitsToEnable, uint256 randomValue) public {
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

    /// @notice U:[BM-2]: `enable` & `disable` works correctly
    function test_U_BM_02_enable_and_disable_works_correctly(uint8 bit) public {
        uint256 mask;
        mask = mask.enable(1 << bit);
        assertEq(mask, 1 << bit, "Enable doesn't work");

        mask = mask.disable(1 << bit);
        assertEq(mask, 0, "Disable doesn't work");
    }

    /// @notice U:[BM-3]: `enableDisable` works correctly
    function test_U_BM_03_enableDisable_works_correctly(uint8 bit) public {
        uint256 mask;

        mask = mask.enableDisable(1 << bit, 0);
        assertEq(mask, 1 << bit, "Enable doesn't work");

        mask = mask.enableDisable(0, 1 << bit);
        assertEq(mask, 0, "Disable doesn't work");
    }
}
