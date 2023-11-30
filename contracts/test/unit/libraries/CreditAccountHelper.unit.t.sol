// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {CreditAccountHelper} from "../../../libraries/CreditAccountHelper.sol";
import {ICreditAccountBase} from "../../../interfaces/ICreditAccountV3.sol";
import {CreditAccountV3} from "../../../credit/CreditAccountV3.sol";

import {ERC20ApproveRestrictedRevert, ERC20ApproveRestrictedFalse} from "../../mocks/token/ERC20ApproveRestricted.sol";

import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import {TestHelper} from "../../lib/helper.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";

import "../../lib/constants.sol";

/// @title CreditAccountHelper logic test
/// @notice U:[CAH]: Unit tests for credit account helper
contract CreditAccountHelperUnitTest is TestHelper, BalanceHelper {
    using CreditAccountHelper for ICreditAccountBase;

    address creditAccount;

    function setUp() public {
        tokenTestSuite = new TokensTestSuite();
        creditAccount = address(new CreditAccountV3(address(this)));
    }

    /// @notice U:[CAH-1]: approveCreditAccount approves with desired allowance
    function test_U_CAH_01_safeApprove_approves_with_desired_allowance() public {
        // Case, when current allowance > Allowance_THRESHOLD
        tokenTestSuite.approve(Tokens.DAI, creditAccount, DUMB_ADDRESS, 200);

        address dai = tokenTestSuite.addressOf(Tokens.DAI);

        ICreditAccountBase(creditAccount).safeApprove(dai, DUMB_ADDRESS, DAI_EXCHANGE_AMOUNT);

        expectAllowance(Tokens.DAI, creditAccount, DUMB_ADDRESS, DAI_EXCHANGE_AMOUNT);
    }

    /// @dev U:[CAH-2]: approveCreditAccount works for ERC20 that revert if allowance > 0 before approve
    function test_U_CAH_02_safeApprove_works_for_ERC20_with_approve_restrictions() public {
        address approveRevertToken = address(new ERC20ApproveRestrictedRevert());

        ICreditAccountBase(creditAccount).safeApprove(approveRevertToken, DUMB_ADDRESS, DAI_EXCHANGE_AMOUNT);

        ICreditAccountBase(creditAccount).safeApprove(approveRevertToken, DUMB_ADDRESS, 2 * DAI_EXCHANGE_AMOUNT);

        expectAllowance(approveRevertToken, creditAccount, DUMB_ADDRESS, 2 * DAI_EXCHANGE_AMOUNT);

        address approveFalseToken = address(new ERC20ApproveRestrictedFalse());

        ICreditAccountBase(creditAccount).safeApprove(approveFalseToken, DUMB_ADDRESS, DAI_EXCHANGE_AMOUNT);

        ICreditAccountBase(creditAccount).safeApprove(approveFalseToken, DUMB_ADDRESS, 2 * DAI_EXCHANGE_AMOUNT);

        expectAllowance(approveFalseToken, creditAccount, DUMB_ADDRESS, 2 * DAI_EXCHANGE_AMOUNT);
    }
}
