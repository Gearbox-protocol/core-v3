// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {
    ICreditManagerV3,
    ICreditManagerV3Events,
    ClosureAction,
    CollateralTokenData,
    ManageDebtAction,
    CollateralDebtData
} from "../../../interfaces/ICreditManagerV3.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PERCENTAGE_FACTOR, SECONDS_PER_YEAR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// LIBS & TRAITS
import {BitMask, UNDERLYING_TOKEN_MASK} from "../../../libraries/BitMask.sol";

// TESTS
import {IntegrationTestHelper} from "../../helpers/IntegrationTestHelper.sol";
import "../../lib/constants.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";

// MOCKS
import {TargetContractMock} from "../../mocks/core/TargetContractMock.sol";
import {ERC20ApproveRestrictedRevert, ERC20ApproveRestrictedFalse} from "../../mocks/token/ERC20ApproveRestricted.sol";

// SUITES
import {Tokens} from "../../config/Tokens.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

contract CreditManagerIntegrationTest is Test, ICreditManagerV3Events, BalanceHelper, IntegrationTestHelper {
    using BitMask for uint256;

    //
    // APPROVE CREDIT ACCOUNT
    //

    /// @dev I:[CM-25A]: approveCreditAccount reverts if the token is not added
    function test_I_CM_25A_approveCreditAccount_reverts_if_the_token_is_not_added() public {
        (,, address creditAccount) = _openCreditAccount();
        creditManager.setActiveCreditAccount(creditAccount);

        vm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        vm.expectRevert(TokenNotAllowedException.selector);

        vm.prank(ADAPTER);
        creditManager.approveCreditAccount(DUMB_ADDRESS, 100);
    }

    // todo: move to unit tests

    /// @dev I:[CM-26]: approveCreditAccount approves with desired allowance
    function test_I_CM_26_approveCreditAccount_approves_with_desired_allowance() public {
        (,, address creditAccount) = _openCreditAccount();
        creditManager.setActiveCreditAccount(creditAccount);

        vm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        // Case, when current allowance > Allowance_THRESHOLD
        tokenTestSuite.approve(Tokens.DAI, creditAccount, DUMB_ADDRESS, 200);

        address dai = tokenTestSuite.addressOf(Tokens.DAI);

        vm.prank(ADAPTER);
        creditManager.approveCreditAccount(dai, DAI_EXCHANGE_AMOUNT);

        expectAllowance(Tokens.DAI, creditAccount, DUMB_ADDRESS, DAI_EXCHANGE_AMOUNT);
    }

    /// @dev I:[CM-27A]: approveCreditAccount works for ERC20 that revert if allowance > 0 before approve
    function test_I_CM_27A_approveCreditAccount_works_for_ERC20_with_approve_restrictions() public {
        (,, address creditAccount) = _openCreditAccount();
        creditManager.setActiveCreditAccount(creditAccount);

        vm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        address approveRevertToken = address(new ERC20ApproveRestrictedRevert());

        vm.prank(CONFIGURATOR);
        creditManager.addToken(approveRevertToken);

        vm.prank(ADAPTER);
        creditManager.approveCreditAccount(approveRevertToken, DAI_EXCHANGE_AMOUNT);

        vm.prank(ADAPTER);
        creditManager.approveCreditAccount(approveRevertToken, 2 * DAI_EXCHANGE_AMOUNT);

        expectAllowance(approveRevertToken, creditAccount, DUMB_ADDRESS, 2 * DAI_EXCHANGE_AMOUNT);
    }

    // /// @dev I:[CM-27B]: approveCreditAccount works for ERC20 that returns false if allowance > 0 before approve
    function test_I_CM_27B_approveCreditAccount_works_for_ERC20_with_approve_restrictions() public {
        (,, address creditAccount) = _openCreditAccount();
        creditManager.setActiveCreditAccount(creditAccount);

        address approveFalseToken = address(new ERC20ApproveRestrictedFalse());

        vm.prank(CONFIGURATOR);
        creditManager.addToken(approveFalseToken);

        vm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        vm.prank(ADAPTER);
        creditManager.approveCreditAccount(approveFalseToken, DAI_EXCHANGE_AMOUNT);

        vm.prank(ADAPTER);
        creditManager.approveCreditAccount(approveFalseToken, 2 * DAI_EXCHANGE_AMOUNT);

        expectAllowance(approveFalseToken, creditAccount, DUMB_ADDRESS, 2 * DAI_EXCHANGE_AMOUNT);
    }

    //
    // EXECUTE ORDER
    //

    /// @dev I:[CM-29]: execute calls credit account method and emit event
    function test_I_CM_29_execute_calls_credit_account_method_and_emit_event() public {
        (,, address creditAccount) = _openCreditAccount();
        creditManager.setActiveCreditAccount(creditAccount);

        TargetContractMock targetMock = new TargetContractMock();

        vm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, address(targetMock));

        bytes memory callData = bytes("Hello, world!");

        // stack trace check
        vm.expectCall(creditAccount, abi.encodeWithSignature("execute(address,bytes)", address(targetMock), callData));
        vm.expectCall(address(targetMock), callData);

        vm.prank(ADAPTER);
        creditManager.execute(callData);

        assertEq0(targetMock.callData(), callData, "Incorrect calldata");
    }

    /// @dev I:[CM-68]: fullCollateralCheck checks tokens in correct order
    function test_I_CM_68_fullCollateralCheck_is_evaluated_in_order_of_hints() public {
        (uint256 debt, uint256 cumulativeIndexLastUpdate, address creditAccount) = _openCreditAccount();

        uint256 daiBalance = tokenTestSuite.balanceOf(Tokens.DAI, creditAccount);

        tokenTestSuite.burn(Tokens.DAI, creditAccount, daiBalance);

        vm.warp(block.timestamp + 365 days);

        uint256 cumulativeIndexNow = pool.calcLinearCumulative_RAY();

        uint256 borrowAmountWithInterest = debt * cumulativeIndexNow / cumulativeIndexLastUpdate;
        uint256 interestAccured = borrowAmountWithInterest - debt;

        (uint256 feeInterest,,,,) = creditManager.fees();

        uint256 amountToRepay = (
            ((borrowAmountWithInterest + interestAccured * feeInterest / PERCENTAGE_FACTOR) * (10 ** 8))
                * PERCENTAGE_FACTOR / tokenTestSuite.prices(Tokens.DAI)
                / creditManager.liquidationThresholds(tokenTestSuite.addressOf(Tokens.DAI))
        ) + WAD;

        tokenTestSuite.mint(Tokens.DAI, creditAccount, amountToRepay);

        tokenTestSuite.mint(Tokens.USDC, creditAccount, USDC_ACCOUNT_AMOUNT);
        tokenTestSuite.mint(Tokens.USDT, creditAccount, 10);
        tokenTestSuite.mint(Tokens.LINK, creditAccount, 10);

        // creditManager.checkAndEnableToken(tokenTestSuite.addressOf(Tokens.USDC));
        // creditManager.checkAndEnableToken(tokenTestSuite.addressOf(Tokens.USDT));
        // creditManager.checkAndEnableToken(tokenTestSuite.addressOf(Tokens.LINK));

        uint256[] memory collateralHints = new uint256[](2);
        collateralHints[0] = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDT));
        collateralHints[1] = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));

        vm.expectCall(tokenTestSuite.addressOf(Tokens.USDT), abi.encodeCall(IERC20.balanceOf, (creditAccount)));
        vm.expectCall(tokenTestSuite.addressOf(Tokens.LINK), abi.encodeCall(IERC20.balanceOf, (creditAccount)));

        uint256 enabledTokensMap = 1 | creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDC))
            | creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDT))
            | creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));

        creditManager.fullCollateralCheck(creditAccount, enabledTokensMap, collateralHints, PERCENTAGE_FACTOR);

        // assertEq(cmi.fullCheckOrder(0), tokenTestSuite.addressOf(Tokens.USDT), "Token order incorrect");

        // assertEq(cmi.fullCheckOrder(1), tokenTestSuite.addressOf(Tokens.LINK), "Token order incorrect");

        // assertEq(cmi.fullCheckOrder(2), tokenTestSuite.addressOf(Tokens.DAI), "Token order incorrect");

        // assertEq(cmi.fullCheckOrder(3), tokenTestSuite.addressOf(Tokens.USDC), "Token order incorrect");
    }

    /// @dev I:[CM-70]: fullCollateralCheck reverts when an illegal mask is passed in collateralHints
    function test_I_CM_70_fullCollateralCheck_reverts_for_illegal_mask_in_hints() public {
        (,, address creditAccount) = _openCreditAccount();

        vm.expectRevert(TokenNotAllowedException.selector);

        uint256[] memory ch = new uint256[](1);
        ch[0] = 3;

        uint256 enabledTokensMap = 1;

        creditManager.fullCollateralCheck(creditAccount, enabledTokensMap, ch, PERCENTAGE_FACTOR);
    }
}
