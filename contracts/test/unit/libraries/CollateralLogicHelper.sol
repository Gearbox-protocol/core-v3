// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import {MockTokensData, MockToken} from "../../config/MockTokensData.sol";
import {CollateralLogic} from "../../../libraries/CollateralLogic.sol";

import "../../lib/constants.sol";

import {TestHelper} from "../../lib/helper.sol";

import "forge-std/console.sol";

address constant PRICE_ORACLE = DUMB_ADDRESS4;

struct B {
    uint256 t;
    uint256 balance;
}

struct Q {
    uint256 t;
    uint256 quota;
}

contract CollateralLogicHelper is TestHelper {
    uint256 session;

    mapping(uint256 => uint256) tokenMask;

    mapping(uint256 => uint256) tokenByMask;

    mapping(uint256 => address) addressOf;
    mapping(uint256 => string) symbolOf;
    mapping(address => uint256) tokenOf;

    mapping(uint256 => uint16) lts;

    mapping(address => uint256) _prices;
    mapping(uint256 => uint256) prices;

    mapping(address => bool) revertIsPriceOracleCalled;

    constructor() {
        MockToken[] memory tokens = MockTokensData.getTokenData();
        uint256 len = tokens.length;
        for (uint256 i; i < len; ++i) {
            deploy(tokens[i].index, tokens[i].symbol, uint8(i));
        }
    }

    // Function helpers which're used as pointers to the lib

    function _convertToUSD(address priceOracle, uint256 amount, address token) internal view returns (uint256 result) {
        require(priceOracle == PRICE_ORACLE, "Incorrect priceOracle");

        if (revertIsPriceOracleCalled[token]) {
            console.log("Price should not be fetched", token);
            revert("Unexpected call to priceOracle");
        }

        result = amount * _prices[token];
        if (result == 0) {
            console.log("Price for %s token is not set", token);
            revert("Cant find price");
        }
    }

    function _collateralTokenByMask(uint256 _tokenMask, bool calcLT) internal view returns (address token, uint16 lt) {
        uint256 t = tokenByMask[_tokenMask];
        if (t == TOKEN_NO_TOKEN) {
            console.log("Cant find token with mask");
            console.log(_tokenMask);
            revert("Token not found");
        }

        token = addressOf[t];
        if (calcLT) lt = lts[t];
    }

    /// HELPERS

    /// @dev Deployes order token and store info
    function deploy(uint256 t, string memory symbol, uint8 index) internal {
        address token = address(new OrderToken());
        addressOf[t] = token;
        tokenOf[token] = t;

        uint256 mask = 1 << index;

        tokenMask[t] = mask;
        tokenByMask[mask] = t;

        symbolOf[t] = symbol;
        vm.label(addressOf[t], symbol);
    }

    function setTokenParams(uint256 t, uint16 lt, uint256 price) internal {
        lts[t] = lt;
        prices[t] = price;
        _prices[addressOf[t]] = price;
    }

    function startSession() internal {
        vm.record();
    }

    function saveCallOrder() external view returns (uint256) {
        uint256 currentToken = tokenOf[msg.sender];
        if (currentToken == TOKEN_NO_TOKEN) {
            revert("Incorrect tokens order");
        }

        uint256 slot = uint256(currentToken) + 100;

        assembly {
            let temp := sload(slot)
            let ptr := mload(0x40)
            mstore(ptr, temp)
            return(ptr, 0x20)
        }
    }

    function expectTokensOrder(uint256[] memory tokens, bool debug) internal {
        (bytes32[] memory reads,) = vm.accesses(address(this));

        uint256 len = reads.length;

        uint256[] memory callOrder = new uint256[](len);
        uint256 j;

        for (uint256 i; i < len; ++i) {
            uint256 slot = uint256(reads[i]);
            if (slot > 100 && slot <= (100 + NUM_TOKENS)) {
                callOrder[j] = slot - 100;
                ++j;
            }
        }

        len = tokens.length;

        if (j != len) {
            console.log(caseName);
            console.log("Different length of expected and called tokens", j, len);
            console.log("Expected: ");
            printTokens(tokens);
            console.log("\nCall order: ");
            printTokens(callOrder);
            revert("Incorrect order call");
        }

        for (uint256 i; i < len; ++i) {
            if (callOrder[i] != tokens[i]) {
                console.log(caseName);
                console.log("Incorrect order of tokens calls");
                console.log("Expected: ");
                printTokens(tokens);
                console.log("\nCall order: ");
                printTokens(callOrder);
                revert("Incorrect order call");
            }
        }

        if (debug) {
            console.log(caseName);
            console.log("Tokens were called in correct order");
            printTokens(tokens);
        }
    }

    function printTokens(uint256[] memory tokens) internal view {
        uint256 len = tokens.length;

        for (uint256 i; i < len; ++i) {
            uint256 t = tokens[i];
            if (t == TOKEN_NO_TOKEN) break;
            console.log(symbolOf[t]);
        }
    }

    function getTokenMask(uint256[] memory tokens) internal view returns (uint256 mask) {
        uint256 len = tokens.length;
        for (uint256 i; i < len; ++i) {
            mask |= tokenMask[tokens[i]];
        }
    }

    function getHints(uint256[] memory tokens) internal view returns (uint256[] memory collateralHints) {
        uint256 len = tokens.length;
        collateralHints = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            collateralHints[i] = tokenMask[tokens[i]];
        }
    }

    function setBalances(B[] memory balances) internal {
        uint256 len = balances.length;
        for (uint256 i; i < len; ++i) {
            OrderToken(addressOf[balances[i].t]).setBalance(balances[i].balance);
        }
    }

    function getQuotas(Q[] memory quotas)
        internal
        view
        returns (address[] memory quotedTokens, uint256[] memory quotasPacked)
    {
        uint256 len = quotas.length;

        quotedTokens = new address[](len);
        quotasPacked = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            quotedTokens[i] = addressOf[quotas[i].t];
            quotasPacked[i] = CollateralLogic.packQuota(uint96(quotas[i].quota), lts[quotas[i].t]);
        }
    }

    ///

    function arrayOfTokens(uint256 t1) internal pure returns (uint256[] memory result) {
        result = new uint256[](1);
        result[0] = t1;
    }

    function arrayOfTokens(uint256 t1, uint256 t2) internal pure returns (uint256[] memory result) {
        result = new uint256[](2);
        result[0] = t1;
        result[1] = t2;
    }

    function arrayOfTokens(uint256 t1, uint256 t2, uint256 t3) internal pure returns (uint256[] memory result) {
        result = new uint256[](3);
        result[0] = t1;
        result[1] = t2;
        result[2] = t3;
    }

    function arrayOfTokens(uint256 t1, uint256 t2, uint256 t3, uint256 t4)
        internal
        pure
        returns (uint256[] memory result)
    {
        result = new uint256[](4);
        result[0] = t1;
        result[1] = t2;
        result[2] = t3;
        result[3] = t4;
    }

    function arrayOfTokens(uint256 t1, uint256 t2, uint256 t3, uint256 t4, uint256 t5)
        internal
        pure
        returns (uint256[] memory result)
    {
        result = new uint256[](5);
        result[0] = t1;
        result[1] = t2;
        result[2] = t3;
        result[3] = t4;
        result[4] = t5;
    }

    function arrayOf(B memory t1) internal pure returns (B[] memory result) {
        result = new B[](1);
        result[0] = t1;
    }

    function arrayOf(B memory t1, B memory t2) internal pure returns (B[] memory result) {
        result = new B[](2);
        result[0] = t1;
        result[1] = t2;
    }

    function arrayOf(B memory t1, B memory t2, B memory t3) internal pure returns (B[] memory result) {
        result = new B[](3);
        result[0] = t1;
        result[1] = t2;
        result[2] = t3;
    }

    function arrayOf(B memory t1, B memory t2, B memory t3, B memory t4) internal pure returns (B[] memory result) {
        result = new B[](4);
        result[0] = t1;
        result[1] = t2;
        result[2] = t3;
        result[3] = t4;
    }

    function arrayOf(B memory t1, B memory t2, B memory t3, B memory t4, B memory t5)
        internal
        pure
        returns (B[] memory result)
    {
        result = new B[](5);
        result[0] = t1;
        result[1] = t2;
        result[2] = t3;
        result[3] = t4;
        result[4] = t5;
    }

    function arrayOf(Q memory t1) internal pure returns (Q[] memory result) {
        result = new Q[](1);
        result[0] = t1;
    }

    function arrayOf(Q memory t1, Q memory t2) internal pure returns (Q[] memory result) {
        result = new Q[](2);
        result[0] = t1;
        result[1] = t2;
    }

    function arrayOf(Q memory t1, Q memory t2, Q memory t3) internal pure returns (Q[] memory result) {
        result = new Q[](3);
        result[0] = t1;
        result[1] = t2;
        result[2] = t3;
    }

    function arrayOf(Q memory t1, Q memory t2, Q memory t3, Q memory t4) internal pure returns (Q[] memory result) {
        result = new Q[](4);
        result[0] = t1;
        result[1] = t2;
        result[2] = t3;
        result[3] = t4;
    }

    function arrayOf(Q memory t1, Q memory t2, Q memory t3, Q memory t4, Q memory t5)
        internal
        pure
        returns (Q[] memory result)
    {
        result = new Q[](5);
        result[0] = t1;
        result[1] = t2;
        result[2] = t3;
        result[3] = t4;
        result[4] = t5;
    }
}

contract OrderToken {
    uint256 returnBalance;

    address immutable orderChecker;

    constructor() {
        orderChecker = msg.sender;
    }

    function balanceOf(address) external view returns (uint256 amount) {
        CollateralLogicHelper(orderChecker).saveCallOrder();
        amount = returnBalance;
    }

    function setBalance(uint256 balance) external {
        returnBalance = balance;
    }
}
