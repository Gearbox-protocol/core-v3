// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import "../lib/constants.sol";

struct MockToken {
    uint256 index;
    string symbol;
    uint8 decimals;
    int256 price;
    uint256 underlying;
}

library MockTokensData {
    function getTokenData() internal pure returns (MockToken[] memory result) {
        MockToken[9] memory testTokensData = [
            MockToken({index: TOKEN_DAI, symbol: "DAI", decimals: 18, price: 10 ** 8, underlying: TOKEN_NO_TOKEN}),
            MockToken({index: TOKEN_USDC, symbol: "USDC", decimals: 6, price: 10 ** 8, underlying: TOKEN_NO_TOKEN}),
            MockToken({
                index: TOKEN_WETH,
                symbol: "WETH",
                decimals: 18,
                price: int256(DAI_WETH_RATE) * 10 ** 8,
                underlying: TOKEN_NO_TOKEN
            }),
            MockToken({index: TOKEN_LINK, symbol: "LINK", decimals: 18, price: 15 * 10 ** 8, underlying: TOKEN_NO_TOKEN}),
            MockToken({
                index: TOKEN_USDT,
                symbol: "USDT",
                decimals: 18,
                price: 99 * 10 ** 7, // .99 for test purposes
                underlying: TOKEN_NO_TOKEN
            }),
            MockToken({index: TOKEN_STETH, symbol: "stETH", decimals: 18, price: 3300 * 10 ** 8, underlying: TOKEN_NO_TOKEN}),
            MockToken({index: TOKEN_CRV, symbol: "CRV", decimals: 18, price: 14 * 10 ** 7, underlying: TOKEN_NO_TOKEN}),
            MockToken({index: TOKEN_CVX, symbol: "CVX", decimals: 18, price: 7 * 10 ** 8, underlying: TOKEN_NO_TOKEN}),
            MockToken({
                index: TOKEN_wstETH,
                symbol: "wstETH",
                decimals: 18,
                price: 3300 * 10 ** 8,
                underlying: TOKEN_NO_TOKEN
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
