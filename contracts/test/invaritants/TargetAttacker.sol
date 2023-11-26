// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICreditManagerV3, CollateralCalcTask} from "../../interfaces/ICreditManagerV3.sol";
import {Random} from "./Random.sol";
/// @title Target Hacker
/// This contract simulates different technics to hack the system by provided seed

contract TargetAttacker is Random {
    ICreditManagerV3 creditManager;
    address creditAccount;

    constructor(address _creditManager) {
        creditManager = ICreditManagerV3(_creditManager);
    }

    // Act function tests different scenarios related to any action
    // which could potential attacker use. Calling internal contracts
    // depositing funds into pools, withdrawing, liquidating, etc.

    // it also could update prices for updatable price oracles

    function act(uint256 _seed) external {
        setSeed(_seed);
        creditAccount = msg.sender;

        function ()[1] memory fnActions = [_stealTokens];

        fnActions[getRandomInRange(fnActions.length)]();
    }

    function _stealTokens() internal {
        uint256 cTokensQty = creditManager.collateralTokensCount();
        uint256 mask = 1 << getRandomInRange(cTokensQty);
        (address token,) = creditManager.collateralTokenByMask(mask);
        uint256 balance = IERC20(token).balanceOf(creditAccount);
        IERC20(token).transferFrom(creditAccount, address(this), getRandomInRange(balance));
    }
}
