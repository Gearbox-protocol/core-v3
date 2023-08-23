// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import "../lib/constants.sol";

struct MockToken {
    Tokens index;
    string symbol;
    uint8 decimals;
    int256 price;
    Tokens underlying;
}

library MockTokensData {
    function getTokenData() internal pure returns (MockToken[] memory result) {
        MockToken[9] memory testTokensData = [
            MockToken({index: Tokens.DAI, symbol: "DAI", decimals: 18, price: 10 ** 8, underlying: Tokens.NO_TOKEN}),
            MockToken({index: Tokens.USDC, symbol: "USDC", decimals: 6, price: 10 ** 8, underlying: Tokens.NO_TOKEN}),
            MockToken({
                index: Tokens.WETH,
                symbol: "WETH",
                decimals: 18,
                price: int256(DAI_WETH_RATE) * 10 ** 8,
                underlying: Tokens.NO_TOKEN
            }),
            MockToken({index: Tokens.LINK, symbol: "LINK", decimals: 18, price: 15 * 10 ** 8, underlying: Tokens.NO_TOKEN}),
            MockToken({
                index: Tokens.USDT,
                symbol: "USDT",
                decimals: 18,
                price: 99 * 10 ** 7, // .99 for test purposes
                underlying: Tokens.NO_TOKEN
            }),
            MockToken({
                index: Tokens.STETH,
                symbol: "stETH",
                decimals: 18,
                price: 3300 * 10 ** 8,
                underlying: Tokens.NO_TOKEN
            }),
            MockToken({index: Tokens.CRV, symbol: "CRV", decimals: 18, price: 14 * 10 ** 7, underlying: Tokens.NO_TOKEN}),
            MockToken({index: Tokens.CVX, symbol: "CVX", decimals: 18, price: 7 * 10 ** 8, underlying: Tokens.NO_TOKEN}),
            MockToken({
                index: Tokens.wstETH,
                symbol: "wstETH",
                decimals: 18,
                price: 3300 * 10 ** 8,
                underlying: Tokens.NO_TOKEN
            })
        ];

        uint256 len = testTokensData.length;
        result = new MockToken[](len);

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                result[i] = testTokensData[i];
            }
        }
    }
}
