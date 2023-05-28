// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {
    ReceiveIsNotAllowedException,
    RegisteredCreditManagerOnlyException,
    ZeroAddressException
} from "../../../interfaces/IExceptions.sol";
import {IWETHGatewayV3Events} from "../../../interfaces/IWETHGatewayV3.sol";
import {ENTERED} from "../../../traits/ReentrancyGuardTrait.sol";

import {AP_WETH_TOKEN, AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {WETHMock} from "../../mocks/token/WETHMock.sol";
import {WETHGatewayV3Harness} from "./WETHGatewayV3Harness.sol";

/// @title WETH gateway V3 unit test
/// @notice U:[WG]: Unit tests for WETH gateway
contract WETHGatewayV3UnitTest is Test, IWETHGatewayV3Events {
    using Address for address payable;

    WETHMock weth;
    WETHGatewayV3Harness gateway;
    AddressProviderV3ACLMock addressProvider;

    address user;
    address configurator;
    address creditManager;

    function setUp() public {
        user = makeAddr("USER");
        configurator = makeAddr("CONFIGURATOR");
        creditManager = makeAddr("CREDIT_MANAGER");

        vm.startPrank(configurator);
        weth = new WETHMock();

        addressProvider = new AddressProviderV3ACLMock();
        addressProvider.addCreditManager(creditManager);
        addressProvider.setAddress(AP_WETH_TOKEN, address(weth), false);

        gateway = new WETHGatewayV3Harness(address(addressProvider));
        vm.stopPrank();
    }

    /// @notice U:[WG-1A]: Constructor reverts on zero address
    function test_U_WG_01A_constructor_reverts_on_zero_address() public {
        vm.expectRevert(ZeroAddressException.selector);
        new WETHGatewayV3Harness(address(0));
    }

    /// @notice U:[WG-1B]: Constructor sets correct values
    function test_U_WG_01B_constructor_sets_correct_values() public {
        assertEq(gateway.weth(), address(weth), "Incorrect WETH token address");
    }

    /// @notice U:[WG-2]: `receive` works correctly
    function test_U_WG_02_receive_works_correctly() public {
        deal(user, 1 ether);
        vm.expectRevert(ReceiveIsNotAllowedException.selector);
        vm.prank(user);
        (bool success, bytes memory returndata) = address(gateway).call{value: 1 ether}("");
        Address.verifyCallResult(success, returndata, "");

        deal(address(weth), 1 ether);
        vm.prank(address(weth));
        payable(gateway).sendValue(1 ether);
        assertEq(address(gateway).balance, 1 ether, "Incorrect ETH balance");
    }

    /// @notice U:[WG-3A]: `deposit` reverts if called not by registered credit manager
    function test_U_WG_03A_deposit_reverts_if_called_not_by_credit_manager() public {
        vm.expectRevert(RegisteredCreditManagerOnlyException.selector);
        vm.prank(makeAddr("ANYONE"));
        gateway.deposit(address(0), 0);
    }

    /// @notice U:[WG-3B]: `deposit` works correctly
    function test_U_WG_03B_deposit_works_correctly(uint256 amount) public {
        vm.prank(creditManager);

        if (amount > 1) {
            vm.expectEmit(true, false, false, true);
            emit Deposit(user, amount);
        }

        gateway.deposit(user, amount);
        assertEq(gateway.balanceOf(user), amount > 1 ? amount : 0, "Incorrect balanceOf");
    }

    /// @notice U:[WG-4A]: `claim` is non-reentrant
    function test_U_WG_04A_claim_is_non_reentrant() public {
        gateway.setReentrancyStatus(ENTERED);
        vm.expectRevert("ReentrancyGuard: reentrant call");
        gateway.claim(address(0));
    }

    /// @notice U:[WG-4B]: `claim` works correctly
    function test_U_WG_04B_claim_works_correctly(uint256 amount) public {
        vm.assume(amount > 1);

        deal(address(weth), amount);
        deal(address(weth), address(gateway), amount);
        vm.prank(creditManager);
        gateway.deposit(user, amount);

        vm.expectCall(address(weth), abi.encodeCall(IWETH.withdraw, (amount - 1)));
        vm.expectCall(user, amount - 1, bytes(""));
        vm.expectEmit(true, false, false, true);
        emit Claim(user, amount - 1);

        gateway.claim(user);
        assertEq(gateway.balanceOf(user), 1, "Incorrect balanceOf");
    }
}
