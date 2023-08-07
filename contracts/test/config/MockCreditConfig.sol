// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {TokensTestSuite} from "../suites/TokensTestSuite.sol";
import {Tokens} from "@gearbox-protocol/sdk/contracts/Tokens.sol";

import {CreditManagerOpts, CollateralToken} from "../../credit/CreditConfiguratorV3.sol";

import {ICreditConfig, PriceFeedConfig} from "../interfaces/ICreditConfig.sol";
import {ITokenTestSuite} from "../interfaces/ITokenTestSuite.sol";

import "../lib/constants.sol";

struct CollateralTokensItem {
    Tokens token;
    uint16 liquidationThreshold;
}

contract MockCreditConfig is Test, ICreditConfig {
    uint128 public minDebt;
    uint128 public maxDebt;

    TokensTestSuite public _tokenTestSuite;

    mapping(Tokens => uint16) public lt;

    address public override underlying;

    address public override wethToken;

    Tokens public underlyingSymbol;

    constructor(TokensTestSuite tokenTestSuite_, Tokens _underlying) {
        underlyingSymbol = _underlying;
        underlying = tokenTestSuite_.addressOf(_underlying);

        uint256 accountAmount = getAccountAmount();

        minDebt = getMinDebt();
        maxDebt = uint128(10 * accountAmount);

        _tokenTestSuite = tokenTestSuite_;

        wethToken = tokenTestSuite_.addressOf(Tokens.WETH);
        underlyingSymbol = _underlying;
    }

    function getCreditOpts() external override returns (CreditManagerOpts memory) {
        return CreditManagerOpts({
            minDebt: minDebt,
            maxDebt: maxDebt,
            collateralTokens: getCollateralTokens(),
            degenNFT: address(0),
            expirable: false
        });
    }

    function getCollateralTokens() public override returns (CollateralToken[] memory collateralTokens) {
        CollateralTokensItem[8] memory collateralTokenOpts = [
            CollateralTokensItem({token: Tokens.USDC, liquidationThreshold: 90_00}),
            CollateralTokensItem({token: Tokens.USDT, liquidationThreshold: 88_00}),
            CollateralTokensItem({token: Tokens.DAI, liquidationThreshold: 83_00}),
            CollateralTokensItem({token: Tokens.WETH, liquidationThreshold: 83_00}),
            CollateralTokensItem({token: Tokens.LINK, liquidationThreshold: 73_00}),
            CollateralTokensItem({token: Tokens.CRV, liquidationThreshold: 73_00}),
            CollateralTokensItem({token: Tokens.CVX, liquidationThreshold: 73_00}),
            CollateralTokensItem({token: Tokens.STETH, liquidationThreshold: 73_00})
        ];

        lt[underlyingSymbol] = DEFAULT_UNDERLYING_LT;

        uint256 len = collateralTokenOpts.length;
        collateralTokens = new CollateralToken[](len - 1);
        uint256 j;
        for (uint256 i = 0; i < len; i++) {
            if (collateralTokenOpts[i].token == underlyingSymbol) continue;

            lt[collateralTokenOpts[i].token] = collateralTokenOpts[i].liquidationThreshold;

            collateralTokens[j] = CollateralToken({
                token: _tokenTestSuite.addressOf(collateralTokenOpts[i].token),
                liquidationThreshold: collateralTokenOpts[i].liquidationThreshold
            });
            j++;
        }
    }

    function getMinDebt() internal view returns (uint128) {
        return (underlyingSymbol == Tokens.USDC) ? uint128(10 ** 6) : uint128(WAD);
    }

    function getAccountAmount() public view override returns (uint256) {
        return (underlyingSymbol == Tokens.DAI)
            ? DAI_ACCOUNT_AMOUNT
            : (underlyingSymbol == Tokens.USDC) ? USDC_ACCOUNT_AMOUNT : WETH_ACCOUNT_AMOUNT;
    }

    // function tokenTestSuite() external view override returns (ITokenTestSuite) {
    //     return _tokenTestSuite;
    // }
}
