// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {TokensTestSuite} from "../suites/TokensTestSuite.sol";
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

import {BalanceEngine} from "./BalanceEngine.sol";
import "forge-std/Vm.sol";
import "forge-std/console.sol";

enum Assertion {
    EQUAL,
    IN_RANGE,
    GE,
    LE
}

struct ExpectedTokenTransfer {
    string reason;
    address token;
    address from;
    address to;
    uint256 amount;
    Assertion assertion;
    uint256 lowerBound;
    uint256 upperBound;
}

struct TransferCheck {
    uint256 amount;
    bool exists;
    bool used;
}

contract BalanceHelper is BalanceEngine {
    // Suites
    TokensTestSuite public tokenTestSuite;

    uint256 internal tokenTrackingSession = 1;
    mapping(uint256 => mapping(address => mapping(address => mapping(address => TransferCheck)))) internal
        _transfersCheck;

    mapping(uint256 => ExpectedTokenTransfer[]) internal _expectedTransfers;

    string private caseName;

    function startTokenTrackingSession(string memory _caseName) internal {
        tokenTrackingSession++;
        vm.recordLogs();
        caseName = _caseName;
    }

    function expectTokenTransfer(address token, address from, address to, uint256 amount) internal {
        expectTokenTransfer({reason: "", token: token, from: from, to: to, amount: amount});
    }

    function expectTokenTransfer(address token, address from, address to, uint256 amount, string memory reason)
        internal
    {
        _expectedTransfers[tokenTrackingSession].push(
            ExpectedTokenTransfer({
                reason: reason,
                token: token,
                from: from,
                to: to,
                amount: amount,
                assertion: Assertion.EQUAL,
                lowerBound: 0,
                upperBound: 0
            })
        );
    }

    function checkTokenTransfers(bool debug) internal {
        VmSafe.Log[] memory entries = vm.getRecordedLogs();

        uint256 len = entries.length;

        if (debug) {
            console.log("\n*** ", caseName, " ***\n");
            console.log("Transfers found:\n");
        }
        uint256 j = 1;
        for (uint256 i; i < len; ++i) {
            Vm.Log memory entry = entries[i];

            if (entry.topics[0] == keccak256("Transfer(address,address,uint256)")) {
                address token = entry.emitter;
                address from = address(uint160(uint256(entry.topics[1])));
                address to = address(uint160(uint256(entry.topics[2])));
                uint256 amount = abi.decode(entry.data, (uint256));

                _transfersCheck[tokenTrackingSession][token][from][to] =
                    TransferCheck({amount: amount, exists: true, used: false});

                if (debug) {
                    console.log("%s. %s => %s", j, from, to);
                    console.log("   %s %s\n", amount, IERC20Metadata(token).symbol());

                    j++;
                }
            }
        }

        len = _expectedTransfers[tokenTrackingSession].length;
        for (uint256 i; i < len; ++i) {
            ExpectedTokenTransfer storage et = _expectedTransfers[tokenTrackingSession][i];
            address token = et.token;
            TransferCheck storage tc = _transfersCheck[tokenTrackingSession][token][et.from][et.to];

            if ((!tc.exists) || tc.used) {
                _consoleErr(et);
                assertTrue(tc.exists, "Transfer not found!");
                assertTrue(!tc.used, "Transfer was called twice!");
            } else if (et.assertion == Assertion.EQUAL && et.amount != tc.amount) {
                _consoleErr(et);
                assertEq(tc.amount, et.amount, "Amounts are different");
            } else if (et.assertion == Assertion.IN_RANGE && (tc.amount < et.lowerBound || tc.amount > et.upperBound)) {
                _consoleErr(et);
                assertLt(tc.amount, et.lowerBound, "Amount less than lower bound");
                assertGt(tc.amount, et.upperBound, "Amount greater than upper bound");
            } else if (et.assertion == Assertion.GE && (tc.amount < et.amount)) {
                _consoleErr(et);
                assertGe(tc.amount, et.amount, "Amount greater than expected");
            } else if (et.assertion == Assertion.LE && (tc.amount > et.amount)) {
                _consoleErr(et);
                assertLe(tc.amount, et.amount, "Amount less than expected");
            } else {
                if (debug) console.log("[ PASS ]", et.reason);
            }

            tc.used = true;
        }
    }

    function _consoleErr(ExpectedTokenTransfer storage et) internal view {
        console.log("Case: ", caseName);
        console.log(et.reason);
        console.log("Problem with transfer of %s (%s)", IERC20Metadata(et.token).symbol(), et.token);
        console.log("  %s => %s", et.from, et.to);
    }

    modifier withTokenSuite() {
        require(address(tokenTestSuite) != address(0), "tokenTestSuite is not set");
        _;
    }

    function expectBalance(Tokens t, address holder, uint256 expectedBalance) internal withTokenSuite {
        expectBalance(t, holder, expectedBalance, "");
    }

    function expectBalance(Tokens t, address holder, uint256 expectedBalance, string memory reason)
        internal
        withTokenSuite
    {
        expectBalance(tokenTestSuite.addressOf(t), holder, expectedBalance, reason);
    }

    function expectBalanceGe(Tokens t, address holder, uint256 minBalance, string memory reason)
        internal
        withTokenSuite
    {
        require(address(tokenTestSuite) != address(0), "tokenTestSuite is not set");

        expectBalanceGe(tokenTestSuite.addressOf(t), holder, minBalance, reason);
    }

    function expectBalanceLe(Tokens t, address holder, uint256 maxBalance, string memory reason)
        internal
        withTokenSuite
    {
        expectBalanceLe(tokenTestSuite.addressOf(t), holder, maxBalance, reason);
    }

    function expectAllowance(Tokens t, address owner, address spender, uint256 expectedAllowance)
        internal
        withTokenSuite
    {
        expectAllowance(t, owner, spender, expectedAllowance, "");
    }

    function expectAllowance(Tokens t, address owner, address spender, uint256 expectedAllowance, string memory reason)
        internal
        withTokenSuite
    {
        require(address(tokenTestSuite) != address(0), "tokenTestSuite is not set");

        expectAllowance(tokenTestSuite.addressOf(t), owner, spender, expectedAllowance, reason);
    }
}
