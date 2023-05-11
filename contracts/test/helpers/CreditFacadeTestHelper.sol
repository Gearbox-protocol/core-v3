// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {TokensTestSuite} from "../suites/TokensTestSuite.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CreditFacadeV3} from "../../credit/CreditFacadeV3.sol";
import {CreditConfigurator} from "../../credit/CreditConfiguratorV3.sol";
import {MultiCall} from "../../interfaces/ICreditFacade.sol";

import {ICreditFacadeMulticall} from "../../interfaces/ICreditFacade.sol";
import {ICreditManagerV3, ICreditManagerV3Events} from "../../interfaces/ICreditManagerV3.sol";

import {CreditFacadeTestSuite} from "../suites/CreditFacadeTestSuite.sol";
// import { TokensTestSuite, Tokens } from "../suites/TokensTestSuite.sol";
import {LEVERAGE_DECIMALS} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import "../lib/constants.sol";

import {TestHelper} from "../lib/helper.sol";

import "../lib/constants.sol";
import {Tokens} from "../config/Tokens.sol";

/// @title CreditManagerTestSuite
/// @notice Deploys contract for unit testing of CreditManagerV3.sol
contract CreditFacadeTestHelper is TestHelper {
    ICreditManagerV3 public creditManager;
    CreditFacadeV3 public creditFacade;
    CreditConfigurator public creditConfigurator;

    CreditFacadeTestSuite public cft;

    address public underlying;

    ///
    /// HELPERS
    ///

    function _openCreditAccount(uint256 amount, address onBehalfOf, uint16 leverageFactor, uint16 referralCode)
        internal
        returns (address)
    {
        uint256 borrowedAmount = (amount * leverageFactor) / LEVERAGE_DECIMALS; // F:[FA-5]

        return creditFacade.openCreditAccount(
            borrowedAmount,
            onBehalfOf,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, amount))
                })
            ),
            false,
            referralCode
        );
    }

    function _openTestCreditAccount() internal returns (address creditAccount, uint256 balance) {
        uint256 accountAmount = cft.creditAccountAmount();

        cft.tokenTestSuite().mint(underlying, USER, accountAmount);

        vm.startPrank(USER);
        creditAccount = _openCreditAccount(accountAmount, USER, 100, 0);

        vm.stopPrank();

        balance = IERC20(underlying).balanceOf(creditAccount);

        vm.label(creditAccount, "creditAccount");
    }

    function _openExtraTestCreditAccount() internal returns (address creditAccount, uint256 balance) {
        uint256 accountAmount = cft.creditAccountAmount();

        /// TODO: FIX
        // vm.prank(FRIEND);
        // creditFacade.openCreditAccount(accountAmount, FRIEND, 100, 0);

        vm.startPrank(USER);
        creditAccount = _openCreditAccount(accountAmount, USER, 100, 0);

        vm.stopPrank();

        balance = IERC20(underlying).balanceOf(creditAccount);
    }

    function _closeTestCreditAccount(address creditAccount) internal {
        MultiCall[] memory closeCalls;

        // switch to new block to be able to close account
        vm.roll(block.number + 1);

        // (,, uint256 underlyingToClose) = creditManager.calcCreditAccountAccruedInterest(creditAccount);
        // uint256 underlyingBalance = cft.tokenTestSuite().balanceOf(underlying, creditAccount);

        // if (underlyingToClose > underlyingBalance) {
        //     cft.tokenTestSuite().mint(underlying, USER, underlyingToClose - underlyingBalance);

        //     cft.tokenTestSuite().approve(underlying, USER, address(creditManager));
        // }

        vm.prank(USER);
        creditFacade.closeCreditAccount(creditAccount, FRIEND, 0, false, closeCalls);
    }

    function expectTokenIsEnabled(address creditAccount, address token, bool expectedState) internal {
        expectTokenIsEnabled(creditAccount, token, expectedState, "");
    }

    function expectTokenIsEnabled(address creditAccount, address token, bool expectedState, string memory reason)
        internal
    {
        bool state = creditManager.getTokenMaskOrRevert(token) & creditManager.enabledTokensMaskOf(creditAccount) != 0;

        if (state != expectedState && bytes(reason).length != 0) {
            emit log_string(reason);
        }

        assertTrue(
            state == expectedState,
            string(
                abi.encodePacked(
                    "Token ",
                    IERC20Metadata(token).symbol(),
                    state ? " enabled as not expetcted" : " not enabled as expected "
                )
            )
        );
    }

    function addCollateral(address token, uint256 amount) internal {
        // tokenTestSuite.mint(t, USER, amount);

        vm.startPrank(USER);
        IERC20(token).approve(address(creditManager), type(uint256).max);

        // TODO: rewrite as collateral
        // creditFacade.addCollateral(USER, token, amount);

        vm.stopPrank();
    }

    function _makeAccountsLiquitable() internal {
        vm.prank(CONFIGURATOR);
        creditConfigurator.setFees(1000, 200, 9000, 100, 9500);

        // switch to new block to be able to close account
        vm.roll(block.number + 1);
    }

    function multicallBuilder() internal pure returns (MultiCall[] memory calls) {}

    function multicallBuilder(MultiCall memory call1) internal pure returns (MultiCall[] memory calls) {
        calls = new MultiCall[](1);
        calls[0] = call1;
    }

    function multicallBuilder(MultiCall memory call1, MultiCall memory call2)
        internal
        pure
        returns (MultiCall[] memory calls)
    {
        calls = new MultiCall[](2);
        calls[0] = call1;
        calls[1] = call2;
    }

    function multicallBuilder(MultiCall memory call1, MultiCall memory call2, MultiCall memory call3)
        internal
        pure
        returns (MultiCall[] memory calls)
    {
        calls = new MultiCall[](3);
        calls[0] = call1;
        calls[1] = call2;
        calls[2] = call3;
    }

    function expectSafeAllowance(address creditAccount, address target) internal {
        uint256 len = creditManager.collateralTokensCount();
        for (uint256 i = 0; i < len; i++) {
            (address token,) = creditManager.collateralTokens(i);
            assertLe(IERC20(token).allowance(creditAccount, target), 1, "allowance is too high");
        }
    }

    function expectTokenIsEnabled(address creditAccount, Tokens t, bool expectedState) internal {
        expectTokenIsEnabled(creditAccount, t, expectedState, "");
    }

    function expectTokenIsEnabled(address creditAccount, Tokens t, bool expectedState, string memory reason) internal {
        expectTokenIsEnabled(creditAccount, tokenTestSuite().addressOf(t), expectedState, reason);
    }

    function addCollateral(Tokens t, uint256 amount) internal {
        tokenTestSuite().mint(t, USER, amount);
        tokenTestSuite().approve(t, USER, address(creditManager));

        vm.startPrank(USER);
        // TODO: rewrite using addCollateral in mc
        // creditFacade.addCollateral(USER, tokenTestSuite().addressOf(t), amount);
        vm.stopPrank();
    }

    function tokenTestSuite() private view returns (TokensTestSuite) {
        return TokensTestSuite(payable(address(cft.tokenTestSuite())));
    }
}
