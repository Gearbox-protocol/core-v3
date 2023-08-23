// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import {MockTokensData, MockToken} from "../../config/MockTokensData.sol";
import {CollateralLogic} from "../../../libraries/CollateralLogic.sol";

import "../../lib/constants.sol";

import {TestHelper} from "../../lib/helper.sol";

import "forge-std/console.sol";

address constant PRICE_ORACLE = DUMB_ADDRESS4;

struct B {
    Tokens t;
    uint256 balance;
}

struct Q {
    Tokens t;
    uint256 quota;
}

contract CollateralLogicHelper is TestHelper {
    uint256 session;

    mapping(Tokens => uint256) tokenMask;

    mapping(uint256 => Tokens) tokenByMask;

    mapping(Tokens => address) addressOf;
    mapping(Tokens => string) symbolOf;
    mapping(address => Tokens) tokenOf;

    mapping(Tokens => uint16) lts;

    mapping(address => uint256) _prices;
    mapping(Tokens => uint256) prices;

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
        Tokens t = tokenByMask[_tokenMask];
        if (t == Tokens.NO_TOKEN) {
            console.log("Cant find token with mask");
            console.log(_tokenMask);
            revert("Token not found");
        }

        token = addressOf[t];
        if (calcLT) lt = lts[t];
    }

    /// HELPERS

    /// @dev Deployes order token and store info
    function deploy(Tokens t, string memory symbol, uint8 index) internal {
        address token = address(new OrderToken());
        addressOf[t] = token;
        tokenOf[token] = t;

        uint256 mask = 1 << index;

        tokenMask[t] = mask;
        tokenByMask[mask] = t;

        symbolOf[t] = symbol;
        vm.label(addressOf[t], symbol);
    }

    function setTokenParams(Tokens t, uint16 lt, uint256 price) internal {
        lts[t] = lt;
        prices[t] = price;
        _prices[addressOf[t]] = price;
    }

    function startSession() internal {
        vm.record();
    }

    function saveCallOrder() external view returns (uint256) {
        Tokens currentToken = tokenOf[msg.sender];
        if (currentToken == Tokens.NO_TOKEN) {
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

    function expectTokensOrder(Tokens[] memory tokens, bool debug) internal {
        (bytes32[] memory reads,) = vm.accesses(address(this));

        uint256 len = reads.length;

        Tokens[] memory callOrder = new Tokens[](len);
        uint256 j;

        for (uint256 i; i < len; ++i) {
            uint256 slot = uint256(reads[i]);
            if (slot > 100 && slot <= (100 + uint256(type(Tokens).max))) {
                callOrder[j] = Tokens(slot - 100);
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

    function printTokens(Tokens[] memory tokens) internal view {
        uint256 len = tokens.length;

        for (uint256 i; i < len; ++i) {
            Tokens t = Tokens(tokens[i]);
            if (t == Tokens.NO_TOKEN) break;
            console.log(symbolOf[t]);
        }
    }

    function getTokenMask(Tokens[] memory tokens) internal view returns (uint256 mask) {
        uint256 len = tokens.length;
        for (uint256 i; i < len; ++i) {
            mask |= tokenMask[tokens[i]];
        }
    }

    function getHints(Tokens[] memory tokens) internal view returns (uint256[] memory collateralHints) {
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

    function arrayOf(Tokens t1) internal pure returns (Tokens[] memory result) {
        result = new Tokens[](1);
        result[0] = t1;
    }

    function arrayOf(Tokens t1, Tokens t2) internal pure returns (Tokens[] memory result) {
        result = new Tokens[](2);
        result[0] = t1;
        result[1] = t2;
    }

    function arrayOf(Tokens t1, Tokens t2, Tokens t3) internal pure returns (Tokens[] memory result) {
        result = new Tokens[](3);
        result[0] = t1;
        result[1] = t2;
        result[2] = t3;
    }

    function arrayOf(Tokens t1, Tokens t2, Tokens t3, Tokens t4) internal pure returns (Tokens[] memory result) {
        result = new Tokens[](4);
        result[0] = t1;
        result[1] = t2;
        result[2] = t3;
        result[3] = t4;
    }

    function arrayOf(Tokens t1, Tokens t2, Tokens t3, Tokens t4, Tokens t5)
        internal
        pure
        returns (Tokens[] memory result)
    {
        result = new Tokens[](5);
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
