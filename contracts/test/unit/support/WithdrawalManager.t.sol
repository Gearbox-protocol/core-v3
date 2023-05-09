// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@gearbox-protocol/core-v2/contracts/test/mocks/token/ERC20Mock.sol";

import {ClaimAction, IWithdrawalManagerEvents, ScheduledWithdrawal} from "../../../interfaces/IWithdrawalManager.sol";
import {
    AmountCantBeZeroException,
    CallerNotConfiguratorException,
    CallerNotCreditManagerException,
    NoFreeWithdrawalSlotsException,
    NothingToClaimException,
    ZeroAddressException
} from "../../../interfaces/IExceptions.sol";
import {WithdrawalManager} from "../../../support/WithdrawalManager.sol";

import {AddressProviderACLMock} from "../../mocks/core/AddressProviderACLMock.sol";
import {ERC20BlacklistableMock} from "../../mocks/token/ERC20Blacklistable.sol";

contract WithdrawalManagerHarness is WithdrawalManager {
    constructor(address _addressProvider, uint40 _delay) WithdrawalManager(_addressProvider, _delay) {}

    function setWithdrawalSlot(address creditAccount, uint8 slot, ScheduledWithdrawal memory w) external {
        _scheduled[creditAccount][slot] = w;
    }

    function processScheduledWithdrawal(address creditAccount, uint8 slot, ClaimAction action, address to)
        external
        returns (bool scheduled, bool claimed, uint256 tokensToEnable)
    {
        return _processScheduledWithdrawal(_scheduled[creditAccount][slot], action, creditAccount, to);
    }

    function claimScheduledWithdrawal(address creditAccount, uint8 slot, address to) external {
        _claimScheduledWithdrawal(_scheduled[creditAccount][slot], creditAccount, to);
    }

    function cancelScheduledWithdrawal(address creditAccount, uint8 slot) external returns (uint256 tokensToEnable) {
        return _cancelScheduledWithdrawal(_scheduled[creditAccount][slot], creditAccount);
    }
}

enum ScheduleTask {
    IMMATURE,
    MATURE,
    NON_SCHEDULED
}

