// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPriceFeed, IUpdatablePriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";

import {IPriceOracleV3Events, PriceFeedParams} from "../../../interfaces/IPriceOracleV3.sol";
import "../../../interfaces/IExceptions.sol";

import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";
import {PriceFeedMock, FlagState} from "../../mocks/oracles/PriceFeedMock.sol";
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";

import {PriceOracleV3Harness} from "./PriceOracleV3Harness.sol";

/// @title Price oracle V3 unit test
/// @notice U:[PO]: Unit tests for price oracle
contract PriceOracleV3UnitTest is Test, IPriceOracleV3Events {
    PriceOracleV3Harness priceOracle;

    address configurator;
    AddressProviderV3ACLMock ap;

    function setUp() public {
        configurator = makeAddr("CONFIGURATOR");
        vm.prank(configurator);
        ap = new AddressProviderV3ACLMock();
        priceOracle = new PriceOracleV3Harness(address(ap));
    }

    // ----------------------- //
    // CORE INTERNAL FUNCTIONS //
    // ----------------------- //

    /// @notice U:[PO-1]: `_getPrice` works as expected
    function test_U_PO_01_getPrice_works_as_expected(
        int256 answer,
        uint256 updatedAt,
        uint32 stalenessPeriod,
        bool skipCheck,
        uint8 decimals
    ) public {
        updatedAt = bound(updatedAt, 0, block.timestamp);
        if (skipCheck) answer = bound(answer, 1, type(int256).max);
        decimals = uint8(bound(decimals, 1, 18));

        address priceFeed = makeAddr("PRICE_FEED");

        vm.mockCall(
            priceFeed,
            abi.encodeCall(IPriceFeed.latestRoundData, ()),
            abi.encode(uint80(0), answer, uint256(0), updatedAt, uint80(0))
        );

        vm.expectCall(priceFeed, abi.encodeCall(IPriceFeed.latestRoundData, ()));

        bool mustRevert;
        if (answer <= 0) {
            vm.expectRevert(IncorrectPriceException.selector);
            mustRevert = true;
        } else if (!skipCheck && block.timestamp >= updatedAt + stalenessPeriod) {
            vm.expectRevert(StalePriceException.selector);
            mustRevert = true;
        }

        (uint256 price, uint256 scale) = priceOracle.getPrice(priceFeed, stalenessPeriod, skipCheck, decimals);

        if (!mustRevert) {
            assertEq(price, uint256(answer), "Incorrect price");
            assertEq(scale, 10 ** decimals, "Incorrect scale");
        }
    }

    /// @notice U:[PO-2]: `_getPriceFeedParams` works as expected
    function test_U_PO_02_getPriceFeedParams_works_as_expected(address token, PriceFeedParams memory expectedParams)
        public
    {
        priceOracle.hackPriceFeedParams(token, expectedParams);

        if (expectedParams.priceFeed == address(0)) {
            vm.expectRevert(PriceFeedDoesNotExistException.selector);
        }

        PriceFeedParams memory params = priceOracle.getPriceFeedParams(token);

        if (expectedParams.priceFeed == address(0)) return;

        assertEq(params.priceFeed, expectedParams.priceFeed, "Incorrect priceFeed");
        assertEq(params.stalenessPeriod, expectedParams.stalenessPeriod, "Incorrect stalenessPeriod");
        assertEq(params.decimals, expectedParams.decimals, "Incorrect decimals");
        assertEq(params.skipCheck, expectedParams.skipCheck, "Incorrect skipCheck");
        assertEq(params.useReserve, expectedParams.useReserve, "Incorrect useReserve");
        assertEq(params.trusted, expectedParams.trusted, "Incorrect trusted");
    }

    /// @notice U:[PO-3]: `_getTokenReserveKey` works as expected
    /// forge-config: default.fuzz.runs = 5000
    function test_U_PO_03_getTokenReserveKey_works_as_expected(address token) public {
        address expectedKey = address(uint160(uint256(keccak256(abi.encodePacked("RESERVE", token)))));
        assertEq(priceOracle.getTokenReserveKey(token), expectedKey);
    }

    /// @notice U:[PO-4]: `_validateToken` works as expected
    function test_U_PO_04_validateToken_works_as_expected() public {
        address token = makeAddr("TOKEN");

        vm.etch(token, "");
        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, token));
        priceOracle.validateToken(token);

        vm.etch(token, "CODE");

        vm.mockCallRevert(token, abi.encodeCall(ERC20.decimals, ()), "");
        vm.expectRevert(IncorrectTokenContractException.selector);
        priceOracle.validateToken(token);

        vm.mockCall(token, abi.encodeCall(ERC20.decimals, ()), abi.encode(uint8(0)));
        vm.expectRevert(IncorrectTokenContractException.selector);
        priceOracle.validateToken(token);

        vm.mockCall(token, abi.encodeCall(ERC20.decimals, ()), abi.encode(uint8(19)));
        vm.expectRevert(IncorrectTokenContractException.selector);
        priceOracle.validateToken(token);

        vm.mockCall(token, abi.encodeCall(ERC20.decimals, ()), abi.encode(uint8(6)));
        uint8 decimals = priceOracle.validateToken(token);
        assertEq(decimals, 6, "Incorrect decimals");
    }

    /// @notice U:[PO-5]: `_validatePriceFeed` works as expected
    function test_U_PO_05_validatePriceFeed_works_as_expected() public {
        address priceFeed = makeAddr("PRICE_FEED");

        // not a contract
        vm.etch(priceFeed, "");
        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, priceFeed));
        priceOracle.validatePriceFeed(priceFeed, 0);

        vm.etch(priceFeed, "CODE");

        // does not implement `decimals()`
        vm.mockCallRevert(priceFeed, abi.encodeCall(IPriceFeed.decimals, ()), "");
        vm.expectRevert(IncorrectPriceFeedException.selector);
        priceOracle.validatePriceFeed(priceFeed, 0);

        // wrong decimals
        vm.mockCall(priceFeed, abi.encodeCall(IPriceFeed.decimals, ()), abi.encode(uint8(6)));
        vm.expectRevert(IncorrectPriceFeedException.selector);
        priceOracle.validatePriceFeed(priceFeed, 0);

        vm.mockCall(priceFeed, abi.encodeCall(IPriceFeed.decimals, ()), abi.encode(uint8(8)));

        // does not implement `latestRoundData()`
        vm.mockCallRevert(priceFeed, abi.encodeCall(IPriceFeed.latestRoundData, ()), "");
        vm.expectRevert(IncorrectPriceFeedException.selector);
        priceOracle.validatePriceFeed(priceFeed, 0);

        // zero staleness period while shipCheck = false
        vm.mockCall(
            priceFeed,
            abi.encodeCall(IPriceFeed.latestRoundData, ()),
            abi.encode(uint80(0), int256(42), uint256(0), block.timestamp, uint80(0))
        );
        vm.expectRevert(IncorrectParameterException.selector);
        priceOracle.validatePriceFeed(priceFeed, 0);

        // negative price
        vm.mockCall(
            priceFeed,
            abi.encodeCall(IPriceFeed.latestRoundData, ()),
            abi.encode(uint80(0), int256(-1), uint256(0), block.timestamp, uint80(0))
        );
        vm.expectRevert(IncorrectPriceException.selector);
        priceOracle.validatePriceFeed(priceFeed, 3600);

        // stale price
        vm.mockCall(
            priceFeed,
            abi.encodeCall(IPriceFeed.latestRoundData, ()),
            abi.encode(uint80(0), int256(42), uint256(0), block.timestamp - 7200, uint80(0))
        );
        vm.expectRevert(StalePriceException.selector);
        priceOracle.validatePriceFeed(priceFeed, 3600);

        // staleness check is skipped for updatable feed
        vm.mockCall(priceFeed, abi.encodeCall(IUpdatablePriceFeed.updatable, ()), abi.encode(true));
        bool skipCheck = priceOracle.validatePriceFeed(priceFeed, 3600);
        assertFalse(skipCheck, "skipCheck is unexpectedly true");

        // non-zero staleness period while skipCheck = true
        vm.mockCall(priceFeed, abi.encodeCall(IPriceFeed.skipPriceCheck, ()), abi.encode(true));
        vm.expectRevert(IncorrectParameterException.selector);
        priceOracle.validatePriceFeed(priceFeed, 3600);

        skipCheck = priceOracle.validatePriceFeed(priceFeed, 0);
        assertTrue(skipCheck, "skipCheck is unexpectedly false");
    }

    // ----------------------- //
    // CONFIGURATION FUNCTIONS //
    // ----------------------- //

    /// @notice U:[PO-6]: `setPriceFeed` works as expected
    function test_U_PO_06_setPriceFeed_works_as_expected() public {
        ERC20Mock token = new ERC20Mock("Test Token", "TEST", 18);
        PriceFeedMock priceFeed = new PriceFeedMock(42, 8);

        vm.expectRevert(ZeroAddressException.selector);
        priceOracle.setPriceFeed(address(0), address(priceFeed), 0, false);

        vm.expectRevert(ZeroAddressException.selector);
        priceOracle.setPriceFeed(address(token), address(0), 0, false);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        priceOracle.setPriceFeed(address(token), address(priceFeed), 0, false);

        vm.expectEmit(true, true, false, true);
        emit SetPriceFeed(address(token), address(priceFeed), 3600, false, false);

        vm.prank(configurator);
        priceOracle.setPriceFeed(address(token), address(priceFeed), 3600, false);
        PriceFeedParams memory params = priceOracle.getPriceFeedParams(address(token));
        assertEq(params.priceFeed, address(priceFeed), "Incorrect priceFeed");
        assertEq(params.decimals, 18, "Incorrect decimals");
        assertEq(params.skipCheck, false, "Incorrect skipCheck");
        assertEq(params.stalenessPeriod, 3600, "Incorrect stalenessPeriod");
        assertEq(params.useReserve, false, "Incorrect useReserve");
    }

    /// @notice U:[PO-7]: `setReservePriceFeed` works as expected
    function test_U_PO_07_setReservePriceFeed_works_as_expected() public {
        ERC20Mock token = new ERC20Mock("Test Token", "TEST", 18);
        PriceFeedMock priceFeed = new PriceFeedMock(42, 8);

        vm.expectRevert(ZeroAddressException.selector);
        priceOracle.setPriceFeed(address(0), address(priceFeed), 0, false);

        vm.expectRevert(ZeroAddressException.selector);
        priceOracle.setPriceFeed(address(token), address(0), 0, false);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        priceOracle.setPriceFeed(address(token), address(priceFeed), 0, false);

        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        vm.prank(configurator);
        priceOracle.setReservePriceFeed(address(token), address(priceFeed), 0);

        priceOracle.hackPriceFeedParams(address(token), PriceFeedParams(address(0), 0, false, 18, false, false));
        priceFeed.setSkipPriceCheck(FlagState.TRUE);

        vm.expectEmit(true, true, false, true);
        emit SetReservePriceFeed(address(token), address(priceFeed), 0, true);

        vm.prank(configurator);
        priceOracle.setReservePriceFeed(address(token), address(priceFeed), 0);

        PriceFeedParams memory params = priceOracle.getReservePriceFeedParams(address(token));
        assertEq(params.priceFeed, address(priceFeed), "Incorrect priceFeed");
        assertEq(params.decimals, 18, "Incorrect decimals");
        assertEq(params.skipCheck, true, "Incorrect skipCheck");
        assertEq(params.stalenessPeriod, 0, "Incorrect stalenessPeriod");
        assertEq(params.useReserve, false, "Incorrect useReserve");
    }

    /// @notice U:[PO-8]: `setReservePriceFeedStatus` works as expected
    function test_U_PO_08_setReservePriceFeedStatus_works_as_expected() public {
        ERC20Mock token = new ERC20Mock("Test Token", "TEST", 18);
        PriceFeedMock priceFeed = new PriceFeedMock(42, 8);

        vm.expectRevert(CallerNotControllerException.selector);
        priceOracle.setReservePriceFeedStatus(address(token), true);

        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        vm.prank(configurator);
        priceOracle.setReservePriceFeedStatus(address(token), true);

        priceOracle.hackPriceFeedParams(
            address(token), PriceFeedParams(makeAddr("MAIN_PRICE_FEED"), 0, false, 18, false, false)
        );
        priceOracle.hackReservePriceFeedParams(
            address(token), PriceFeedParams(address(priceFeed), 0, false, 18, false, false)
        );

        vm.expectEmit(true, false, false, true);
        emit SetReservePriceFeedStatus(address(token), true);

        vm.prank(configurator);
        priceOracle.setReservePriceFeedStatus(address(token), true);

        assertTrue(priceOracle.getPriceFeedParams(address(token)).useReserve, "useReserve is unexpectedly false");
        // make sure all functions now switch to reserve price feed
        assertEq(priceOracle.priceFeeds(address(token)), address(priceFeed), "Incorrect priceFeed");
    }

    // -------------------- //
    // CONVERSION FUNCTIONS //
    // -------------------- //

    /// @notice U:[PO-9]: `convertToUSD` works as expected
    function test_U_PO_09_covnertToUSD_and_convertFromUSD_work_as_expected() public {
        ERC20Mock token = new ERC20Mock("Test Token", "TEST", 6);
        PriceFeedMock priceFeed = new PriceFeedMock(2e8, 8);
        priceOracle.hackPriceFeedParams(address(token), PriceFeedParams(address(priceFeed), 0, false, 6, false, false));

        assertEq(priceOracle.convertToUSD(100e6, address(token)), 200e8, "Incorrect convertToUSD");
        assertEq(priceOracle.convertFromUSD(1000e8, address(token)), 500e6, "Incorrect convertFromUSD");
    }

    /// @notice U:[PO-10]: `convert` works as epxected
    function test_U_PO_10_convert_works_as_expected() public {
        ERC20Mock token1 = new ERC20Mock("Test Token 1", "TEST1", 6);
        PriceFeedMock priceFeed1 = new PriceFeedMock(10e8, 8);
        priceOracle.hackPriceFeedParams(
            address(token1), PriceFeedParams(address(priceFeed1), 0, false, 6, false, false)
        );

        ERC20Mock token2 = new ERC20Mock("Test Token 2", "TEST2", 18);
        PriceFeedMock priceFeed2 = new PriceFeedMock(0.1e8, 8);
        priceOracle.hackPriceFeedParams(
            address(token2), PriceFeedParams(address(priceFeed2), 0, false, 18, false, false)
        );

        assertEq(
            priceOracle.convert(1e6, address(token1), address(token2)), 100e18, "Incorrect token1 -> token2 conversion"
        );

        assertEq(
            priceOracle.convert(100e18, address(token2), address(token1)), 1e6, "Incorrect token2 -> token1 conversion"
        );
    }

    /// @notice U:[PO-11]: Safe conversion works as expected
    function test_U_PO_11_safe_conversion_works_as_expected() public {
        ERC20Mock token = new ERC20Mock("Test Token", "TEST", 6);
        PriceFeedMock mainFeed = new PriceFeedMock(2e8, 8);
        PriceFeedMock reserveFeed = new PriceFeedMock(1.8e8, 8);

        // untrusted feed without reserve feed
        priceOracle.hackPriceFeedParams(address(token), PriceFeedParams(address(mainFeed), 0, false, 6, false, false));
        assertEq(priceOracle.getPriceSafe(address(token)), 0, "getPriceSafe, untrusted feed without reserve feed");
        assertEq(
            priceOracle.safeConvertToUSD(100e6, address(token)),
            0,
            "safeConvertToUSD untrusted feed without reserve feed"
        );

        // untrusted feed with reserve feed
        priceOracle.hackReservePriceFeedParams(
            address(token), PriceFeedParams(address(reserveFeed), 0, false, 6, false, false)
        );
        assertEq(priceOracle.getPriceSafe(address(token)), 1.8e8, "safe price of untrusted feed with reserve feed");
        assertEq(
            priceOracle.safeConvertToUSD(100e6, address(token)),
            180e8,
            "safeConvertToUSD untrusted feed with reserve feed"
        );

        // trusted feed
        priceOracle.hackPriceFeedParams(address(token), PriceFeedParams(address(mainFeed), 0, false, 6, false, true));
        assertEq(priceOracle.getPriceSafe(address(token)), 2e8, "safe price of trusted feed");
        assertEq(priceOracle.safeConvertToUSD(100e6, address(token)), 200e8, "safeConvertToUSD trusted feed");
    }
}
