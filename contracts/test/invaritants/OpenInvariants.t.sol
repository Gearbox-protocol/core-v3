// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {GearboxInstance} from "./Deployer.sol";
import {Handler} from "./Handler.sol";

import {ICreditManagerV3, CollateralDebtData, CollateralCalcTask} from "../../interfaces/ICreditManagerV3.sol";

import "forge-std/Test.sol";
import "forge-std/console.sol";
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

    // 20x Open CA
    // multicall multilpe times

    // liquidate -> (??)
    // [ p ] -> EVENT LIQUIDATION -> [ ca ]  -> liquidate

    //
    // Open CA
    // N x randomMulticall()
    // Set paramt to liuiq
    // M x randiomMulticall()
    // Liquidate

    // Self-liquidation [ ? ]

    function invariant_credit_accounts() external {
        address[] memory accounts = creditManager.creditAccounts();
        uint256 len = accounts.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                address creditAccount = accounts[i];
                CollateralDebtData memory cdd =
                    creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);

                _checkAccountInvariants(cdd);
            }
        }
    }

    function invariant_system() external {
        _checkSystemInvariants();
    }

    function _checkAccountInvariants(CollateralDebtData memory cdd) internal {
        if (cdd.debt == 0) {
            assertEq(cdd.quotedTokens.length, 0, "Incorrect quota length");
            assertEq(cdd.totalDebtUSD, 0, "Debt is 0 while total debt is not");
        } else {
            // todo: for changed account true (for all if onDemandPrice was not called)
            assertTrue(cdd.twvUSD >= cdd.totalDebtUSD, "Accounts with hf < 1 exists");
        }
    }

    function _checkSystemInvariants() internal {
        inv_system_01();
        inv_system_02();
        inv_system_03();
    }

    // tokenQuotaParams.limit >= tokenQuotaParams.totalQuoted without limit change
    function inv_system_01() internal {
        uint256 cTokensQty = creditManager.collateralTokensCount();

        for (uint256 i = 0; i < cTokensQty; ++i) {
            (address token,) = creditManager.collateralTokenByMask(1 << i);

            (,,, uint96 totalQuoted, uint96 limit,) = gi.poolQuotaKeeper().getTokenQuotaParams(token);

            assertGe(limit, totalQuoted, "Total quoted is larger than limit");
        }
    }

    // expectedLiquidity ~ availableLiquidity + sum of total debts
    function inv_system_02() internal {
        uint256 el = gi.pool().expectedLiquidity();
        uint256 al = gi.pool().availableLiquidity();

        if (al >= el) return;

        uint256 totalDebts = 0;

        address[] memory accounts = creditManager.creditAccounts();
        uint256 len = accounts.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                address creditAccount = accounts[i];
                CollateralDebtData memory cdd =
                    creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

                totalDebts += cdd.debt + cdd.accruedInterest;
            }
        }

        uint256 eel = al + totalDebts;

        uint256 diff = eel > el ? (eel - el) * 10000 / el : (el - eel) * 10000 / el;

        assertLe(diff, 10, "Expected liquidity discrepancy is larger than 0.1%");
    }

    function inv_system_03() internal {
        bool isDefault;

        try creditManager.getActiveCreditAccountOrRevert() returns (address) {
            isDefault = false;
        } catch {
            isDefault = true;
        }

        assertTrue(isDefault, "Active credit account is non-zero between transactions");
    }
}
