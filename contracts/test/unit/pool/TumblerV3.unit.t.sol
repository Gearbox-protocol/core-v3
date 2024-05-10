// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

import {
    CallerNotControllerException,
    IncorrectParameterException,
    TokenIsNotQuotedException,
    TokenNotAllowedException,
    ZeroAddressException
} from "../../../interfaces/IExceptions.sol";
import {ITumblerV3Events, TokenRate} from "../../../interfaces/ITumblerV3.sol";

import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {PoolMock} from "../../mocks/pool/PoolMock.sol";
import {PoolQuotaKeeperMock} from "../../mocks/pool/PoolQuotaKeeperMock.sol";

import {TumblerV3Harness} from "./TumblerV3Harness.sol";

/// @title Tumbler V3 unit test
/// @notice U:[TU]: Unit tests for tumbler contract
contract TumblerV3UnitTest is Test, ITumblerV3Events {
    TumblerV3Harness tumbler;

    PoolMock pool;
    PoolQuotaKeeperMock poolQuotaKeeper;
    AddressProviderV3ACLMock addressProvider;

    address underlying = makeAddr("underlying");
    address token1 = makeAddr("token1");
    address token2 = makeAddr("token2");

    function setUp() public {
        addressProvider = new AddressProviderV3ACLMock();
        pool = new PoolMock(address(addressProvider), underlying);
        poolQuotaKeeper = new PoolQuotaKeeperMock(address(pool), underlying);
        poolQuotaKeeper.set_lastQuotaRateUpdate(uint40(block.timestamp));
        pool.setPoolQuotaKeeper(address(poolQuotaKeeper));

        tumbler = new TumblerV3Harness(address(addressProvider), address(pool), 1 days);
    }

    /// @notice U:[TU-1]: Constructor works as expected
    function test_U_TU_01_constructor_works_as_expected() public {
        assertEq(tumbler.pool(), address(pool), "Incorrect pool");
        assertEq(tumbler.underlying(), underlying, "Incorrect underlying");
        assertEq(tumbler.poolQuotaKeeper(), address(poolQuotaKeeper), "Incorrect poolQuotaKeeper");
        assertEq(tumbler.epochLength(), 1 days, "Incorrect epochLength");
        assertEq(tumbler.getTokens().length, 0, "Non-empty quoted tokens set");
    }

    /// @notice U:[TU-2]: `_addToken` works as expected
    function test_U_TU_02_addToken_works_as_expected() public {
        // reverts if token is zero address
        vm.expectRevert(ZeroAddressException.selector);
        tumbler.exposed_addToken(address(0));

        // reverts if token is underlying
        vm.expectRevert(TokenNotAllowedException.selector);
        tumbler.exposed_addToken(underlying);

        // properly adds token to both rate and quota keeper
        poolQuotaKeeper.set_isQuotedToken(false);
        vm.expectCall(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.isQuotedToken, (token1)));
        vm.expectCall(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.addQuotaToken, (token1)));

        vm.expectEmit(true, true, true, true);
        emit AddToken(token1);

        tumbler.exposed_addToken(token1);

        address[] memory quotedTokens = tumbler.getTokens();
        assertEq(quotedTokens.length, 1, "Incorrect getTokens.length");
        assertEq(quotedTokens[0], token1, "Incorrect getTokens[0]");

        // skips everything if token is already added
        vm.mockCallRevert(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.isQuotedToken, (token1)), "");
        tumbler.exposed_addToken(token1);
        vm.clearMockedCalls();

        // adds token to tumbler but skips quota keeper if token is already there
        poolQuotaKeeper.set_isQuotedToken(true);
        vm.expectCall(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.isQuotedToken, (token2)));
        vm.mockCallRevert(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.addQuotaToken, (token2)), "");

        vm.expectEmit(true, true, true, true);
        emit AddToken(token2);

        tumbler.exposed_addToken(token2);

        quotedTokens = tumbler.getTokens();
        assertEq(quotedTokens.length, 2, "Incorrect getTokens.length");
        assertEq(quotedTokens[0], token1, "Incorrect getTokens[0]");
        assertEq(quotedTokens[1], token2, "Incorrect getTokens[1]");
    }

    /// @notice U:[TU-3]: `_setRate` works as expected
    function test_U_TU_03_setRate_works_as_expected() public {
        address[] memory tokens = new address[](1);
        tokens[0] = token1;

        // setRate reverts on zero rate
        vm.expectRevert(IncorrectParameterException.selector);
        tumbler.exposed_setRate(token1, 0);

        // getRates reverts if rate is not set
        vm.expectRevert(TokenIsNotQuotedException.selector);
        tumbler.getRates(tokens);

        // setRate properly sets rate
        vm.expectEmit(true, true, true, true);
        emit SetRate(token1, 4200);

        tumbler.exposed_setRate(token1, 4200);

        // getRate properly returns rate
        uint16[] memory rates = tumbler.getRates(tokens);
        assertEq(rates.length, 1, "Incorrect rates.length");
        assertEq(rates[0], 4200, "Incorrect rates[0]");
    }

    /// @notice U:[TU-4]: `setRates` works as expected
    function test_U_TU_04_setQuotaRates_works_as_expected() public {
        // reverts on unauthorized caller
        vm.expectRevert(CallerNotControllerException.selector);
        vm.prank(makeAddr("dude"));
        tumbler.setRates(new TokenRate[](0));

        // skips update in quota keeper
        vm.expectCall(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.lastQuotaRateUpdate, ()));
        vm.mockCallRevert(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.updateRates, ()), "");

        tumbler.setRates(new TokenRate[](0));

        vm.clearMockedCalls();
        vm.warp(block.timestamp + 1 days);

        // sets rates for all tokens and updates them in quota keeper
        TokenRate[] memory rates = new TokenRate[](2);
        rates[0] = TokenRate(token1, 4200);
        rates[1] = TokenRate(token2, 12000);

        vm.expectEmit(true, true, true, true);
        emit AddToken(token1);

        vm.expectEmit(true, true, true, true);
        emit SetRate(token1, 4200);

        vm.expectEmit(true, true, true, true);
        emit AddToken(token2);

        vm.expectEmit(true, true, true, true);
        emit SetRate(token2, 12000);

        vm.expectCall(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.updateRates, ()));

        tumbler.setRates(rates);
    }
}
