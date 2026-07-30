// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";

import {CreditAccountV3} from "../../../credit/CreditAccountV3.sol";
import {IDefaultAccountFactoryV3Events} from "../../../interfaces/IDefaultAccountFactoryV3.sol";
import {
    CallerNotCreditManagerException,
    MasterCreditAccountAlreadyDeployedException
} from "../../../interfaces/IExceptions.sol";

import {TestHelper} from "../../lib/helper.sol";

import {DefaultAccountFactoryV3Harness} from "./DefaultAccountFactoryV3Harness.sol";

/// @title Default account factory V3 unit test
/// @notice U:[AF]: Unit tests for account factory
contract DefaultAccountFactoryV3UnitTest is TestHelper, IDefaultAccountFactoryV3Events {
    DefaultAccountFactoryV3Harness accountFactory;

    address creditManager;

    function setUp() public {
        AddressProviderV3ACLMock addressProvider = new AddressProviderV3ACLMock();
        accountFactory = new DefaultAccountFactoryV3Harness(address(addressProvider));

        creditManager = makeAddr("CREDIT_MANAGER");
        accountFactory.addCreditManager(creditManager);
    }

    /// @notice U:[AF-1]: External functions have correct access
    function test_U_AF_01_external_functions_have_correct_access(address caller) public {
        vm.assume(caller != creditManager);

        vm.expectRevert(CallerNotCreditManagerException.selector);
        vm.prank(caller);
        accountFactory.takeCreditAccount(0, 0);
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
}
