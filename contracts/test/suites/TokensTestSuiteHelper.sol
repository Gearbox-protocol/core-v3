// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";

import {ITokenTestSuite} from "../interfaces/ITokenTestSuite.sol";

// MOCKS
import {ERC20Mock} from "../mocks/token/ERC20Mock.sol";

import {Test} from "forge-std/Test.sol";

contract TokensTestSuiteHelper is Test, ITokenTestSuite {
    using SafeERC20 for IERC20;

    uint256 chainId;
    address public wethToken;

    function topUpWETH() public payable override {
        IWETH(wethToken).deposit{value: msg.value}();
    }

    function topUpWETH(address onBehalfOf, uint256 value) public override {
        vm.prank(onBehalfOf);
        IWETH(wethToken).deposit{value: value}();
    }

    function mint(address token, address to, uint256 amount) public virtual override {
        if (token == wethToken) {
            vm.deal(address(this), amount);
            IWETH(wethToken).deposit{value: amount}();
            IERC20(token).transfer(to, amount);
        } else {
            // ERC20Mock(token).mint(to, amount);
            if (chainId == 1337 || chainId == 31337) ERC20Mock(token).mint(to, amount);
            // Live test case
            else deal(token, to, amount, false);
        }
    }

    function balanceOf(address token, address holder) public view override returns (uint256 balance) {
        balance = IERC20(token).balanceOf(holder);
    }

    function approve(address token, address holder, address targetContract) public override {
        approve(token, holder, targetContract, type(uint256).max);
    }

    function approve(address token, address holder, address targetContract, uint256 amount) public override {
        vm.startPrank(holder);
        IERC20(token).forceApprove(targetContract, amount);
        vm.stopPrank();
    }

    function burn(address token, address from, uint256 amount) public override {
        ERC20Mock(token).burn(from, amount);
    }

    receive() external payable {}
}
