// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UnsafeERC20} from "../../../libraries/UnsafeERC20.sol";

import {TestHelper} from "../../lib/helper.sol";

/// @title UnsafeERC20 library unit test
/// @notice U:[UE]: Unit tests for UnsafeERC20 library
contract UnsafeERC20UnitTest is TestHelper {
    using UnsafeERC20 for IERC20;

    struct UnsafeTransferTestCase {
        string name;
        bytes transferOutput;
        bool transferReverts;
        bool expectedResult;
    }

    /// @notice U:[UE-1]: `unsafeTransfer` works correctly
    function test_U_UE_01_unsafeTransfer_works_correctly() public {
        UnsafeTransferTestCase[4] memory cases = [
            UnsafeTransferTestCase({
                name: "function reverts",
                transferOutput: bytes(""),
                transferReverts: true,
                expectedResult: false
            }),
            UnsafeTransferTestCase({
                name: "function returns false",
                transferOutput: abi.encode(false),
                transferReverts: false,
                expectedResult: false
            }),
            UnsafeTransferTestCase({
                name: "function returns true",
                transferOutput: abi.encode(true),
                transferReverts: false,
                expectedResult: true
            }),
            UnsafeTransferTestCase({
                name: "function returns nothing",
                transferOutput: bytes(""),
                transferReverts: false,
                expectedResult: true
            })
        ];

        address token = makeAddr("TOKEN");
        address to = makeAddr("TO");
        uint256 amount = 1 ether;
        bytes memory transferCallData = abi.encodeCall(IERC20.transfer, (to, amount));

        for (uint256 i; i < cases.length; ++i) {
            if (cases[i].transferReverts) {
                vm.mockCallRevert(token, transferCallData, cases[i].transferOutput);
            } else {
                vm.mockCall(token, transferCallData, cases[i].transferOutput);
            }

            vm.expectCall(token, transferCallData);

            bool result = IERC20(token).unsafeTransfer(to, amount);
            assertEq(result, cases[i].expectedResult, _testCaseErr(cases[i].name, "Incorrect result"));
        }
    }

    /// @notice U:[UE-2]: `unsafeTransferFrom` works correctly
    function test_U_UE_02_unsafeTransferFrom_works_correctly() public {
        UnsafeTransferTestCase[4] memory cases = [
            UnsafeTransferTestCase({
                name: "function reverts",
                transferOutput: bytes(""),
                transferReverts: true,
                expectedResult: false
            }),
            UnsafeTransferTestCase({
                name: "function returns false",
                transferOutput: abi.encode(false),
                transferReverts: false,
                expectedResult: false
            }),
            UnsafeTransferTestCase({
                name: "function returns true",
                transferOutput: abi.encode(true),
                transferReverts: false,
                expectedResult: true
            }),
            UnsafeTransferTestCase({
                name: "function returns nothing",
                transferOutput: bytes(""),
                transferReverts: false,
                expectedResult: true
            })
        ];

        address token = makeAddr("TOKEN");
        address from = makeAddr("FROM");
        address to = makeAddr("TO");
        uint256 amount = 1 ether;
        bytes memory transferFromCallData = abi.encodeCall(IERC20.transferFrom, (from, to, amount));

        for (uint256 i; i < cases.length; ++i) {
            if (cases[i].transferReverts) {
                vm.mockCallRevert(token, transferFromCallData, cases[i].transferOutput);
            } else {
                vm.mockCall(token, transferFromCallData, cases[i].transferOutput);
            }

            vm.expectCall(token, transferFromCallData);

            bool result = IERC20(token).unsafeTransferFrom(from, to, amount);
            assertEq(result, cases[i].expectedResult, _testCaseErr(cases[i].name, "Incorrect result"));
        }
    }
}
