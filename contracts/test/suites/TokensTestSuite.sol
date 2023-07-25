// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WETHMock} from "../mocks/token/WETHMock.sol";
import {ERC20BlacklistableMock} from "../mocks/token/ERC20Blacklistable.sol";

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {PriceFeedConfig} from "@gearbox-protocol/core-v2/contracts/oracles/PriceOracleV2.sol";

// MOCKS
import {ERC20Mock} from "../mocks/token/ERC20Mock.sol";
import {ERC20FeeMock} from "../mocks/token/ERC20FeeMock.sol";

import {PriceFeedMock} from "../mocks/oracles/PriceFeedMock.sol";

import {Test} from "forge-std/Test.sol";
import "../lib/constants.sol";

import {TokensTestSuiteHelper} from "./TokensTestSuiteHelper.sol";
import {MockTokensData, MockToken} from "../config/MockTokensData.sol";
import {Tokens} from "@gearbox-protocol/sdk/contracts/Tokens.sol";
import {TokenData, TokensDataLive, TokenType} from "@gearbox-protocol/sdk/contracts/TokensData.sol";

contract TokensTestSuite is Test, TokensTestSuiteHelper {
    mapping(Tokens => address) public addressOf;
    mapping(Tokens => string) public symbols;
    mapping(Tokens => uint256) public prices;
    mapping(Tokens => address) public priceFeedsMap;

    mapping(Tokens => TokenType) public tokenTypes;

    mapping(address => Tokens) public tokenIndexes;

    uint256 public tokenCount;

    bool mockTokens;

    PriceFeedConfig[] public priceFeeds;

    constructor() {
        if (block.chainid == 1337) {
            uint8 networkId;

            try vm.envInt("ETH_FORK_NETWORK_ID") returns (int256 val) {
                networkId = uint8(uint256(val));
            } catch {
                networkId = 1;
            }

            TokensDataLive tdd = new TokensDataLive(networkId);
            TokenData[] memory td = tdd.getTokenData();
            mockTokens = false;

            tokenCount = td.length;

            unchecked {
                for (uint256 i; i < tokenCount; ++i) {
                    addressOf[td[i].id] = td[i].addr;
                    tokenIndexes[td[i].addr] = td[i].id;
                    symbols[td[i].id] = td[i].symbol;
                    tokenTypes[td[i].id] = td[i].tokenType;

                    _flushAccounts(td[i].addr);

                    vm.label(td[i].addr, td[i].symbol);
                }
            }
        } else {
            MockToken[] memory data = MockTokensData.getTokenData();

            mockTokens = true;

            tokenCount = data.length;

            unchecked {
                for (uint256 i; i < tokenCount; ++i) {
                    addMockToken(data[i]);
                }
            }
        }

        wethToken = addressOf[Tokens.WETH];
    }

    function addMockToken(MockToken memory token) internal {
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

    function _flushAccounts(address token) internal {
        _flushAccount(token, DUMB_ADDRESS);
        _flushAccount(token, DUMB_ADDRESS2);
        _flushAccount(token, DUMB_ADDRESS3);
        _flushAccount(token, DUMB_ADDRESS4);

        _flushAccount(token, USER);
        _flushAccount(token, LIQUIDATOR);
        _flushAccount(token, FRIEND);
        _flushAccount(token, FRIEND2);
    }

    function _flushAccount(address token, address account) internal {
        uint256 balance = IERC20(token).balanceOf(account);

        if (balance > 0) {
            vm.prank(account);
            IERC20(token).transfer(address(type(uint160).max), balance);
        }
    }
}
