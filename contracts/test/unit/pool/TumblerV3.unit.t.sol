// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {
    CallerNotControllerOrConfiguratorException,
    IncorrectParameterException,
    TokenIsNotQuotedException,
    TokenNotAllowedException,
    ZeroAddressException
} from "../../../interfaces/IExceptions.sol";
import {ITumblerV3Events} from "../../../interfaces/ITumblerV3.sol";

import {TumblerV3} from "../../../pool/TumblerV3.sol";

import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {PoolMock} from "../../mocks/pool/PoolMock.sol";
import {PoolQuotaKeeperMock} from "../../mocks/pool/PoolQuotaKeeperMock.sol";

/// @title Tumbler V3 unit test
/// @notice U:[TU]: Unit tests for tumbler contract
contract TumblerV3UnitTest is Test, ITumblerV3Events {
    TumblerV3 tumbler;

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

        tumbler = new TumblerV3(address(addressProvider), address(poolQuotaKeeper), 1 days);
    }

    /// @notice U:[TU-1]: Constructor works as expected
    function test_U_TU_01_constructor_works_as_expected() public {
        assertEq(tumbler.quotaKeeper(), address(poolQuotaKeeper), "Incorrect quotaKeeper");
        assertEq(tumbler.epochLength(), 1 days, "Incorrect epochLength");

        vm.expectRevert(ZeroAddressException.selector);
        new TumblerV3(address(addressProvider), address(0), 1 days);
    }

    /// @notice U:[TU-2]: `addToken` works as expected
    function test_U_TU_02_addToken_works_as_expected() public {
        // getRates reverts if token is not added
        address[] memory tokens = new address[](1);
        tokens[0] = token1;
        vm.expectRevert(TokenIsNotQuotedException.selector);
        tumbler.getRates(tokens);

        // addToken reverts if token is zero address
        vm.expectRevert(ZeroAddressException.selector);
        tumbler.addToken(address(0), 1);

        // addToken properly adds token to both rate and quota keeper and sets rate
        poolQuotaKeeper.set_isQuotedToken(false);
        vm.expectCall(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.isQuotedToken, (token1)));
        vm.expectCall(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.addQuotaToken, (token1)));

        vm.expectEmit(true, true, true, true);
        emit AddToken(token1);

        vm.expectEmit(true, true, true, true);
        emit SetRate(token1, 4200);

        tumbler.addToken(token1, 4200);

        assertTrue(tumbler.isTokenAdded(token1), "token1 is not added");

        // addToken reverts if token is already added
        vm.expectRevert(TokenNotAllowedException.selector);
        tumbler.addToken(token1, 1);

        // addToken adds token to tumbler but skips quota keeper if token is already there
        poolQuotaKeeper.set_isQuotedToken(true);
        vm.expectCall(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.isQuotedToken, (token2)));
        vm.mockCallRevert(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.addQuotaToken, (token2)), "");

        vm.expectEmit(true, true, true, true);
        emit AddToken(token2);

        vm.expectEmit(true, true, true, true);
        emit SetRate(token2, 1);

        tumbler.addToken(token2, 1);

        assertTrue(tumbler.isTokenAdded(token2), "token2 is not added");
    }

    /// @notice U:[TU-3]: `setRate` works as expected
    function test_U_TU_03_setRate_works_as_expected() public {
        address[] memory tokens = new address[](1);
        tokens[0] = token1;

        // setRate reverts if token is not added
        vm.expectRevert(TokenIsNotQuotedException.selector);
        tumbler.setRate(token1, 1);

        tumbler.addToken(token1, 1);

        // setRate reverts on zero rate
        vm.expectRevert(IncorrectParameterException.selector);
        tumbler.setRate(token1, 0);

        // setRate properly sets rate
        vm.expectEmit(true, true, true, true);
        emit SetRate(token1, 4200);

        tumbler.setRate(token1, 4200);

        // getRate properly returns rate
        uint16[] memory rates = tumbler.getRates(tokens);
        assertEq(rates.length, 1, "Incorrect rates.length");
        assertEq(rates[0], 4200, "Incorrect rates[0]");
    }

    /// @notice U:[TU-4]: `updateRates` works as expected
    function test_U_TU_04_updateRates_works_as_expected() public {
        // reverts on unauthorized caller
        vm.expectRevert(CallerNotControllerOrConfiguratorException.selector);
        vm.prank(makeAddr("dude"));
        tumbler.updateRates();

        // skips update in quota keeper
        vm.expectCall(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.lastQuotaRateUpdate, ()));
        vm.mockCallRevert(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.updateRates, ()), "");

        tumbler.updateRates();

        vm.clearMockedCalls();
        vm.warp(block.timestamp + 1 days);

        tumbler.addToken(token1, 4200);
        tumbler.addToken(token2, 12000);

        // updates rates in quota keeper
        vm.expectCall(address(poolQuotaKeeper), abi.encodeCall(poolQuotaKeeper.updateRates, ()));
        tumbler.updateRates();
    }
}
