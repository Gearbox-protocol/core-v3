// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CreditAccountV3} from "../../../credit/CreditAccountV3.sol";
import {CallerNotAccountFactoryException, CallerNotCreditManagerException} from "../../../interfaces/IExceptions.sol";

import {TestHelper} from "../../lib/helper.sol";

/// @title Credit account V3 unit test
/// @notice U:[CA]: Unit tests for credit account
contract CreditAccountV3UnitTest is TestHelper {
    CreditAccountV3 creditAccount;

    address factory;
    address creditManager;

    function setUp() public {
        factory = makeAddr("ACCOUNT_FACTORY");
        creditManager = makeAddr("CREDIT_MANAGER");

        vm.prank(factory);
        creditAccount = new CreditAccountV3(creditManager);
    }

    /// @notice U:[CA-1]: Constructor sets correct values
    function test_U_CA_01_constructor_sets_correct_values(address factory_, address creditManager_) public {
        vm.assume(factory_ != creditManager_);

        vm.prank(factory_);
        CreditAccountV3 creditAccount_ = new CreditAccountV3(creditManager_);

        assertEq(creditAccount_.factory(), factory_, "Incorrect factory");
        assertEq(creditAccount_.creditManager(), creditManager_, "Incorrect creditManager");
    }

    /// @notice U:[CA-2]: External functions have correct access
    function test_U_CA_02_external_functions_have_correct_access(address caller) public {
        vm.startPrank(caller);
        if (caller != creditManager) {
            vm.expectRevert(CallerNotCreditManagerException.selector);
            creditAccount.safeTransfer({token: address(0), to: address(0), amount: 0});
        }
        if (caller != creditManager) {
            vm.expectRevert(CallerNotCreditManagerException.selector);
            creditAccount.execute({target: address(0), data: bytes("")});
        }
        if (caller != factory) {
            vm.expectRevert(CallerNotAccountFactoryException.selector);
            creditAccount.rescue({target: address(0), data: bytes("")});
        }
        vm.stopPrank();
    }

    /// @notice U:[CA-3]: `safeTransfer` works correctly
    function test_U_CA_03_safeTransfer_works_correctly(address token, address to, uint256 amount) public {
        vm.assume(token != address(vm)); // just brilliant
        vm.mockCall(token, abi.encodeCall(IERC20.transfer, (to, amount)), bytes(""));
        vm.expectCall(token, abi.encodeCall(IERC20.transfer, (to, amount)));
        vm.prank(creditManager);
        creditAccount.safeTransfer({token: token, to: to, amount: amount});
    }

    /// @notice U:[CA-4]: `execute` works correctly
    function test_U_CA_04_execute_works_correctly(address target, bytes memory data, bytes memory expResult) public {
        vm.assume(target != address(vm));
        vm.mockCall(target, data, expResult);
        vm.expectCall(target, data);
        vm.prank(creditManager);
        bytes memory result = creditAccount.execute(target, data);
        assertEq(result, expResult, "Incorrect result");
    }

    /// @notice U:[CA-5]: `rescue` works correctly
    function test_U_CA_05_rescue_works_correctly(address target, bytes memory data) public {
        vm.assume(target != address(vm));
        vm.mockCall(target, data, bytes(""));
        vm.expectCall(target, data);
        vm.prank(factory);
        creditAccount.rescue(target, data);
    }
}
