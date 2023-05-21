// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {ClaimAction, ScheduledWithdrawal} from "../../../interfaces/IWithdrawalManager.sol";
import {WithdrawalsLogic} from "../../../libraries/WithdrawalsLogic.sol";

import {TestHelper} from "../../lib/helper.sol";

enum ScheduleTask {
    IMMATURE,
    MATURE,
    NON_SCHEDULED
}

/// @title Withdrawals logic library unit test
/// @notice U:[WL]: Unit tests for withdrawals logic library
contract WithdrawalsLogicUnitTest is TestHelper {
    using WithdrawalsLogic for ClaimAction;
    using WithdrawalsLogic for ScheduledWithdrawal;
    using WithdrawalsLogic for ScheduledWithdrawal[2];

    ScheduledWithdrawal[2] withdrawals;

    address constant TOKEN = address(0xdead);
    uint8 constant TOKEN_INDEX = 1;
    uint256 constant AMOUNT = 1 ether;

    /// @notice U:[WL-1]: `clear` works correctly
    function test_U_WL_01_clear_works_correctly() public {
        _setupWithdrawalSlot(0, ScheduleTask.MATURE);
        withdrawals[0].clear();
        assertEq(withdrawals[0].maturity, 1);
        assertEq(withdrawals[0].amount, 1);
    }

    /// @notice U:[WL-2]: `tokenMaskAndAmount` works correctly
    function test_U_WL_02_tokenMaskAndAmount_works_correctly() public {
        // before scheduling
        (address token, uint256 mask, uint256 amount) = withdrawals[0].tokenMaskAndAmount();
        assertEq(token, address(0));
        assertEq(mask, 0);
        assertEq(amount, 0);

        // after scheduling
        _setupWithdrawalSlot(0, ScheduleTask.MATURE);
        (token, mask, amount) = withdrawals[0].tokenMaskAndAmount();
        assertEq(token, TOKEN);
        assertEq(mask, 1 << TOKEN_INDEX);
        assertEq(amount, AMOUNT - 1);

        // after clearing
        _setupWithdrawalSlot(0, ScheduleTask.NON_SCHEDULED);
        (token, mask, amount) = withdrawals[0].tokenMaskAndAmount();
        assertEq(token, address(0));
        assertEq(mask, 0);
        assertEq(amount, 0);
    }

    struct FindFreeSlotCase {
        string name;
        ScheduleTask task0;
        ScheduleTask task1;
        bool expectedFound;
        uint8 expectedSlot;
    }

    /// @notice U:[WL-3]: `findFreeSlot` works correctly
    function test_U_WL_03_findFreeSlot_works_correctly() public {
        FindFreeSlotCase[4] memory cases = [
            FindFreeSlotCase({
                name: "both slots non-scheduled",
                task0: ScheduleTask.NON_SCHEDULED,
                task1: ScheduleTask.NON_SCHEDULED,
                expectedFound: true,
                expectedSlot: 0
            }),
            FindFreeSlotCase({
                name: "slot 0 non-scheduled, slot 1 scheduled",
                task0: ScheduleTask.NON_SCHEDULED,
                task1: ScheduleTask.MATURE,
                expectedFound: true,
                expectedSlot: 0
            }),
            FindFreeSlotCase({
                name: "slot 0 scheduled, slot 1 non-scheduled",
                task0: ScheduleTask.MATURE,
                task1: ScheduleTask.NON_SCHEDULED,
                expectedFound: true,
                expectedSlot: 1
            }),
            FindFreeSlotCase({
                name: "both slots scheduled",
                task0: ScheduleTask.MATURE,
                task1: ScheduleTask.MATURE,
                expectedFound: false,
                expectedSlot: 0
            })
        ];

        for (uint256 i; i < cases.length; ++i) {
            _setupWithdrawalSlot(0, cases[i].task0);
            _setupWithdrawalSlot(1, cases[i].task1);

            (bool found, uint8 slot) = withdrawals.findFreeSlot();
            assertEq(found, cases[i].expectedFound, _testCaseErr(cases[i].name, "incorrect found value"));
            if (found) {
                assertEq(slot, cases[i].expectedSlot, _testCaseErr(cases[i].name, "incorrect slot"));
            }
        }
    }

    struct ClaimOrCancelAllowedCase {
        string name;
        ClaimAction action;
        ScheduleTask task;
        bool expectedResult;
    }

    /// @notice U:[WL-4]: `claimAllowed` works correctly
    function test_U_WL_04_claimAllowed_works_correctly() public {
        ClaimOrCancelAllowedCase[12] memory cases = [
            ClaimOrCancelAllowedCase({
                name: "immature withdrawal, action == CLAIM",
                action: ClaimAction.CLAIM,
                task: ScheduleTask.IMMATURE,
                expectedResult: false
            }),
            ClaimOrCancelAllowedCase({
                name: "immature withdrawal, action == CANCEL",
                action: ClaimAction.CANCEL,
                task: ScheduleTask.IMMATURE,
                expectedResult: false
            }),
            ClaimOrCancelAllowedCase({
                name: "immature withdrawal, action == FORCE_CLAIM",
                action: ClaimAction.FORCE_CLAIM,
                task: ScheduleTask.IMMATURE,
                expectedResult: true
            }),
            ClaimOrCancelAllowedCase({
                name: "immature withdrawal, action == FORCE_CANCEL",
                action: ClaimAction.FORCE_CANCEL,
                task: ScheduleTask.IMMATURE,
                expectedResult: false
            }),
            ClaimOrCancelAllowedCase({
                name: "mature withdrawal, action == CLAIM",
                action: ClaimAction.CLAIM,
                task: ScheduleTask.MATURE,
                expectedResult: true
            }),
            ClaimOrCancelAllowedCase({
                name: "mature withdrawal, action == CANCEL",
                action: ClaimAction.CANCEL,
                task: ScheduleTask.MATURE,
                expectedResult: true
            }),
            ClaimOrCancelAllowedCase({
                name: "mature withdrawal, action == FORCE_CLAIM",
                action: ClaimAction.FORCE_CLAIM,
                task: ScheduleTask.MATURE,
                expectedResult: true
            }),
            ClaimOrCancelAllowedCase({
                name: "mature withdrawal, action == FORCE_CANCEL",
                action: ClaimAction.FORCE_CANCEL,
                task: ScheduleTask.MATURE,
                expectedResult: false
            }),
            ClaimOrCancelAllowedCase({
                name: "non-scheduled withdrawal, action == CLAIM",
                action: ClaimAction.CLAIM,
                task: ScheduleTask.NON_SCHEDULED,
                expectedResult: false
            }),
            ClaimOrCancelAllowedCase({
                name: "non-scheduled withdrawal, action == CANCEL",
                action: ClaimAction.CANCEL,
                task: ScheduleTask.NON_SCHEDULED,
                expectedResult: false
            }),
            ClaimOrCancelAllowedCase({
                name: "non-scheduled withdrawal, action == FORCE_CLAIM",
                action: ClaimAction.FORCE_CLAIM,
                task: ScheduleTask.NON_SCHEDULED,
                expectedResult: false
            }),
            ClaimOrCancelAllowedCase({
                name: "non-scheduled withdrawal, action == FORCE_CANCEL",
                action: ClaimAction.FORCE_CANCEL,
                task: ScheduleTask.NON_SCHEDULED,
                expectedResult: false
            })
        ];

        for (uint256 i; i < cases.length; ++i) {
            _setupWithdrawalSlot(0, cases[i].task);
            assertEq(
                cases[i].action.claimAllowed(withdrawals[0].maturity),
                cases[i].expectedResult,
                _testCaseErr(cases[i].name, "incorrect result")
            );
        }
    }

    /// @notice U:[WL-5]: `cancelAllowed` works correctly
    function test_U_WL_05_cancelAllowed_works_correctly() public {
        ClaimOrCancelAllowedCase[12] memory cases = [
            ClaimOrCancelAllowedCase({
                name: "immature withdrawal, action == CLAIM",
                action: ClaimAction.CLAIM,
                task: ScheduleTask.IMMATURE,
                expectedResult: false
            }),
            ClaimOrCancelAllowedCase({
                name: "immature withdrawal, action == CANCEL",
                action: ClaimAction.CANCEL,
                task: ScheduleTask.IMMATURE,
                expectedResult: true
            }),
            ClaimOrCancelAllowedCase({
                name: "immature withdrawal, action == FORCE_CLAIM",
                action: ClaimAction.FORCE_CLAIM,
                task: ScheduleTask.IMMATURE,
                expectedResult: false
            }),
            ClaimOrCancelAllowedCase({
                name: "immature withdrawal, action == FORCE_CANCEL",
                action: ClaimAction.FORCE_CANCEL,
                task: ScheduleTask.IMMATURE,
                expectedResult: true
            }),
            ClaimOrCancelAllowedCase({
                name: "mature withdrawal, action == CLAIM",
                action: ClaimAction.CLAIM,
                task: ScheduleTask.MATURE,
                expectedResult: false
            }),
            ClaimOrCancelAllowedCase({
                name: "mature withdrawal, action == CANCEL",
                action: ClaimAction.CANCEL,
                task: ScheduleTask.MATURE,
                expectedResult: false
            }),
            ClaimOrCancelAllowedCase({
                name: "mature withdrawal, action == FORCE_CLAIM",
                action: ClaimAction.FORCE_CLAIM,
                task: ScheduleTask.MATURE,
                expectedResult: false
            }),
            ClaimOrCancelAllowedCase({
                name: "mature withdrawal, action == FORCE_CANCEL",
                action: ClaimAction.FORCE_CANCEL,
                task: ScheduleTask.MATURE,
                expectedResult: true
            }),
            ClaimOrCancelAllowedCase({
                name: "non-scheduled withdrawal, action == CLAIM",
                action: ClaimAction.CLAIM,
                task: ScheduleTask.NON_SCHEDULED,
                expectedResult: false
            }),
            ClaimOrCancelAllowedCase({
                name: "non-scheduled withdrawal, action == CANCEL",
                action: ClaimAction.CANCEL,
                task: ScheduleTask.NON_SCHEDULED,
                expectedResult: false
            }),
            ClaimOrCancelAllowedCase({
                name: "non-scheduled withdrawal, action == FORCE_CLAIM",
                action: ClaimAction.FORCE_CLAIM,
                task: ScheduleTask.NON_SCHEDULED,
                expectedResult: false
            }),
            ClaimOrCancelAllowedCase({
                name: "non-scheduled withdrawal, action == FORCE_CANCEL",
                action: ClaimAction.FORCE_CANCEL,
                task: ScheduleTask.NON_SCHEDULED,
                expectedResult: false
            })
        ];

        for (uint256 i; i < cases.length; ++i) {
            _setupWithdrawalSlot(0, cases[i].task);
            assertEq(
                cases[i].action.cancelAllowed(withdrawals[0].maturity),
                cases[i].expectedResult,
                _testCaseErr(cases[i].name, "incorrect result")
            );
        }
    }

    /// ------- ///
    /// HELPERS ///
    /// ------- ///

    function _setupWithdrawalSlot(uint8 slot, ScheduleTask task) internal {
        if (task == ScheduleTask.NON_SCHEDULED) {
            withdrawals[slot].clear();
        } else {
            uint40 maturity = task == ScheduleTask.MATURE ? uint40(block.timestamp - 1) : uint40(block.timestamp + 1);
            withdrawals[slot] =
                ScheduledWithdrawal({maturity: maturity, amount: 1 ether, token: address(0xdead), tokenIndex: 1});
        }
    }
}
