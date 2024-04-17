// // SPDX-License-Identifier: UNLICENSED
// // Gearbox Protocol. Generalized leverage for DeFi protocols
// // (c) Gearbox Foundation, 2023.
// pragma solidity ^0.8.17;

// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// import {ICreditManagerV3, CollateralCalcTask, CollateralDebtData} from "../../interfaces/ICreditManagerV3.sol";
// import {IPriceOracleV3} from "../../interfaces/IPriceOracleV3.sol";
// import {ITokenTestSuite} from "../interfaces/ITokenTestSuite.sol";
// import {PriceFeedMock} from "../mocks/oracles/PriceFeedMock.sol";
// import {Random} from "./Random.sol";

// /// @title Target Hacker
// /// This contract simulates different technics to hack the system by provided seed

// contract TargetAttacker is Random {
//     using Math for uint256;

//     ICreditManagerV3 creditManager;
//     IPriceOracleV3 priceOracle;
//     ITokenTestSuite tokenTestSuite;
//     address creditAccount;

//     constructor(address _creditManager, address _priceOracle, address _tokenTestSuite) {
//         creditManager = ICreditManagerV3(_creditManager);
//         priceOracle = IPriceOracleV3(_priceOracle);
//         tokenTestSuite = ITokenTestSuite(_tokenTestSuite);
//     }

//     // Act function tests different scenarios related to any action
//     // which could potential attacker use. Calling internal contracts
//     // depositing funds into pools, withdrawing, liquidating, etc.

//     // it also could update prices for updatable price oracles

//     function act(uint256 _seed) external {
//         setSeed(_seed);
//         creditAccount = msg.sender;

//         function ()[3] memory fnActions = [_stealTokens, _changeTokenPrice, _swapTokens];

//         fnActions[getRandomInRange(fnActions.length)]();
//     }

//     function _changeTokenPrice() internal {
//         uint256 cTokensQty = creditManager.collateralTokensCount();
//         uint256 mask = 1 << getRandomInRange(cTokensQty);
//         (address token,) = creditManager.collateralTokenByMask(mask);

//         address priceFeed = IPriceOracleV3(priceOracle).priceFeeds(token);

//         (, int256 price,,,) = PriceFeedMock(priceFeed).latestRoundData();

//         uint256 sign = getRandomInRange(2);
//         uint256 deltaPct = getRandomInRange(500);

//         int256 newPrice =
//             sign == 1 ? price * (10000 + int256(deltaPct)) / 10000 : price * (10000 - int256(deltaPct)) / 10000;

//         PriceFeedMock(priceFeed).setPrice(newPrice);
//     }

//     function _swapTokens() internal {
//         uint256 cTokensQty = creditManager.collateralTokensCount();
//         uint256 mask0 = 1 << getRandomInRange(cTokensQty);
//         uint256 mask1 = 1 << getRandomInRange(cTokensQty);

//         (address tokenIn,) = creditManager.collateralTokenByMask(mask0);
//         (address tokenOut,) = creditManager.collateralTokenByMask(mask1);

//         uint256 balance = IERC20(tokenIn).balanceOf(creditAccount);

//         uint256 tokenInAmount = getRandomInRange(balance);

//         uint256 tokenInEq = priceOracle.convert(tokenInAmount, tokenIn, tokenOut);

//         IERC20(tokenIn).transferFrom(creditAccount, address(this), tokenInAmount);
//         tokenTestSuite.mint(tokenOut, creditAccount, getRandomInRange(tokenInEq));
//     }

//     function _stealTokens() internal {
//         uint256 cTokensQty = creditManager.collateralTokensCount();
//         uint256 mask = 1 << getRandomInRange(cTokensQty);
//         (tokenIn,) = creditManager.collateralTokenByMask(mask);
//         uint256 balance = IERC20(tokenIn).balanceOf(creditAccount);
//         IERC20(tokenIn).transferFrom(creditAccount, address(this), getRandomInRange(balance));
//     }

//     /// Swaps token with some deviation from oracle price

//     function _swap() internal {
//         uint256 cTokensQty = creditManager.collateralTokensCount();

//         (tokenIn,) = creditManager.collateralTokenByMask(1 << getRandomInRange(cTokensQty));
//         uint256 balance = IERC20(tokenIn).balanceOf(creditAccount);
//         uint256 amount = getRandomInRange(balance);
//         IERC20(tokenIn).transferFrom(creditAccount, address(this), amount);

//         (tokenOut,) = creditManager.collateralTokenByMask(1 << getRandomInRange(cTokensQty));

//         uint256 amountOut = (priceOracle.convert(amount, tokenIn, tokenOut) * (120 - getRandomInRange(40))) / 100;
//         amountOut = Math.min(amountOut, IERC20(tokenOut).balanceOf(address(this)));
//         IERC20(tokenOut).transfer(creditAccount, amountOut);
//     }

//     function _deposit() internal {
//         uint256 amount = getRandomInRange95(pool.availableLiquidity());
//         pool.deposit(amount, address(this));
//     }

//     function _withdraw() internal {
//         uint256 amount = getRandomInRange95(pool.balanceOf(address(this)));
//         pool.withdraw(amount, address(this), address(this));
//     }
// }