/// @title Withdrawal manager test
/// @notice [WM]: Unit tests for withdrawal manager
contract WithdrawalManagerTest is Test, IWithdrawalManagerEvents {
    WithdrawalManagerHarness manager;
    AddressProviderACLMock acl;
    ERC20BlacklistableMock token0;
    ERC20Mock token1;

    address user;
    address configurator;
    address creditAccount;
    address creditManager;

    uint40 constant DELAY = 1 days;
    uint256 constant AMOUNT = 10 ether;
    uint8 constant TOKEN0_INDEX = 0;
    uint256 constant TOKEN0_MASK = 1;

    uint8 constant TOKEN1_INDEX = 1;
    uint8 constant TOKEN1_MASK = 2;

    function setUp() public {
        user = makeAddr("USER");
        configurator = makeAddr("CONFIGURATOR");
        creditAccount = makeAddr("CREDIT_ACCOUNT");
        creditManager = makeAddr("CREDIT_MANAGER");

        vm.startPrank(configurator);
        acl = new AddressProviderACLMock();
        manager = new WithdrawalManagerHarness(address(acl), DELAY);
        manager.setCreditManagerStatus(creditManager, true);
        vm.stopPrank();

        token0 = new ERC20BlacklistableMock("Test token 1", "TEST1", 18);
        token1 = new ERC20Mock("Test token 2", "TEST2", 18);
    }

    /// ------------- ///
    /// GENERAL TESTS ///
    /// ------------- ///

    /// @notice [WM-1]: Constructor sets correct values
    function test_WM_01_constructor_sets_correct_values() public {
        assertEq(manager.delay(), DELAY, "Incorrect delay");
    }

    /// @notice [WM-2]: External functions have correct access
    function test_WM_02_external_functions_have_correct_access() public {
        vm.startPrank(user);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        manager.addImmediateWithdrawal(address(0), address(0), 0);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        manager.addScheduledWithdrawal(address(0), address(0), 0, 0);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        manager.claimScheduledWithdrawals(address(0), address(0), ClaimAction(0));

        vm.expectRevert(CallerNotConfiguratorException.selector);
        manager.setWithdrawalDelay(0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        manager.setCreditManagerStatus(address(0), false);

        vm.stopPrank();
    }

    /// --------------------------- ///
    /// IMMEDIATE WITHDRAWALS TESTS ///
    /// --------------------------- ///

    /// @notice [WM-3]: `addImmediateWithdrawal` works correctly
    function test_WM_03_addImmediateWithdrawal_works_correctly() public {
        vm.startPrank(creditManager);

        // add first withdrawal
        deal(address(token0), address(manager), AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit AddImmediateWithdrawal(user, address(token0), AMOUNT);

        manager.addImmediateWithdrawal(user, address(token0), AMOUNT);

        assertEq(
            manager.immediateWithdrawals(user, address(token0)),
            AMOUNT,
            "Incorrect claimable balance after adding first withdrawal"
        );

        // add second withdrawal in the same token0
        deal(address(token0), address(manager), AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit AddImmediateWithdrawal(user, address(token0), AMOUNT);

        manager.addImmediateWithdrawal(user, address(token0), AMOUNT);

        assertEq(
            manager.immediateWithdrawals(user, address(token0)),
            2 * AMOUNT,
            "Incorrect claimable balance after adding second withdrawal"
        );

        vm.stopPrank();
    }

    /// @notice [WM-4A]: `claimImmediateWithdrawal` reverts on zero recipient
    function test_WM_04A_claimImmediateWithdrawal_reverts_on_zero_recipient() public {
        vm.expectRevert(ZeroAddressException.selector);
        vm.prank(user);
        manager.claimImmediateWithdrawal(address(token0), address(0));
    }

    /// @notice [WM-4B]: `claimImmediateWithdrawal` reverts on nothing to claim
    function test_WM_04B_claimImmediateWithdrawal_reverts_on_nothing_to_claim() public {
        vm.expectRevert(NothingToClaimException.selector);
        vm.prank(user);
        manager.claimImmediateWithdrawal(address(token0), address(user));
    }

    /// @notice [WM-4C]: `claimImmediateWithdrawal` works correctly
    function test_WM_04C_claimImmediateWithdrawal_works_correctly() public {
        deal(address(token0), address(manager), AMOUNT);

        vm.prank(creditManager);
        manager.addImmediateWithdrawal(user, address(token0), 10 ether);

        vm.expectEmit(true, true, false, true);
        emit ClaimImmediateWithdrawal(user, address(token0), user, AMOUNT - 1);

        vm.prank(user);
        manager.claimImmediateWithdrawal(address(token0), user);

        assertEq(manager.immediateWithdrawals(user, address(token0)), 1, "Incorrect claimable balance");
        assertEq(token0.balanceOf(user), AMOUNT - 1, "Incorrect claimed amount");
    }

    /// ----------------------------------------------- ///
    /// SCHEDULED WITHDRAWALS: EXTERNAL FUNCTIONS TESTS ///
    /// ----------------------------------------------- ///

    /// @notice [WM-5A]: `addScheduledWithdrawal` reverts on zero amount
    function test_WM_05A_addScheduledWithdrawal_reverts_on_zero_amount() public {
        vm.expectRevert(AmountCantBeZeroException.selector);
        vm.prank(creditManager);
        manager.addScheduledWithdrawal(creditAccount, address(token0), 1, TOKEN0_INDEX);
    }

    struct AddScheduledWithdrawalCase {
        string name;
        // scenario
        ScheduleTask task0;
        ScheduleTask task1;
        // expected result
        bool shouldRevert;
        uint8 expectedSlot;
    }

    /// @notice [WM-5B]: `addScheduledWithdrawal` works correctly
    function test_WM_05B_addScheduledWithdrawal_works_correctly() public {
        AddScheduledWithdrawalCase[4] memory cases = [
            AddScheduledWithdrawalCase({
                name: "both slots non-scheduled",
                task0: ScheduleTask.NON_SCHEDULED,
                task1: ScheduleTask.NON_SCHEDULED,
                shouldRevert: false,
                expectedSlot: 0
            }),
            AddScheduledWithdrawalCase({
                name: "slot 0 non-scheduled, slot 1 scheduled",
                task0: ScheduleTask.NON_SCHEDULED,
                task1: ScheduleTask.MATURE,
                shouldRevert: false,
                expectedSlot: 0
            }),
            AddScheduledWithdrawalCase({
                name: "slot 0 scheduled, slot 1 non-scheduled",
                task0: ScheduleTask.MATURE,
                task1: ScheduleTask.NON_SCHEDULED,
                shouldRevert: false,
                expectedSlot: 1
            }),
            AddScheduledWithdrawalCase({
                name: "both slots scheduled",
                task0: ScheduleTask.MATURE,
                task1: ScheduleTask.MATURE,
                shouldRevert: true,
                expectedSlot: 0
            })
        ];

        uint256 snapshot = vm.snapshot();
        for (uint256 i; i < cases.length; ++i) {
            _addScheduledWithdrawal({slot: 0, task: cases[i].task0});
            _addScheduledWithdrawal({slot: 1, task: cases[i].task1});

            uint40 expectedMaturity = uint40(block.timestamp) + DELAY;

            if (cases[i].shouldRevert) {
                vm.expectRevert(NoFreeWithdrawalSlotsException.selector);
            } else {
                vm.expectEmit(true, true, false, true);
                emit AddScheduledWithdrawal(creditAccount, address(token0), AMOUNT, expectedMaturity);
            }

            vm.prank(creditManager);
            manager.addScheduledWithdrawal(creditAccount, address(token0), AMOUNT, TOKEN0_INDEX);

            if (!cases[i].shouldRevert) {
                ScheduledWithdrawal memory w = manager.scheduledWithdrawals(creditAccount)[cases[i].expectedSlot];
                assertEq(w.tokenIndex, TOKEN0_INDEX, _format("incorrect token index", cases[i].name));
                assertEq(w.token, address(token0), _format("incorrect token", cases[i].name));
                assertEq(w.maturity, expectedMaturity, _format("incorrect maturity", cases[i].name));
                assertEq(w.amount, AMOUNT, _format("incorrect amount", cases[i].name));
            }

            vm.revertTo(snapshot);
        }
    }

    /// @notice [WM-6A]: `claimScheduledWithdrawals` reverts on nothing to claim when action is `CLAIM`
    function test_WM_06A_claimScheduledWithdrawals_reverts_on_nothing_to_claim() public {
        _addScheduledWithdrawal({slot: 0, task: ScheduleTask.IMMATURE});
        _addScheduledWithdrawal({slot: 1, task: ScheduleTask.NON_SCHEDULED});
        vm.expectRevert(NothingToClaimException.selector);
        vm.prank(creditManager);
        manager.claimScheduledWithdrawals(creditAccount, user, ClaimAction.CLAIM);
    }

    struct ClaimScheduledWithdrawalsCase {
        string name;
        // scenario
        ClaimAction action;
        ScheduleTask task0;
        ScheduleTask task1;
        // expected result
        bool shouldClaim0;
        bool shouldClaim1;
        bool shouldCancel0;
        bool shouldCancel1;
        bool expectedHasScheduled;
        uint256 expectedTokensToEnable;
    }

    /// @notice [WM-6B]: `claimScheduledWithdrawals` works correctly
    function test_WM_06B_claimScheduledWithdrawals_works_correctly() public {
        ClaimScheduledWithdrawalsCase[5] memory cases = [
            ClaimScheduledWithdrawalsCase({
                name: "action == CLAIM, slot 0 mature, slot 1 immature",
                action: ClaimAction.CLAIM,
                task0: ScheduleTask.MATURE,
                task1: ScheduleTask.IMMATURE,
                shouldClaim0: true,
                shouldClaim1: false,
                shouldCancel0: false,
                shouldCancel1: false,
                expectedHasScheduled: true,
                expectedTokensToEnable: 0
            }),
            ClaimScheduledWithdrawalsCase({
                name: "action == CLAIM, slot 0 mature, slot 1 non-scheduled",
                action: ClaimAction.CLAIM,
                task0: ScheduleTask.MATURE,
                task1: ScheduleTask.NON_SCHEDULED,
                shouldClaim0: true,
                shouldClaim1: false,
                shouldCancel0: false,
                shouldCancel1: false,
                expectedHasScheduled: false,
                expectedTokensToEnable: 0
            }),
            ClaimScheduledWithdrawalsCase({
                name: "action == CANCEL, slot 0 mature, slot 1 immature",
                action: ClaimAction.CANCEL,
                task0: ScheduleTask.MATURE,
                task1: ScheduleTask.IMMATURE,
                shouldClaim0: true,
                shouldClaim1: false,
                shouldCancel0: false,
                shouldCancel1: true,
                expectedHasScheduled: false,
                expectedTokensToEnable: TOKEN1_MASK
            }),
            ClaimScheduledWithdrawalsCase({
                name: "action == FORCE_CLAIM, slot 0 mature, slot 1 immature",
                action: ClaimAction.FORCE_CLAIM,
                task0: ScheduleTask.MATURE,
                task1: ScheduleTask.IMMATURE,
                shouldClaim0: true,
                shouldClaim1: true,
                shouldCancel0: false,
                shouldCancel1: false,
                expectedHasScheduled: false,
                expectedTokensToEnable: 0
            }),
            ClaimScheduledWithdrawalsCase({
                name: "action == FORCE_CANCEL, slot 0 mature, slot 1 immature",
                action: ClaimAction.FORCE_CANCEL,
                task0: ScheduleTask.MATURE,
                task1: ScheduleTask.IMMATURE,
                shouldClaim0: false,
                shouldClaim1: false,
                shouldCancel0: true,
                shouldCancel1: true,
                expectedHasScheduled: false,
                expectedTokensToEnable: TOKEN0_MASK | TOKEN1_MASK
            })
        ];

        uint256 snapshot = vm.snapshot();
        for (uint256 i; i < cases.length; ++i) {
            _addScheduledWithdrawal({slot: 0, task: cases[i].task0});
            _addScheduledWithdrawal({slot: 1, task: cases[i].task1});

            if (cases[i].shouldClaim0) {
                vm.expectEmit(true, true, false, false);
                emit ClaimScheduledWithdrawal(creditAccount, address(token0), address(0), 0);
            }
            if (cases[i].shouldClaim1) {
                vm.expectEmit(true, true, false, false);
                emit ClaimScheduledWithdrawal(creditAccount, address(token1), address(0), 0);
            }
            if (cases[i].shouldCancel0) {
                vm.expectEmit(true, true, false, false);
                emit CancelScheduledWithdrawal(creditAccount, address(token0), 0);
            }
            if (cases[i].shouldCancel1) {
                vm.expectEmit(true, true, false, false);
                emit CancelScheduledWithdrawal(creditAccount, address(token1), 0);
            }

            vm.prank(creditManager);
            (bool hasScheduled, uint256 tokensToEnable) =
                manager.claimScheduledWithdrawals(creditAccount, user, cases[i].action);

            assertEq(hasScheduled, cases[i].expectedHasScheduled, _format("incorrect hasScheduled", cases[i].name));
            assertEq(
                tokensToEnable, cases[i].expectedTokensToEnable, _format("incorrect tokensToEnable", cases[i].name)
            );

            vm.revertTo(snapshot);
        }
    }

    struct CancellableScheduledWithdrawalsCase {
        string name;
        // scenario
        bool isForceCancel;
        ScheduleTask task0;
        ScheduleTask task1;
        // expected results
        address expectedToken0;
        uint256 expectedAmount0;
        address expectedToken1;
        uint256 expectedAmount1;
    }

    /// @notice [WM-7]: `cancellableScheduledWithdrawals` works correctly
    function test_WM_07_cancellableScheduledWithdrawals_works_correctly() public {
        CancellableScheduledWithdrawalsCase[4] memory cases = [
            CancellableScheduledWithdrawalsCase({
                name: "cancel, both slots mature",
                isForceCancel: false,
                task0: ScheduleTask.MATURE,
                task1: ScheduleTask.MATURE,
                expectedToken0: address(0),
                expectedAmount0: 0,
                expectedToken1: address(0),
                expectedAmount1: 0
            }),
            CancellableScheduledWithdrawalsCase({
                name: "cancel, slot 0 immature, slot 1 mature",
                isForceCancel: false,
                task0: ScheduleTask.IMMATURE,
                task1: ScheduleTask.MATURE,
                expectedToken0: address(token0),
                expectedAmount0: AMOUNT - 1,
                expectedToken1: address(0),
                expectedAmount1: 0
            }),
            CancellableScheduledWithdrawalsCase({
                name: "force cancel, slot 0 immature, slot 1 mature",
                isForceCancel: true,
                task0: ScheduleTask.IMMATURE,
                task1: ScheduleTask.MATURE,
                expectedToken0: address(token0),
                expectedAmount0: AMOUNT - 1,
                expectedToken1: address(token1),
                expectedAmount1: AMOUNT - 1
            }),
            CancellableScheduledWithdrawalsCase({
                name: "force cancel, both slots mature",
                isForceCancel: true,
                task0: ScheduleTask.MATURE,
                task1: ScheduleTask.MATURE,
                expectedToken0: address(token0),
                expectedAmount0: AMOUNT - 1,
                expectedToken1: address(token1),
                expectedAmount1: AMOUNT - 1
            })
        ];

        uint256 snapshot = vm.snapshot();
        for (uint256 i; i < cases.length; ++i) {
            _addScheduledWithdrawal({slot: 0, task: cases[i].task0});
            _addScheduledWithdrawal({slot: 1, task: cases[i].task1});

            (address token0_, uint256 amount0, address token1_, uint256 amount1) =
                manager.cancellableScheduledWithdrawals(creditAccount, cases[i].isForceCancel);

            assertEq(token0_, cases[i].expectedToken0, _format("incorrect token0", cases[i].name));
            assertEq(amount0, cases[i].expectedAmount0, _format("incorrect amount0", cases[i].name));
            assertEq(token1_, cases[i].expectedToken1, _format("incorrect token0", cases[i].name));
            assertEq(amount1, cases[i].expectedAmount1, _format("incorrect amount1", cases[i].name));

            vm.revertTo(snapshot);
        }
    }

    /// ----------------------------------------------- ///
    /// SCHEDULED WITHDRAWALS: INTERNAL FUNCTIONS TESTS ///
    /// ----------------------------------------------- ///

    struct ProcessScheduledWithdrawalCase {
        string name;
        // scenario
        ClaimAction action;
        ScheduleTask task;
        // expected result
        bool shouldClaim;
        bool shouldCancel;
        bool expectedScheduled;
        bool expectedClaimed;
        uint256 expectedTokensToEnable;
    }

    /// @notice [WM-8]: `_processScheduledWithdrawal` works correctly
    function test_WM_08_processScheduledWithdrawal_works_correctly() public {
        ProcessScheduledWithdrawalCase[12] memory cases = [
            ProcessScheduledWithdrawalCase({
                name: "immature withdrawal, action == CLAIM",
                action: ClaimAction.CLAIM,
                task: ScheduleTask.IMMATURE,
                shouldClaim: false,
                shouldCancel: false,
                expectedScheduled: true,
                expectedClaimed: false,
                expectedTokensToEnable: 0
            }),
            ProcessScheduledWithdrawalCase({
                name: "immature withdrawal, action == CANCEL",
                action: ClaimAction.CANCEL,
                task: ScheduleTask.IMMATURE,
                shouldClaim: false,
                shouldCancel: true,
                expectedScheduled: false,
                expectedClaimed: false,
                expectedTokensToEnable: TOKEN0_MASK
            }),
            ProcessScheduledWithdrawalCase({
                name: "immature withdrawal, action == FORCE_CLAIM",
                action: ClaimAction.FORCE_CLAIM,
                task: ScheduleTask.IMMATURE,
                shouldClaim: true,
                shouldCancel: false,
                expectedScheduled: false,
                expectedClaimed: true,
                expectedTokensToEnable: 0
            }),
            ProcessScheduledWithdrawalCase({
                name: "immature withdrawal, action == FORCE_CANCEL",
                action: ClaimAction.FORCE_CANCEL,
                task: ScheduleTask.IMMATURE,
                shouldClaim: false,
                shouldCancel: true,
                expectedScheduled: false,
                expectedClaimed: false,
                expectedTokensToEnable: TOKEN0_MASK
            }),
            ProcessScheduledWithdrawalCase({
                name: "mature withdrawal, action == CLAIM",
                action: ClaimAction.CLAIM,
                task: ScheduleTask.MATURE,
                shouldClaim: true,
                shouldCancel: false,
                expectedScheduled: false,
                expectedClaimed: true,
                expectedTokensToEnable: 0
            }),
            ProcessScheduledWithdrawalCase({
                name: "mature withdrawal, action == CANCEL",
                action: ClaimAction.CANCEL,
                task: ScheduleTask.MATURE,
                shouldClaim: true,
                shouldCancel: false,
                expectedScheduled: false,
                expectedClaimed: true,
                expectedTokensToEnable: 0
            }),
            ProcessScheduledWithdrawalCase({
                name: "mature withdrawal, action == FORCE_CLAIM",
                action: ClaimAction.FORCE_CLAIM,
                task: ScheduleTask.MATURE,
                shouldClaim: true,
                shouldCancel: false,
                expectedScheduled: false,
                expectedClaimed: true,
                expectedTokensToEnable: 0
            }),
            ProcessScheduledWithdrawalCase({
                name: "mature withdrawal, action == FORCE_CANCEL",
                action: ClaimAction.FORCE_CANCEL,
                task: ScheduleTask.MATURE,
                shouldClaim: false,
                shouldCancel: true,
                expectedScheduled: false,
                expectedClaimed: false,
                expectedTokensToEnable: TOKEN0_MASK
            }),
            //
            ProcessScheduledWithdrawalCase({
                name: "non-scheduled withdrawal, action == CLAIM",
                action: ClaimAction.CLAIM,
                task: ScheduleTask.NON_SCHEDULED,
                shouldClaim: false,
                shouldCancel: false,
                expectedScheduled: false,
                expectedClaimed: false,
                expectedTokensToEnable: 0
            }),
            ProcessScheduledWithdrawalCase({
                name: "non-scheduled withdrawal, action == CANCEL",
                action: ClaimAction.CANCEL,
                task: ScheduleTask.NON_SCHEDULED,
                shouldClaim: false,
                shouldCancel: false,
                expectedScheduled: false,
                expectedClaimed: false,
                expectedTokensToEnable: 0
            }),
            ProcessScheduledWithdrawalCase({
                name: "non-scheduled withdrawal, action == FORCE_CLAIM",
                action: ClaimAction.FORCE_CLAIM,
                task: ScheduleTask.NON_SCHEDULED,
                shouldClaim: false,
                shouldCancel: false,
                expectedScheduled: false,
                expectedClaimed: false,
                expectedTokensToEnable: 0
            }),
            ProcessScheduledWithdrawalCase({
                name: "non-scheduled withdrawal, action == FORCE_CANCEL",
                action: ClaimAction.FORCE_CANCEL,
                task: ScheduleTask.NON_SCHEDULED,
                shouldClaim: false,
                shouldCancel: false,
                expectedScheduled: false,
                expectedClaimed: false,
                expectedTokensToEnable: 0
            })
        ];

        uint256 snapshot = vm.snapshot();
        for (uint256 i; i < cases.length; ++i) {
            _addScheduledWithdrawal({slot: 0, task: cases[i].task});

            if (cases[i].shouldClaim) {
                vm.expectEmit(true, true, false, false);
                emit ClaimScheduledWithdrawal(creditAccount, address(token0), address(0), 0);
            }
            if (cases[i].shouldCancel) {
                vm.expectEmit(true, true, false, false);
                emit CancelScheduledWithdrawal(creditAccount, address(token0), 0);
            }

            (bool scheduled, bool claimed, uint256 tokensToEnable) = manager.processScheduledWithdrawal({
                creditAccount: creditAccount,
                slot: 0,
                action: cases[i].action,
                to: user
            });

            assertEq(scheduled, cases[i].expectedScheduled, _format("incorrect scheduled", cases[i].name));
            assertEq(claimed, cases[i].expectedClaimed, _format("incorrect claimed", cases[i].name));
            assertEq(
                tokensToEnable, cases[i].expectedTokensToEnable, _format("incorrect tokensToEnable", cases[i].name)
            );

            vm.revertTo(snapshot);
        }
    }

    /// @notice [WM-9A]: `_claimScheduledWithdrawal` works correctly
    function test_WM_09A_claimScheduledWithdrawal_works_correctly() public {
        _addScheduledWithdrawal({slot: 0, task: ScheduleTask.MATURE});

        vm.expectEmit(true, true, false, true);
        emit ClaimScheduledWithdrawal(creditAccount, address(token0), user, AMOUNT - 1);

        manager.claimScheduledWithdrawal({creditAccount: creditAccount, slot: 0, to: user});

        assertEq(token0.balanceOf(address(manager)), 1, "Incorrect manager balance");
        assertEq(token0.balanceOf(user), AMOUNT - 1, "Incorrect recipient balance");

        ScheduledWithdrawal memory w = manager.scheduledWithdrawals(creditAccount)[0];
        assertEq(w.maturity, 1, "Withdrawal not cleared");
    }

    /// @notice [WM-9B]: `_claimScheduledWithdrawal` works correctly with blacklisted recipient
    function test_WM_09B_claimScheduledWithdrawal_works_correctly_with_blacklisted_recipient() public {
        _addScheduledWithdrawal({slot: 0, task: ScheduleTask.MATURE});
        token0.setBlacklisted(user, true);

        vm.expectEmit(true, true, false, true);
        emit ClaimScheduledWithdrawal(creditAccount, address(token0), user, AMOUNT - 1);

        vm.expectEmit(true, true, false, true);
        emit AddImmediateWithdrawal(user, address(token0), AMOUNT - 1);

        manager.claimScheduledWithdrawal({creditAccount: creditAccount, slot: 0, to: user});

        assertEq(token0.balanceOf(address(manager)), AMOUNT, "Incorrect manager balance");

        ScheduledWithdrawal memory w = manager.scheduledWithdrawals(creditAccount)[0];
        assertEq(w.maturity, 1, "Withdrawal not cleared");
    }

    /// @notice [WM-10]: `_cancelScheduledWithdrawal` works correctly
    function test_WM_10_cancelScheduledWithdrawal_works_correctly() public {
        _addScheduledWithdrawal({slot: 0, task: ScheduleTask.MATURE});

        vm.expectEmit(true, true, false, true);
        emit CancelScheduledWithdrawal(creditAccount, address(token0), AMOUNT - 1);

        uint256 tokensToEnable = manager.cancelScheduledWithdrawal({creditAccount: creditAccount, slot: 0});

        assertEq(token0.balanceOf(address(manager)), 1, "Incorrect manager balance");
        assertEq(token0.balanceOf(creditAccount), AMOUNT - 1, "Incorrect credit account balance");
        assertEq(tokensToEnable, TOKEN0_MASK, "Incorrect tokensToEnable");
    }

    /// ------------------- ///
    /// CONFIGURATION TESTS ///
    /// ------------------- ///

    /// @notice [WM-12]: `setWithdrawalDelay` works correctly
    function test_WM_12_setWithdrawalDelay_works_correctly() public {
        uint40 newDelay = 2 days;

        vm.expectEmit(false, false, false, true);
        emit SetWithdrawalDelay(newDelay);

        vm.prank(configurator);
        manager.setWithdrawalDelay(newDelay);

        assertEq(manager.delay(), newDelay, "Incorrect delay");
    }

    /// @notice [WM-11]: `setCreditManagerStatus` works correctly
    function test_WM_11_setCreditManagerStatus_works_correctly() public {
        address newCreditManager = makeAddr("NEW_CREDIT_MANAGER");

        vm.expectEmit(true, false, false, true);
        emit SetCreditManagerStatus(newCreditManager, true);

        vm.prank(configurator);
        manager.setCreditManagerStatus(newCreditManager, true);

        assertTrue(manager.creditManagerStatus(newCreditManager), "Incorrect credit manager status");
    }

    /// ------- ///
    /// HELPERS ///
    /// ------- ///

    function _addScheduledWithdrawal(uint8 slot, ScheduleTask task) internal {
        ScheduledWithdrawal memory withdrawal;
        if (task == ScheduleTask.NON_SCHEDULED) {
            withdrawal.amount = 1;
            withdrawal.maturity = 1;
        } else {
            address token = slot == 0 ? address(token0) : address(token1);
            deal(token, address(manager), AMOUNT);
            withdrawal.amount = AMOUNT;
            withdrawal.token = token;
            withdrawal.tokenIndex = slot == 0 ? TOKEN0_INDEX : TOKEN1_INDEX;
            withdrawal.maturity =
                task == ScheduleTask.MATURE ? uint40(block.timestamp - 1) : uint40(block.timestamp + 1);
        }
        manager.setWithdrawalSlot(creditAccount, slot, withdrawal);
    }

    function _format(string memory reason, string memory caseName) internal pure returns (string memory) {
        return string(abi.encodePacked(reason, ", case: ", caseName));
    }
}