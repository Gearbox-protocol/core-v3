// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {BalancesLogic, Balance, BalanceWithMask} from "../../../libraries/BalancesLogic.sol";

contract BalancesLogicCaller {
    function compareBalances(address creditAccount, Balance[] memory expected) external view {
        BalancesLogic.compareBalances(creditAccount, expected);
    }

    function checkForbiddenBalances(
        address creditAccount,
        uint256 enabledTokensMaskBefore,
        uint256 enabledTokensMaskAfter,
        BalanceWithMask[] memory forbiddenBalances,
        uint256 forbiddenTokenMask
    ) external view {
        BalancesLogic.checkForbiddenBalances(
            creditAccount, enabledTokensMaskBefore, enabledTokensMaskAfter, forbiddenBalances, forbiddenTokenMask
        );
    }
}
