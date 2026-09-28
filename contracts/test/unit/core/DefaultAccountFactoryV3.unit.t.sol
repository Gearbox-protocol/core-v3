// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";

import {CreditAccountV3} from "../../../credit/CreditAccountV3.sol";
import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";
import {IDefaultAccountFactoryV3Events} from "../../../interfaces/IDefaultAccountFactoryV3.sol";
import {CreditAccountInfo} from "../../../interfaces/ICreditManagerV3.sol";
import {
    CallerNotCreditManagerException,
    CreditAccountIsInUseException,
    MasterCreditAccountAlreadyDeployedException
} from "../../../interfaces/IExceptions.sol";

import {TestHelper} from "../../lib/helper.sol";

import {DefaultAccountFactoryV3Harness} from "./DefaultAccountFactoryV3Harness.sol";

/// @title Default account factory V3 unit test
/// @notice U:[AF]: Unit tests for account factory
contract DefaultAccountFactoryV3UnitTest is TestHelper, IDefaultAccountFactoryV3Events {
    DefaultAccountFactoryV3Harness accountFactory;

    address owner;
    address creditManager;

    function setUp() public {
        AddressProviderV3ACLMock addressProvider = new AddressProviderV3ACLMock();
        accountFactory = new DefaultAccountFactoryV3Harness(address(addressProvider));

        owner = accountFactory.owner();
        creditManager = makeAddr("CREDIT_MANAGER");
        accountFactory.addCreditManager(creditManager);
    }

    /// @notice U:[AF-1]: External functions have correct access
    function test_U_AF_01_external_functions_have_correct_access(address caller) public {
        vm.startPrank(caller);
        if (caller != creditManager) {
            vm.expectRevert(CallerNotCreditManagerException.selector);
            accountFactory.takeCreditAccount(0, 0);
        }
        if (caller != owner) {
            vm.expectRevert("Ownable: caller is not the owner");
            accountFactory.rescue(address(0), address(0), bytes(""));
        }
        vm.stopPrank();
    }

    /// @notice U:[AF-2]: `takeCreditAccount` always deploys a new credit account
    function test_U_AF_02_takeCreditAccount_deploys_new_credit_account() public {
        vm.expectEmit(false, true, false, false);
        emit DeployCreditAccount(address(0), creditManager);

        vm.expectEmit(false, true, false, false);
        emit TakeCreditAccount(address(0), creditManager);

        vm.prank(creditManager);
        address creditAccount = accountFactory.takeCreditAccount(0, 0);

        assertNotEq(creditAccount, address(0), "Incorrect clone account");
        assertEq(CreditAccountV3(creditAccount).factory(), address(accountFactory), "Incorrect clone account's factory");
        assertEq(
            CreditAccountV3(creditAccount).creditManager(), creditManager, "Incorrect clone account's creditManager"
        );
    }

    /// @notice U:[AF-3]: `returnCreditAccount` is a no-op
    function test_U_AF_03_returnCreditAccount_is_noop(address caller, address creditAccount) public {
        vm.prank(caller);
        accountFactory.returnCreditAccount(creditAccount);
    }

    /// @notice U:[AF-4A]: `addCreditManager` reverts on already added credit manager
    function test_U_AF_04A_addCreditManager_reverts_on_already_added_credit_manager(
        address creditAccount,
        address manager
    ) public {
        vm.assume(manager != creditManager && creditAccount != address(0));

        accountFactory.setMasterCreditAccount(manager, creditAccount);

        vm.expectRevert(MasterCreditAccountAlreadyDeployedException.selector);
        accountFactory.addCreditManager(manager);
    }

    /// @notice U:[AF-4B]: `addCreditManager` works correctly
    function test_U_AF_04B_addCreditManager_works_correctly(address manager) public {
        vm.assume(manager != creditManager);

        vm.expectEmit(true, false, false, false);
        emit AddCreditManager(manager, address(0));

        accountFactory.addCreditManager(manager);

        address account = accountFactory.masterCreditAccount(manager);
        assertNotEq(account, address(0), "Incorrect master account");
        assertEq(CreditAccountV3(account).factory(), address(accountFactory), "Incorrect master account's factory");
        assertEq(CreditAccountV3(account).creditManager(), manager, "Incorrect master account's creditManager");
    }

    /// @notice U:[AF-5A]: `rescue` reverts when credit account is in use
    function test_U_AF_05A_rescue_reverts_when_credit_account_is_in_use(address creditAccount, address borrower)
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
        vm.prank(owner);
        accountFactory.rescue(creditAccount, address(0), bytes(""));
    }

    /// @notice U:[AF-5B]: `rescue` works correctly
    function test_U_AF_05B_rescue_works_correctly(address creditAccount, address target, bytes calldata data) public {
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

        vm.expectEmit(true, true, true, true);
        emit Rescue(creditAccount, target, data);

        vm.expectCall(creditAccount, abi.encodeCall(CreditAccountV3(creditAccount).rescue, (target, data)));
        vm.prank(owner);
        accountFactory.rescue(creditAccount, target, data);
    }
}
