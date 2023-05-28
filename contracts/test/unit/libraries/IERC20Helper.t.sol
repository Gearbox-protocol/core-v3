// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IERC20Helper} from "../../../libraries/IERC20Helper.sol";

import {TestHelper} from "../../lib/helper.sol";

/// @title ERC20 helper library unit test
/// @notice U:[EH]: Unit tests for ERC20 helper library
contract IERC20HelperUnitTest is TestHelper {
    using IERC20Helper for IERC20;

    struct UnsafeTransferTestCase {
        string name;
        bytes transferOutput;
        bool transferReverts;
        bool expectedResult;
    }

    /// @notice U:[EH-1]: `unsafeTransfer` works correctly
    function test_U_EH_01_unsafeTransfer_works_correctly() public {
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

    /// @notice U:[EH-2]: `unsafeTransferFrom` works correctly
    function test_U_EH_02_unsafeTransferFrom_works_correctly() public {
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
