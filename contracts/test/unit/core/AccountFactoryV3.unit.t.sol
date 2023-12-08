// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {CreditAccountV3} from "../../../credit/CreditAccountV3.sol";
import {CreditAccountInfo, CreditManagerV3} from "../../../credit/CreditManagerV3.sol";
import {IAccountFactoryV3Events} from "../../../interfaces/IAccountFactoryV3.sol";
import {
    CallerNotConfiguratorException,
    CallerNotCreditManagerException,
    CreditAccountIsInUseException,
    MasterCreditAccountAlreadyDeployedException,
    RegisteredCreditManagerOnlyException
} from "../../../interfaces/IExceptions.sol";

import {TestHelper} from "../../lib/helper.sol";
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";

import {AccountFactoryV3Harness, FactoryParams, QueuedAccount} from "./AccountFactoryV3Harness.sol";

/// @title Account factory V3 unit test
/// @notice U:[AF]: Unit tests for account factory
contract AccountFactoryV3UnitTest is TestHelper, IAccountFactoryV3Events {
    AccountFactoryV3Harness accountFactory;
    AddressProviderV3ACLMock addressProvider;

    address configurator;
    address creditManager;

    function setUp() public {
        configurator = makeAddr("CONFIGURATOR");
        creditManager = makeAddr("CREDIT_MANAGER");

        vm.startPrank(configurator);
        addressProvider = new AddressProviderV3ACLMock();
        addressProvider.addCreditManager(creditManager);
        accountFactory = new AccountFactoryV3Harness(address(addressProvider));
        accountFactory.addCreditManager(creditManager);
        vm.stopPrank();
    }

    /// @notice U:[AF-1]: External functions have correct access
    function test_U_AF_01_external_functions_have_correct_access(address caller) public {
        vm.startPrank(caller);
        if (caller != creditManager) {
            vm.expectRevert(CallerNotCreditManagerException.selector);
            accountFactory.takeCreditAccount(0, 0);
        }
        if (caller != creditManager) {
            vm.expectRevert(CallerNotCreditManagerException.selector);
            accountFactory.returnCreditAccount(address(0));
        }
        if (caller != configurator) {
            vm.expectRevert(CallerNotConfiguratorException.selector);
            accountFactory.addCreditManager(address(0));
        }
        if (caller != configurator) {
            vm.expectRevert(CallerNotConfiguratorException.selector);
            accountFactory.rescue(address(0), address(0), bytes(""));
        }
        vm.stopPrank();
    }

    /// @notice U:[AF-2A]: `takeCreditAccount` works correctly when queue has no reusable accounts
    function test_U_AF_02A_takeCreditAccount_works_correctly_when_queue_has_no_reusable_accounts(
        uint40 head,
        uint40 tail
    ) public {
        tail = uint40(bound(tail, 0, 512));
        head = uint40(bound(head, 0, tail));
        FactoryParams memory fp = accountFactory.factoryParams(creditManager);
        accountFactory.setFactoryParams(creditManager, fp.masterCreditAccount, head, tail);
        if (head < tail) {
            accountFactory.setQueuedAccount(creditManager, head, address(0), uint40(block.timestamp + 1));
        }

        vm.expectEmit(false, true, false, false);
        emit DeployCreditAccount(address(0), creditManager);

        vm.expectEmit(false, true, false, false);
        emit TakeCreditAccount(address(0), creditManager);

        vm.prank(creditManager);
        address creditAccount = accountFactory.takeCreditAccount(0, 0);

        assertNotEq(creditAccount, address(0), "Incorrect clone account");
        assertEq(CreditAccountV3(creditAccount).factory(), address(accountFactory), "Incorrect clone account's factory");
        assertEq(
            CreditAccountV3(creditAccount).creditManager(), creditManager, "Incorrect cline deployed's creditManager"
        );
    }

    /// @notice U:[AF-2B]: `takeCreditAccount` works correctly when queue has reusable accounts
    function test_U_AF_02B_takeCreditAccount_works_correctly_when_queue_has_reusable_accounts(
        address creditAccount,
        uint40 head,
        uint40 tail
    ) public {
        tail = uint40(bound(tail, 1, 512));
        head = uint40(bound(head, 0, tail - 1));

        FactoryParams memory fp = accountFactory.factoryParams(creditManager);
        accountFactory.setFactoryParams(creditManager, fp.masterCreditAccount, head, tail);
        accountFactory.setQueuedAccount(creditManager, head, creditAccount, uint40(block.timestamp - 1));

        vm.expectEmit(true, true, false, false);
        emit TakeCreditAccount(creditAccount, creditManager);

        vm.prank(creditManager);
        address result = accountFactory.takeCreditAccount(0, 0);

        assertEq(result, creditAccount, "Incorrect creditAccount");
        assertEq(accountFactory.factoryParams(creditManager).head, uint40(head) + 1, "Incorrect head");
    }

    /// @notice U:[AF-3]: `returnCreditAccount` works correctly
    function test_U_AF_03_returnCreditAccount_works_correctly(address creditAccount, uint8 tail) public {
        FactoryParams memory fp = accountFactory.factoryParams(creditManager);
        accountFactory.setFactoryParams(creditManager, fp.masterCreditAccount, fp.head, tail);

        vm.expectEmit(true, true, false, false);
        emit ReturnCreditAccount(creditAccount, creditManager);

        vm.prank(creditManager);
        accountFactory.returnCreditAccount(creditAccount);

        QueuedAccount memory qa = accountFactory.queuedAccounts(creditManager, tail);
        assertEq(qa.creditAccount, creditAccount, "Incorrect creditAccount");
        assertEq(qa.reusableAfter, uint40(block.timestamp + 3 days), "Incorrect reusableAfter");
        assertEq(accountFactory.factoryParams(creditManager).tail, uint40(tail) + 1, "Incorrect tail");
    }

    /// @notice U:[AF-4A]: `addCreditManager` reverts on non-registered credit manager
    function test_U_AF_04A_addCreditManager_reverts_on_non_registered_credit_manager(address manager) public {
        vm.assume(manager != creditManager);
        vm.expectRevert(RegisteredCreditManagerOnlyException.selector);
        vm.prank(configurator);
        accountFactory.addCreditManager(manager);
    }

    /// @notice U:[AF-4B]: `addCreditManager` reverts on already added credit manager
    function test_U_AF_04B_addCreditManager_reverts_on_already_added_credit_manager(
        address creditAccount,
        address manager
    ) public {
        vm.assume(manager != creditManager && creditAccount != address(0));

        addressProvider.addCreditManager(manager);
        accountFactory.setFactoryParams(manager, creditAccount, 0, 0);

        vm.expectRevert(MasterCreditAccountAlreadyDeployedException.selector);
        vm.prank(configurator);
        accountFactory.addCreditManager(manager);
    }

    /// @notice U:[AF-4C]: `addCreditManager` works correctly
    function test_U_AF_04C_addCreditManager_works_correctly(address manager) public {
        vm.assume(manager != creditManager);
        addressProvider.addCreditManager(manager);

        vm.expectEmit(true, false, false, false);
        emit AddCreditManager(manager, address(0));

        vm.prank(configurator);
        accountFactory.addCreditManager(manager);

        address account = accountFactory.factoryParams(manager).masterCreditAccount;
        assertNotEq(account, address(0), "Incorrect master account");
        assertEq(CreditAccountV3(account).factory(), address(accountFactory), "Incorrect master account's factory");
        assertEq(CreditAccountV3(account).creditManager(), manager, "Incorrect master account's creditManager");
    }

    /// @notice U:[AF-5A]: `rescue` reverts on non-registered credit manager
    function test_U_AF_05A_rescue_reverts_on_non_registered_credit_manager(address creditAccount, address manager)
        public
    {
        vm.assume(creditAccount != address(vm) && creditAccount != CONSOLE && manager != creditManager);

        vm.mockCall(
            creditAccount, abi.encodeCall(CreditAccountV3(creditAccount).creditManager, ()), abi.encode(manager)
        );

        vm.expectRevert(RegisteredCreditManagerOnlyException.selector);
        vm.prank(configurator);
        accountFactory.rescue(creditAccount, address(0), bytes(""));
    }

    /// @notice U:[AF-5B]: `rescue` reverts when credit account is in use
    function test_U_AF_05B_rescue_reverts_when_credit_account_is_in_use(address creditAccount, address borrower)
        public
    {
        vm.assume(creditAccount != address(vm) && creditAccount != CONSOLE && borrower != address(0));

        CreditAccountInfo memory info;
        info.borrower = borrower;
        vm.mockCall(
            creditAccount, abi.encodeCall(CreditAccountV3(creditAccount).creditManager, ()), abi.encode(creditManager)
        );
        vm.mockCall(
            creditManager,
            abi.encodeCall(CreditManagerV3(creditManager).creditAccountInfo, (creditAccount)),
            abi.encode(info)
        );

        vm.expectRevert(CreditAccountIsInUseException.selector);
        vm.prank(configurator);
        accountFactory.rescue(creditAccount, address(0), bytes(""));
    }

    /// @notice U:[AF-5C]: `rescue` works correctly
    function test_U_AF_05C_rescue_works_correctly(address creditAccount, address target, bytes calldata data) public {
        vm.assume(creditAccount != address(vm) && creditAccount != CONSOLE);

        CreditAccountInfo memory info;
        vm.mockCall(
            creditAccount, abi.encodeCall(CreditAccountV3(creditAccount).creditManager, ()), abi.encode(creditManager)
        );
        vm.mockCall(
            creditManager,
            abi.encodeCall(CreditManagerV3(creditManager).creditAccountInfo, (creditAccount)),
            abi.encode(info)
        );
        vm.mockCall(creditAccount, abi.encodeCall(CreditAccountV3(creditAccount).rescue, (target, data)), bytes(""));

        vm.expectCall(creditAccount, abi.encodeCall(CreditAccountV3(creditAccount).rescue, (target, data)));
        vm.prank(configurator);
        accountFactory.rescue(creditAccount, target, data);
    }
}
