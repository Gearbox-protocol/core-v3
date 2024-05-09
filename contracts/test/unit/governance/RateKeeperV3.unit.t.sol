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
import {IRateKeeperV3Events, TokenRate} from "../../../interfaces/IRateKeeperV3.sol";

import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {PoolMock} from "../../mocks/pool/PoolMock.sol";
import {PoolQuotaKeeperMock} from "../../mocks/pool/PoolQuotaKeeperMock.sol";

import {RateKeeperV3Harness} from "./RateKeeperV3Harness.sol";

/// @title Rate keeper V3 unit test
/// @notice U:[RK]: Unit tests for rate keeper contract
contract RateKeeperV3UnitTest is Test, IRateKeeperV3Events {
    RateKeeperV3Harness rateKeeper;

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

        rateKeeper = new RateKeeperV3Harness(address(addressProvider), address(pool), 1 days);
    }

    /// @notice U:[RK-1]: Constructor works as expected
    function test_U_RK_01_constructor_works_as_expected() public {
        assertEq(rateKeeper.pool(), address(pool), "Incorrect pool");
        assertEq(rateKeeper.underlying(), underlying, "Incorrect underlying");
        assertEq(rateKeeper.poolQuotaKeeper(), address(poolQuotaKeeper), "Incorrect poolQuotaKeeper");
        assertEq(rateKeeper.epochLength(), 1 days, "Incorrect epochLength");
        assertEq(rateKeeper.getTokens().length, 0, "Non-empty quoted tokens set");
    }

    /// @notice U:[RK-2]: `_addToken` works as expected
    function test_U_RK_02_addToken_works_as_expected() public {
        // reverts if token is zero address
        vm.expectRevert(ZeroAddressException.selector);
        rateKeeper.exposed_addToken(address(0));

        // reverts if token is underlying
        vm.expectRevert(TokenNotAllowedException.selector);
        rateKeeper.exposed_addToken(underlying);

        // properly adds token to both rate and quota keeper
        poolQuotaKeeper.set_isQuotedToken(false);
        vm.expectCall(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.isQuotedToken, (token1)));
        vm.expectCall(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.addQuotaToken, (token1)));

        vm.expectEmit(true, true, true, true);
        emit AddToken(token1);

        rateKeeper.exposed_addToken(token1);

        address[] memory quotedTokens = rateKeeper.getTokens();
        assertEq(quotedTokens.length, 1, "Incorrect getTokens.length");
        assertEq(quotedTokens[0], token1, "Incorrect getTokens[0]");

        // skips everything if token is already added
        vm.mockCallRevert(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.isQuotedToken, (token1)), "");
        rateKeeper.exposed_addToken(token1);
        vm.clearMockedCalls();

        // adds token to rate keeper but skips quota keeper if token is already there
        poolQuotaKeeper.set_isQuotedToken(true);
        vm.expectCall(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.isQuotedToken, (token2)));
        vm.mockCallRevert(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.addQuotaToken, (token2)), "");

        vm.expectEmit(true, true, true, true);
        emit AddToken(token2);

        rateKeeper.exposed_addToken(token2);

        quotedTokens = rateKeeper.getTokens();
        assertEq(quotedTokens.length, 2, "Incorrect getTokens.length");
        assertEq(quotedTokens[0], token1, "Incorrect getTokens[0]");
        assertEq(quotedTokens[1], token2, "Incorrect getTokens[1]");
    }

    /// @notice U:[RK-3]: `_setRate` works as expected
    function test_U_RK_03_setRate_works_as_expected() public {
        address[] memory tokens = new address[](1);
        tokens[0] = token1;

        // setRate reverts on zero rate
        vm.expectRevert(IncorrectParameterException.selector);
        rateKeeper.exposed_setRate(token1, 0);

        // getRates reverts if rate is not set
        vm.expectRevert(TokenIsNotQuotedException.selector);
        rateKeeper.getRates(tokens);

        // setRate properly sets rate
        vm.expectEmit(true, true, true, true);
        emit SetRate(token1, 4200);

        rateKeeper.exposed_setRate(token1, 4200);

        // getRate properly returns rate
        uint16[] memory rates = rateKeeper.getRates(tokens);
        assertEq(rates.length, 1, "Incorrect rates.length");
        assertEq(rates[0], 4200, "Incorrect rates[0]");
    }

    /// @notice U:[RK-4]: `setRates` works as expected
    function test_U_RK_04_setQuotaRates_works_as_expected() public {
        // reverts on unauthorized caller
        vm.expectRevert(CallerNotControllerException.selector);
        vm.prank(makeAddr("dude"));
        rateKeeper.setRates(new TokenRate[](0));

        // skips update in quota keeper
        vm.expectCall(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.lastQuotaRateUpdate, ()));
        vm.mockCallRevert(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.updateRates, ()), "");

        rateKeeper.setRates(new TokenRate[](0));

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

        rateKeeper.setRates(rates);
    }
}
