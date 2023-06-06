// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {
    ClaimAction,
    ETH_ADDRESS,
    IWithdrawalManagerV3Events,
    ScheduledWithdrawal
} from "../../../interfaces/IWithdrawalManagerV3.sol";
import {
    AmountCantBeZeroException,
    CallerNotConfiguratorException,
    CallerNotCreditManagerException,
    NoFreeWithdrawalSlotsException,
    NothingToClaimException,
    ReceiveIsNotAllowedException,
    RegisteredCreditManagerOnlyException,
    ZeroAddressException
} from "../../../interfaces/IExceptions.sol";

import {Tokens} from "../../config/Tokens.sol";
import {USER} from "../../lib/constants.sol";
import {TestHelper} from "../../lib/helper.sol";
import {AddressProviderV3ACLMock, AP_WETH_TOKEN} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";
import {ERC20BlacklistableMock} from "../../mocks/token/ERC20Blacklistable.sol";
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";

import {WithdrawalManagerHarness} from "./WithdrawalManagerHarness.sol";

enum ScheduleTask {
    IMMATURE,
    MATURE,
    NON_SCHEDULED
}

/// @title Withdrawal manager unit test
/// @notice U:[WM]: Unit tests for withdrawal manager
contract WithdrawalManagerUnitTest is TestHelper, IWithdrawalManagerV3Events {
    WithdrawalManagerHarness manager;
    AddressProviderV3ACLMock acl;
    TokensTestSuite ts;
    ERC20BlacklistableMock token0;
    ERC20Mock token1;

    address configurator;
    address creditAccount;
    address creditManager;

    uint40 constant DELAY = 1 days;
    uint256 constant AMOUNT = 10 ether;
    uint8 constant TOKEN0_INDEX = 0;
    uint256 constant TOKEN0_MASK = 1;
    uint8 constant TOKEN1_INDEX = 1;
    uint256 constant TOKEN1_MASK = 2;

    function setUp() public {
        configurator = makeAddr("CONFIGURATOR");
        creditAccount = makeAddr("CREDIT_ACCOUNT");
        creditManager = makeAddr("CREDIT_MANAGER");

        ts = new TokensTestSuite();
        ts.topUpWETH{value: AMOUNT}();
        token0 = ERC20BlacklistableMock(ts.addressOf(Tokens.USDC));
        token1 = ERC20Mock(ts.addressOf(Tokens.WETH));

        vm.startPrank(configurator);
        acl = new AddressProviderV3ACLMock();
        acl.setAddress(AP_WETH_TOKEN, address(token1), false);
        acl.addCreditManager(creditManager);
        manager = new WithdrawalManagerHarness(address(acl), DELAY);
        manager.addCreditManager(creditManager);
        vm.stopPrank();
    }

    // ------------- //
    // GENERAL TESTS //
    // ------------- //

    /// @notice U:[WM-1]: Constructor sets correct values
    function test_U_WM_01_constructor_sets_correct_values() public {
        assertEq(manager.delay(), DELAY, "Incorrect delay");
    }

    /// @notice U:[WM-2]: External functions have correct access
    function test_U_WM_02_external_functions_have_correct_access() public {
        vm.startPrank(USER);

        deal(USER, 1 ether);
        vm.expectRevert(ReceiveIsNotAllowedException.selector);
        payable(manager).transfer(1 ether);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        manager.addImmediateWithdrawal(address(0), address(0), 0);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        manager.addScheduledWithdrawal(address(0), address(0), 0, 0);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        manager.claimScheduledWithdrawals(address(0), address(0), ClaimAction(0));

        vm.expectRevert(CallerNotConfiguratorException.selector);
        manager.setWithdrawalDelay(0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        manager.addCreditManager(address(0));

        vm.stopPrank();
    }

    // --------------------------- //
    // IMMEDIATE WITHDRAWALS TESTS //
    // --------------------------- //

    /// @notice U:[WM-3]: `addImmediateWithdrawal` works correctly
    function test_U_WM_03_addImmediateWithdrawal_works_correctly() public {
        vm.startPrank(creditManager);

        // add first withdrawal
        deal(address(token0), address(manager), AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit AddImmediateWithdrawal(USER, address(token0), AMOUNT);

        manager.addImmediateWithdrawal(address(token0), USER, AMOUNT);

        assertEq(
            manager.immediateWithdrawals(USER, address(token0)),
            AMOUNT,
            "Incorrect claimable balance after adding first withdrawal"
        );

        // add second withdrawal in the same token
        deal(address(token0), address(manager), AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit AddImmediateWithdrawal(USER, address(token0), AMOUNT);

        manager.addImmediateWithdrawal(address(token0), USER, AMOUNT);

        assertEq(
            manager.immediateWithdrawals(USER, address(token0)),
            2 * AMOUNT,
            "Incorrect claimable balance after adding second withdrawal"
        );

        vm.stopPrank();
    }

    /// @notice U:[WM-4A]: `claimImmediateWithdrawal` reverts on zero recipient
    function test_U_WM_04A_claimImmediateWithdrawal_reverts_on_zero_recipient() public {
        vm.expectRevert(ZeroAddressException.selector);
        vm.prank(USER);
        manager.claimImmediateWithdrawal(address(token0), address(0));
    }

    /// @notice U:[WM-4B]: `claimImmediateWithdrawal` reverts on nothing to claim
    function test_U_WM_04B_claimImmediateWithdrawal_reverts_on_nothing_to_claim() public {
        vm.expectRevert(NothingToClaimException.selector);
        vm.prank(USER);
        manager.claimImmediateWithdrawal(address(token0), address(USER));
    }

    /// @notice U:[WM-4C]: `claimImmediateWithdrawal` works correctly
    function test_U_WM_04C_claimImmediateWithdrawal_works_correctly() public {
        deal(address(token0), address(manager), AMOUNT);

        vm.prank(creditManager);
        manager.addImmediateWithdrawal(address(token0), USER, AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit ClaimImmediateWithdrawal(USER, address(token0), USER, AMOUNT - 1);

        vm.prank(USER);
        manager.claimImmediateWithdrawal(address(token0), USER);

        assertEq(manager.immediateWithdrawals(USER, address(token0)), 1, "Incorrect claimable balance");
        assertEq(ts.balanceOf(Tokens.USDC, USER), AMOUNT - 1, "Incorrect claimed amount");
    }

    /// @notice U:[WM-4D]: `claimImmediateWithdrawal` works correctly with Ether
    function test_U_WM_04D_claimImmediateWithdrawal_works_correctly_with_ether() public {
        deal(address(token1), address(manager), AMOUNT);

        vm.prank(creditManager);
        manager.addImmediateWithdrawal(address(token1), USER, AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit ClaimImmediateWithdrawal(USER, address(token1), USER, AMOUNT - 1);

        vm.prank(USER);
        manager.claimImmediateWithdrawal(ETH_ADDRESS, USER);

        assertEq(manager.immediateWithdrawals(USER, address(token1)), 1, "Incorrect claimable balance");
        assertEq(address(USER).balance, AMOUNT - 1, "Incorrect claimed amount");
    }

    // ----------------------------------------------- //
    // SCHEDULED WITHDRAWALS: EXTERNAL FUNCTIONS TESTS //
    // ----------------------------------------------- //

    /// @notice U:[WM-5A]: `addScheduledWithdrawal` reverts on zero amount
    function test_U_WM_05A_addScheduledWithdrawal_reverts_on_zero_amount() public {
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

    /// @notice U:[WM-5B]: `addScheduledWithdrawal` works correctly
    function test_U_WM_05B_addScheduledWithdrawal_works_correctly() public {
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
                assertEq(w.tokenIndex, TOKEN0_INDEX, _testCaseErr(cases[i].name, "incorrect token index"));
                assertEq(w.token, address(token0), _testCaseErr(cases[i].name, "incorrect token"));
                assertEq(w.maturity, expectedMaturity, _testCaseErr(cases[i].name, "incorrect maturity"));
                assertEq(w.amount, AMOUNT, _testCaseErr(cases[i].name, "incorrect amount"));
            }

            vm.revertTo(snapshot);
        }
    }

    /// @notice U:[WM-6A]: `claimScheduledWithdrawals` reverts on nothing to claim when action is `CLAIM`
    function test_U_WM_06A_claimScheduledWithdrawals_reverts_on_nothing_to_claim() public {
        _addScheduledWithdrawal({slot: 0, task: ScheduleTask.IMMATURE});
        _addScheduledWithdrawal({slot: 1, task: ScheduleTask.NON_SCHEDULED});
        vm.expectRevert(NothingToClaimException.selector);
        vm.prank(creditManager);
        manager.claimScheduledWithdrawals(creditAccount, USER, ClaimAction.CLAIM);
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

    /// @notice U:[WM-6B]: `claimScheduledWithdrawals` works correctly
    function test_U_WM_06B_claimScheduledWithdrawals_works_correctly() public {
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
                manager.claimScheduledWithdrawals(creditAccount, USER, cases[i].action);

            assertEq(hasScheduled, cases[i].expectedHasScheduled, _testCaseErr(cases[i].name, "incorrect hasScheduled"));
            assertEq(
                tokensToEnable, cases[i].expectedTokensToEnable, _testCaseErr(cases[i].name, "incorrect tokensToEnable")
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

    /// @notice U:[WM-7]: `cancellableScheduledWithdrawals` works correctly
    function test_U_WM_07_cancellableScheduledWithdrawals_works_correctly() public {
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

            assertEq(token0_, cases[i].expectedToken0, _testCaseErr(cases[i].name, "incorrect token0"));
            assertEq(amount0, cases[i].expectedAmount0, _testCaseErr(cases[i].name, "incorrect amount0"));
            assertEq(token1_, cases[i].expectedToken1, _testCaseErr(cases[i].name, "incorrect token0"));
            assertEq(amount1, cases[i].expectedAmount1, _testCaseErr(cases[i].name, "incorrect amount1"));

            vm.revertTo(snapshot);
        }
    }

    // ----------------------------------------------- //
    // SCHEDULED WITHDRAWALS: INTERNAL FUNCTIONS TESTS //
    // ----------------------------------------------- //

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

    /// @notice U:[WM-8]: `_processScheduledWithdrawal` works correctly
    function test_U_WM_08_processScheduledWithdrawal_works_correctly() public {
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
                to: USER
            });

            assertEq(scheduled, cases[i].expectedScheduled, _testCaseErr(cases[i].name, "incorrect scheduled"));
            assertEq(claimed, cases[i].expectedClaimed, _testCaseErr(cases[i].name, "incorrect claimed"));
            assertEq(
                tokensToEnable, cases[i].expectedTokensToEnable, _testCaseErr(cases[i].name, "incorrect tokensToEnable")
            );

            vm.revertTo(snapshot);
        }
    }

    /// @notice U:[WM-9A]: `_claimScheduledWithdrawal` works correctly
    function test_U_WM_09A_claimScheduledWithdrawal_works_correctly() public {
        _addScheduledWithdrawal({slot: 0, task: ScheduleTask.MATURE});

        vm.expectEmit(true, true, false, true);
        emit ClaimScheduledWithdrawal(creditAccount, address(token0), USER, AMOUNT - 1);

        manager.claimScheduledWithdrawal({creditAccount: creditAccount, slot: 0, to: USER});

        assertEq(token0.balanceOf(address(manager)), 1, "Incorrect manager balance");
        assertEq(token0.balanceOf(USER), AMOUNT - 1, "Incorrect recipient balance");

        ScheduledWithdrawal memory w = manager.scheduledWithdrawals(creditAccount)[0];
        assertEq(w.maturity, 1, "Withdrawal not cleared");
    }

    /// @notice U:[WM-9B]: `_claimScheduledWithdrawal` works correctly with blacklisted recipient
    function test_U_WM_09B_claimScheduledWithdrawal_works_correctly_with_blacklisted_recipient() public {
        _addScheduledWithdrawal({slot: 0, task: ScheduleTask.MATURE});
        token0.setBlacklisted(USER, true);

        vm.expectEmit(true, true, false, true);
        emit ClaimScheduledWithdrawal(creditAccount, address(token0), USER, AMOUNT - 1);

        vm.expectEmit(true, true, false, true);
        emit AddImmediateWithdrawal(USER, address(token0), AMOUNT - 1);

        manager.claimScheduledWithdrawal({creditAccount: creditAccount, slot: 0, to: USER});

        assertEq(token0.balanceOf(address(manager)), AMOUNT, "Incorrect manager balance");

        ScheduledWithdrawal memory w = manager.scheduledWithdrawals(creditAccount)[0];
        assertEq(w.maturity, 1, "Withdrawal not cleared");
    }

    /// @notice U:[WM-10]: `_cancelScheduledWithdrawal` works correctly
    function test_U_WM_10_cancelScheduledWithdrawal_works_correctly() public {
        _addScheduledWithdrawal({slot: 0, task: ScheduleTask.MATURE});

        vm.expectEmit(true, true, false, true);
        emit CancelScheduledWithdrawal(creditAccount, address(token0), AMOUNT - 1);

        uint256 tokensToEnable = manager.cancelScheduledWithdrawal({creditAccount: creditAccount, slot: 0});

        assertEq(token0.balanceOf(address(manager)), 1, "Incorrect manager balance");
        assertEq(token0.balanceOf(creditAccount), AMOUNT - 1, "Incorrect credit account balance");
        assertEq(tokensToEnable, TOKEN0_MASK, "Incorrect tokensToEnable");
    }

    // ------------------- //
    // CONFIGURATION TESTS //
    // ------------------- //

    /// @notice U:[WM-11]: `setWithdrawalDelay` works correctly
    function test_U_WM_11_setWithdrawalDelay_works_correctly() public {
        uint40 newDelay = 2 days;

        vm.expectEmit(false, false, false, true);
        emit SetWithdrawalDelay(newDelay);

        vm.prank(configurator);
        manager.setWithdrawalDelay(newDelay);

        assertEq(manager.delay(), newDelay, "Incorrect delay");
    }

    /// @notice U:[WM-12A]: `addCreditManager` reverts for non-registered credit manager
    function test_U_WM_12A_addCreditManager_reverts_for_non_registered_credit_manager() public {
        vm.expectRevert(RegisteredCreditManagerOnlyException.selector);
        vm.prank(configurator);
        manager.addCreditManager(address(0));
    }

    /// @notice U:[WM-12B]: `addCreditManager` works correctly
    function test_U_WM_12B_addCreditManager_works_correctly() public {
        manager = new WithdrawalManagerHarness(address(acl), DELAY);
        assertEq(manager.creditManagers().length, 0, "Incorrect credit managers list length before adding");

        vm.expectEmit(true, false, false, false);
        emit AddCreditManager(creditManager);

        vm.prank(configurator);
        manager.addCreditManager(creditManager);

        address[] memory cms = manager.creditManagers();
        assertEq(cms.length, 1, "Incorrect credit managers list length after adding");
        assertEq(cms[0], creditManager, "Incorrect credit manager address");
    }

    // ------- //
    // HELPERS //
    // ------- //

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
}
