// SPDX-License-Identifier: UNLICENSED
// Gearbox. Generalized leverage protocol that allows to take leverage and then use it across other DeFi protocols and platforms in a composable way.
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WETHMock} from "@gearbox-protocol/core-v2/contracts/test/mocks/token/WETHMock.sol";
import {ERC20BlacklistableMock} from "../mocks//token/ERC20Blacklistable.sol";

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {PriceFeedConfig} from "@gearbox-protocol/core-v2/contracts/oracles/PriceOracle.sol";

// MOCKS
import {ERC20Mock} from "@gearbox-protocol/core-v2/contracts/test/mocks/token/ERC20Mock.sol";
import {ERC20FeeMock} from "../mocks//token/ERC20FeeMock.sol";

import {PriceFeedMock} from "@gearbox-protocol/core-v2/contracts/test/mocks/oracles/PriceFeedMock.sol";

import {Test} from "forge-std/Test.sol";

import {TokensTestSuiteHelper} from "./TokensTestSuiteHelper.sol";
import {TokensData, TestToken} from "../config/TokensData.sol";
import {Tokens} from "../config/Tokens.sol";

contract TokensTestSuite is Test, TokensData, TokensTestSuiteHelper {
    mapping(Tokens => address) public addressOf;
    mapping(Tokens => string) public symbols;
    mapping(Tokens => uint256) public prices;
    mapping(Tokens => address) public priceFeedsMap;

    uint256 public tokenCount;

    PriceFeedConfig[] public priceFeeds;
    mapping(address => Tokens) public tokenIndexes;

    constructor() {
        TestToken[] memory data = tokensData();

        uint256 len = data.length;
        tokenCount = len;

        unchecked {
            for (uint256 i; i < len; ++i) {
                addToken(data[i]);
            }
        }
    }

    function addToken(TestToken memory token) internal {
        IERC20 t;

        if (token.index == Tokens.WETH) {
            t = new WETHMock();
            wethToken = address(t);
        } else if (token.index == Tokens.USDC) {
            t = new ERC20BlacklistableMock(
                token.symbol,
                token.symbol,
                token.decimals
            );
        } else if (token.index == Tokens.USDT) {
            t = new ERC20FeeMock(token.symbol, token.symbol, token.decimals);
        } else {
            t = new ERC20Mock(token.symbol, token.symbol, token.decimals);
        }

        vm.label(address(t), token.symbol);

        AggregatorV3Interface priceFeed = new PriceFeedMock(token.price, 8);

        addressOf[token.index] = address(t);
        prices[token.index] = uint256(token.price);

        tokenIndexes[address(t)] = token.index;

        priceFeeds.push(PriceFeedConfig({token: address(t), priceFeed: address(priceFeed)}));
        symbols[token.index] = token.symbol;
        priceFeedsMap[token.index] = address(priceFeed);
        tokenCount++;
    }

    function getPriceFeeds() external view returns (PriceFeedConfig[] memory) {
        return priceFeeds;
    }

    function mint(Tokens t, address to, uint256 amount) public {
        mint(addressOf[t], to, amount);
    }

    function balanceOf(Tokens t, address holder) public view returns (uint256) {
        return balanceOf(addressOf[t], holder);
    }

    function approve(Tokens t, address from, address spender) public {
        approve(addressOf[t], from, spender);
    }

    function approve(Tokens t, address from, address spender, uint256 amount) public {
        approve(addressOf[t], from, spender, amount);
    }

    function allowance(Tokens t, address from, address spender) external view returns (uint256) {
        return IERC20(addressOf[t]).allowance(from, spender);
    }

    function burn(Tokens t, address from, uint256 amount) external {
        burn(addressOf[t], from, amount);
    }

    function listOf(Tokens t1) external view returns (address[] memory tokensList) {
        tokensList = new address[](1);
        tokensList[0] = addressOf[t1];
    }

    function listOf(Tokens t1, Tokens t2) external view returns (address[] memory tokensList) {
        tokensList = new address[](2);
        tokensList[0] = addressOf[t1];
        tokensList[1] = addressOf[t2];
    }

    function listOf(Tokens t1, Tokens t2, Tokens t3) external view returns (address[] memory tokensList) {
        tokensList = new address[](3);
        tokensList[0] = addressOf[t1];
        tokensList[1] = addressOf[t2];
        tokensList[2] = addressOf[t3];
    }

    function listOf(Tokens t1, Tokens t2, Tokens t3, Tokens t4) external view returns (address[] memory tokensList) {
        tokensList = new address[](4);
        tokensList[0] = addressOf[t1];
        tokensList[1] = addressOf[t2];
        tokensList[2] = addressOf[t3];
        tokensList[3] = addressOf[t4];
    }
}
