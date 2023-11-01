// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {ETH_ADDRESS, IWithdrawalManagerV3Events} from "../../../interfaces/IWithdrawalManagerV3.sol";
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

import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import {USER} from "../../lib/constants.sol";
import {TestHelper} from "../../lib/helper.sol";
import {AddressProviderV3ACLMock, AP_WETH_TOKEN} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";
import {ERC20BlacklistableMock} from "../../mocks/token/ERC20Blacklistable.sol";
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";

import {WithdrawalManagerV3Harness} from "./WithdrawalManagerV3Harness.sol";

enum ScheduleTask {
    IMMATURE,
    MATURE,
    NON_SCHEDULED
}

/// @title Withdrawal manager V3 unit test
/// @notice U:[WM]: Unit tests for withdrawal manager
contract WithdrawalManagerV3UnitTest is TestHelper, IWithdrawalManagerV3Events {
    WithdrawalManagerV3Harness manager;
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
        manager = new WithdrawalManagerV3Harness(address(acl));
        manager.addCreditManager(creditManager);
        vm.stopPrank();
    }

    // ------------- //
    // GENERAL TESTS //
    // ------------- //

    /// @notice U:[WM-2]: External functions have correct access
    function test_U_WM_02_external_functions_have_correct_access() public {
        vm.startPrank(USER);

        deal(USER, 1 ether);
        vm.expectRevert(ReceiveIsNotAllowedException.selector);
        payable(manager).transfer(1 ether);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        manager.addImmediateWithdrawal(address(0), address(0), 0);

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

    // ------------------- //
    // CONFIGURATION TESTS //
    // ------------------- //

    /// @notice U:[WM-12A]: `addCreditManager` reverts for non-registered credit manager
    function test_U_WM_12A_addCreditManager_reverts_for_non_registered_credit_manager() public {
        vm.expectRevert(RegisteredCreditManagerOnlyException.selector);
        vm.prank(configurator);
        manager.addCreditManager(address(0));
    }

    /// @notice U:[WM-12B]: `addCreditManager` works correctly
    function test_U_WM_12B_addCreditManager_works_correctly() public {
        manager = new WithdrawalManagerV3Harness(address(acl));

        vm.expectEmit(true, false, false, false);
        emit AddCreditManager(creditManager);

        vm.prank(configurator);
        manager.addCreditManager(creditManager);

        assertTrue(manager.isValidCreditManager(creditManager), "Credit Manager status was not set");
    }
}
