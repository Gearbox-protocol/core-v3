// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {GearboxInstance} from "./Deployer.sol";
import {Handler} from "./Handler.sol";

import {ICreditManagerV3, CollateralDebtData, CollateralCalcTask} from "../../interfaces/ICreditManagerV3.sol";

import "forge-std/Test.sol";
import "../lib/constants.sol";

contract InvariantGearboxTest is Test {
    GearboxInstance gi;
    Handler handler;

    ICreditManagerV3 creditManager;

    function setUp() public {
        gi = new GearboxInstance();
        gi._setUp();
        handler = new Handler(gi);
        targetContract(address(handler));

        creditManager = gi.creditManager();
    }

    function invariant_example() external {
        address[] memory accounts = creditManager.creditAccounts();
        uint256 len = accounts.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                _checkAccountInvariants(accounts[i]);
            }
        }
    }

    function _checkAccountInvariants(address creditAccount) internal {
        CollateralDebtData memory cdd =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);

        if (cdd.debt == 0) {
            assertEq(cdd.quotedTokens.length, 0, "Incorrect quota length");
        } else {
            assertTrue(cdd.twvUSD >= cdd.totalDebtUSD, "Accounts with hf < 1 exists");
        }
    }
}
