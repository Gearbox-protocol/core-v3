// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICreditManagerV3, CollateralCalcTask} from "../../interfaces/ICreditManagerV3.sol";
import {IPoolV3} from "../../interfaces/IPoolV3.sol";

import {IPriceOracleV3} from "../../interfaces/IPriceOracleV3.sol";

import {Random} from "./Random.sol";
/// @title Target Hacker
/// This contract simulates different technics to hack the system by provided seed

contract TargetAttacker is Random {
    using Math for uint256;

    ICreditManagerV3 creditManager;
    IPoolV3 pool;
    IPriceOracleV3 priceOracle;

    address underlying;

    address public creditAccount;
    address public tokenIn;
    address public tokenOut;

    constructor(address _creditManager) {
        creditManager = ICreditManagerV3(_creditManager);
        pool = IPoolV3(creditManager.pool());
        priceOracle = IPriceOracleV3(creditManager.priceOracle());
        underlying = pool.asset();
        IERC20(underlying).approve(address(pool), type(uint256).max);
    }

    // Act function tests different scenarios related to any action
    // which could potential attacker use. Calling internal contracts
    // depositing funds into pools, withdrawing, liquidating, etc.

    // it also could update prices for updatable price oracles

    function act(uint256 _seed) external {
        setSeed(_seed);
        creditAccount = msg.sender;

        tokenOut = address(0);

        function ()[4] memory fnActions = [_stealTokens, _swap, _deposit, _withdraw];

        fnActions[getRandomInRange(fnActions.length)]();
    }

    function _stealTokens() internal {
        uint256 cTokensQty = creditManager.collateralTokensCount();
        uint256 mask = 1 << getRandomInRange(cTokensQty);
        (tokenIn,) = creditManager.collateralTokenByMask(mask);
        uint256 balance = IERC20(tokenIn).balanceOf(creditAccount);
        IERC20(tokenIn).transferFrom(creditAccount, address(this), getRandomInRange(balance));
    }

    /// Swaps token with some deviation from oracle price

    function _swap() internal {
        uint256 cTokensQty = creditManager.collateralTokensCount();

        (tokenIn,) = creditManager.collateralTokenByMask(1 << getRandomInRange(cTokensQty));
        uint256 balance = IERC20(tokenIn).balanceOf(creditAccount);
        uint256 amount = getRandomInRange(balance);
        IERC20(tokenIn).transferFrom(creditAccount, address(this), amount);

        (tokenOut,) = creditManager.collateralTokenByMask(1 << getRandomInRange(cTokensQty));

        uint256 amountOut = (priceOracle.convert(amount, tokenIn, tokenOut) * (120 - getRandomInRange(40))) / 100;
        amountOut = Math.min(amountOut, IERC20(tokenOut).balanceOf(address(this)));
        IERC20(tokenOut).transfer(creditAccount, amountOut);
    }

    function _deposit() internal {
        uint256 amount = getRandomInRange95(pool.availableLiquidity());
        pool.deposit(amount, address(this));
    }

    function _withdraw() internal {
        uint256 amount = getRandomInRange95(pool.balanceOf(address(this)));
        pool.withdraw(amount, address(this), address(this));
    }
}
