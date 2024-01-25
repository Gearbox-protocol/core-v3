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
import {PriceFeedMock} from "../../mocks/oracles/PriceFeedMock.sol";
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

    // -------------------- //
    // CONVERSION FUNCTIONS //
    // -------------------- //

    /// @notice U:[PO-1]: `getPrice` works as expected
    function test_U_PO_01_getPrice_works_as_expected() public {
        address token = address(new ERC20Mock("Test Token", "TEST", 18));
        address mainFeed = address(new PriceFeedMock(2e8, 8));
        address reserveFeed = address(new PriceFeedMock(1.8e8, 8));

        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        priceOracle.getPrice(token);
        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        priceOracle.convertToUSD(2e18, token);
        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        priceOracle.convertFromUSD(3.6e8, token);

        vm.prank(configurator);
        priceOracle.setPriceFeed(token, mainFeed, 3600, false);
        assertEq(priceOracle.getPrice(token), 2e8);
        assertEq(priceOracle.convertToUSD(2e18, token), 4e8);
        assertEq(priceOracle.convertFromUSD(3.6e8, token), 1.8e18);

        vm.prank(configurator);
        priceOracle.setReservePriceFeed(token, reserveFeed, 3600, false);
        assertEq(priceOracle.getPrice(token), 2e8);
        assertEq(priceOracle.convertToUSD(2e18, token), 4e8);
        assertEq(priceOracle.convertFromUSD(3.6e8, token), 1.8e18);

        vm.prank(configurator);
        priceOracle.setReservePriceFeedStatus(token, true);
        assertEq(priceOracle.getPrice(token), 1.8e8);
        assertEq(priceOracle.convertToUSD(2e18, token), 3.6e8);
        assertEq(priceOracle.convertFromUSD(3.6e8, token), 2e18);
    }

    /// @notice U:[PO-2]: `getPriceSafe` works as expected
    function test_U_PO_02_getPriceSafe_works_as_expected() public {
        address token = address(new ERC20Mock("Test Token", "TEST", 18));
        address mainFeed = address(new PriceFeedMock(2e8, 8));
        address reserveFeed = address(new PriceFeedMock(1.8e8, 8));

        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        priceOracle.getPriceSafe(token);
        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        priceOracle.safeConvertToUSD(2e18, token);

        vm.prank(configurator);
        priceOracle.setPriceFeed(token, mainFeed, 3600, true);
        assertEq(priceOracle.getPriceSafe(token), 2e8);
        assertEq(priceOracle.safeConvertToUSD(2e18, token), 4e8);

        vm.prank(configurator);
        priceOracle.setPriceFeed(token, mainFeed, 3600, false);
        assertEq(priceOracle.getPriceSafe(token), 0);
        assertEq(priceOracle.safeConvertToUSD(2e18, token), 0);

        vm.prank(configurator);
        priceOracle.setReservePriceFeed(token, reserveFeed, 3600, true);
        assertEq(priceOracle.getPriceSafe(token), 1.8e8);
        assertEq(priceOracle.safeConvertToUSD(2e18, token), 3.6e8);

        vm.prank(configurator);
        priceOracle.setReservePriceFeedStatus(token, true);
        assertEq(priceOracle.getPriceSafe(token), 1.8e8);
        assertEq(priceOracle.safeConvertToUSD(2e18, token), 3.6e8);

        vm.prank(configurator);
        priceOracle.setReservePriceFeed(token, reserveFeed, 3600, false);
        assertEq(priceOracle.getPriceSafe(token), 0);
        assertEq(priceOracle.safeConvertToUSD(2e18, token), 0);
    }

    // ----------------------- //
    // CONFIGURATION FUNCTIONS //
    // ----------------------- //

    /// @notice U:[PO-3]: `setPriceFeed` works as expected
    function test_U_PO_03_setPriceFeed_works_as_expected() public {
        address token = makeAddr("TOKEN");
        address priceFeed = address(new PriceFeedMock(42, 8));

        // revert cases
        vm.expectRevert(ZeroAddressException.selector);
        priceOracle.setPriceFeed(address(0), priceFeed, 0, false);

        vm.expectRevert(ZeroAddressException.selector);
        priceOracle.setPriceFeed(token, address(0), 0, false);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        priceOracle.setPriceFeed(token, priceFeed, 0, false);

        // setting the price feed
        // - must validate token and set decimals
        // - must set active status to true
        vm.mockCall(token, abi.encodeCall(ERC20.decimals, ()), abi.encode(uint8(18)));

        vm.expectCall(token, abi.encodeCall(ERC20.decimals, ()));
        vm.expectCall(priceFeed, abi.encodeCall(IPriceFeed.skipPriceCheck, ()));

        vm.expectEmit(true, true, true, true);
        emit SetPriceFeed(token, priceFeed, 3600, false, true);

        vm.prank(configurator);
        priceOracle.setPriceFeed(token, priceFeed, 3600, true);

        PriceFeedParams memory params = priceOracle.priceFeedParamsRaw(token, false);
        assertEq(params.priceFeed, priceFeed, "Incorrect priceFeed");
        assertEq(params.stalenessPeriod, 3600, "Incorrect stalenessPeriod");
        assertEq(params.skipCheck, false, "Incorrect skipCheck");
        assertEq(params.decimals, 18, "Incorrect decimals");
        assertEq(params.trusted, true, "Incorrect trusted");
        assertTrue(params.active, "active status not set to true when setting a price feed");

        // updating the price feed
        // - must not validate token
        // - must not change active status
        params.active = false;
        priceOracle.hackPriceFeedParams(token, params);
        vm.mockCallRevert(token, abi.encodeCall(ERC20.decimals, ()), "should not be called");

        vm.expectCall(priceFeed, abi.encodeCall(IPriceFeed.skipPriceCheck, ()));

        vm.expectEmit(true, true, true, true);
        emit SetPriceFeed(token, priceFeed, 3600, false, true);

        vm.prank(configurator);
        priceOracle.setPriceFeed(token, priceFeed, 3600, true);

        params = priceOracle.priceFeedParamsRaw(token, false);
        assertEq(params.priceFeed, priceFeed, "Incorrect priceFeed");
        assertEq(params.stalenessPeriod, 3600, "Incorrect stalenessPeriod");
        assertEq(params.skipCheck, false, "Incorrect skipCheck");
        assertEq(params.decimals, 18, "Incorrect decimals");
        assertEq(params.trusted, true, "Incorrect trusted");
        assertFalse(params.active, "active status changed when updating a price feed");
    }

    /// @notice U:[PO-4]: `setReservePriceFeed` works as expected
    function test_U_PO_04_setReservePriceFeed_works_as_expected() public {
        address token = makeAddr("TOKEN");
        address mainFeed = makeAddr("MAIN_FEED");
        address reserveFeed = address(new PriceFeedMock(42, 8));

        // revert cases
        vm.expectRevert(ZeroAddressException.selector);
        priceOracle.setPriceFeed(address(0), reserveFeed, 0, false);

        vm.expectRevert(ZeroAddressException.selector);
        priceOracle.setPriceFeed(token, address(0), 0, false);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        priceOracle.setPriceFeed(token, reserveFeed, 0, false);

        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        vm.prank(configurator);
        priceOracle.setReservePriceFeed(token, reserveFeed, 0, false);

        // setting the reserve price feed
        // - must copy decimals from main feed
        // - must invert main feed active status
        priceOracle.hackPriceFeedParams(token, PriceFeedParams(mainFeed, 0, false, 18, false, false));

        vm.expectCall(reserveFeed, abi.encodeCall(IPriceFeed.skipPriceCheck, ()));

        vm.expectEmit(true, true, true, true);
        emit SetReservePriceFeed(token, reserveFeed, 3600, false, true);

        vm.prank(configurator);
        priceOracle.setReservePriceFeed(token, reserveFeed, 3600, true);

        PriceFeedParams memory params = priceOracle.priceFeedParamsRaw(token, true);
        assertEq(params.priceFeed, reserveFeed, "Incorrect priceFeed");
        assertEq(params.stalenessPeriod, 3600, "Incorrect stalenessPeriod");
        assertEq(params.skipCheck, false, "Incorrect skipCheck");
        assertEq(params.decimals, 18, "Incorrect decimals");
        assertEq(params.trusted, true, "Incorrect trusted");
        assertTrue(params.active, "active status is not negative of main feed active status");
    }

    /// @notice U:[PO-5]: `setReservePriceFeedStatus` works as expected
    function test_U_PO_05_setReservePriceFeedStatus_works_as_expected() public {
        address token = makeAddr("TOKEN");
        address mainFeed = makeAddr("MAIN_FEED");
        address reserveFeed = makeAddr("RESERVE_FEED");

        vm.expectRevert(CallerNotControllerException.selector);
        priceOracle.setReservePriceFeedStatus(token, true);

        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        vm.prank(configurator);
        priceOracle.setReservePriceFeedStatus(token, true);

        priceOracle.hackPriceFeedParams(token, PriceFeedParams(mainFeed, 0, false, 18, false, true));
        priceOracle.hackReservePriceFeedParams(token, PriceFeedParams(reserveFeed, 0, false, 18, false, false));

        // activating reserve feed
        vm.expectEmit(true, true, true, true);
        emit SetReservePriceFeedStatus(token, true);

        vm.prank(configurator);
        priceOracle.setReservePriceFeedStatus(token, true);

        assertFalse(priceOracle.priceFeedParamsRaw(token, false).active, "Main feed is unexpectedly active");
        assertTrue(priceOracle.priceFeedParamsRaw(token, true).active, "Reserve feed is unexpectedly inactive");
        assertEq(priceOracle.priceFeeds(token), reserveFeed, "Incorrect priceFeeds");

        // activating main feed
        vm.expectEmit(true, true, true, true);
        emit SetReservePriceFeedStatus(token, false);

        vm.prank(configurator);
        priceOracle.setReservePriceFeedStatus(token, false);

        assertTrue(priceOracle.priceFeedParamsRaw(token, false).active, "Main feed is unexpectedly inactive");
        assertFalse(priceOracle.priceFeedParamsRaw(token, true).active, "Reserve feed is unexpectedly active");
        assertEq(priceOracle.priceFeeds(token), mainFeed, "Incorrect priceFeeds");
    }

    // ------------------ //
    // INTERNAL FUNCTIONS //
    // ------------------ //

    /// @notice U:[PO-6]: `_getTokenReserveKey` works as expected
    function test_U_PO_06_getTokenReserveKey_works_as_expected(address token) public {
        address expectedKey = address(uint160(uint256(keccak256(abi.encodePacked("RESERVE", token)))));
        assertEq(priceOracle.exposed_getTokenReserveKey(token), expectedKey);
    }

    /// @notice U:[PO-7]: `_validateToken` works as expected
    function test_U_PO_07_validateToken_works_as_expected() public {
        address token = makeAddr("TOKEN");

        vm.etch(token, "");
        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, token));
        priceOracle.exposed_validateToken(token);

        vm.etch(token, "CODE");

        vm.mockCallRevert(token, abi.encodeCall(ERC20.decimals, ()), "");
        vm.expectRevert(IncorrectTokenContractException.selector);
        priceOracle.exposed_validateToken(token);

        vm.mockCall(token, abi.encodeCall(ERC20.decimals, ()), abi.encode(uint8(0)));
        vm.expectRevert(IncorrectTokenContractException.selector);
        priceOracle.exposed_validateToken(token);

        vm.mockCall(token, abi.encodeCall(ERC20.decimals, ()), abi.encode(uint8(19)));
        vm.expectRevert(IncorrectTokenContractException.selector);
        priceOracle.exposed_validateToken(token);

        vm.mockCall(token, abi.encodeCall(ERC20.decimals, ()), abi.encode(uint8(6)));
        uint8 decimals = priceOracle.exposed_validateToken(token);
        assertEq(decimals, 6, "Incorrect decimals");
    }

    /// @notice U:[PO-8]: `_validatePriceFeed` works as expected
    function test_U_PO_08_validatePriceFeed_works_as_expected() public {
        address priceFeed = makeAddr("PRICE_FEED");

        // not a contract
        vm.etch(priceFeed, "");
        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, priceFeed));
        priceOracle.exposed_validatePriceFeed(priceFeed, 0);

        vm.etch(priceFeed, "CODE");

        // does not implement `decimals()`
        vm.mockCallRevert(priceFeed, abi.encodeCall(IPriceFeed.decimals, ()), "");
        vm.expectRevert(IncorrectPriceFeedException.selector);
        priceOracle.exposed_validatePriceFeed(priceFeed, 0);

        // wrong decimals
        vm.mockCall(priceFeed, abi.encodeCall(IPriceFeed.decimals, ()), abi.encode(uint8(6)));
        vm.expectRevert(IncorrectPriceFeedException.selector);
        priceOracle.exposed_validatePriceFeed(priceFeed, 0);

        vm.mockCall(priceFeed, abi.encodeCall(IPriceFeed.decimals, ()), abi.encode(uint8(8)));

        // does not implement `latestRoundData()`
        vm.mockCallRevert(priceFeed, abi.encodeCall(IPriceFeed.latestRoundData, ()), "");
        vm.expectRevert(IncorrectPriceFeedException.selector);
        priceOracle.exposed_validatePriceFeed(priceFeed, 0);

        // zero staleness period while shipCheck = false
        vm.mockCall(
            priceFeed,
            abi.encodeCall(IPriceFeed.latestRoundData, ()),
            abi.encode(uint80(0), int256(42), uint256(0), block.timestamp, uint80(0))
        );
        vm.expectRevert(IncorrectParameterException.selector);
        priceOracle.exposed_validatePriceFeed(priceFeed, 0);

        // negative price
        vm.mockCall(
            priceFeed,
            abi.encodeCall(IPriceFeed.latestRoundData, ()),
            abi.encode(uint80(0), int256(-1), uint256(0), block.timestamp, uint80(0))
        );
        vm.expectRevert(IncorrectPriceException.selector);
        priceOracle.exposed_validatePriceFeed(priceFeed, 3600);

        // stale price
        vm.mockCall(
            priceFeed,
            abi.encodeCall(IPriceFeed.latestRoundData, ()),
            abi.encode(uint80(0), int256(42), uint256(0), block.timestamp - 7200, uint80(0))
        );
        vm.expectRevert(StalePriceException.selector);
        priceOracle.exposed_validatePriceFeed(priceFeed, 3600);

        // staleness check is skipped for updatable feed
        vm.mockCall(priceFeed, abi.encodeCall(IUpdatablePriceFeed.updatable, ()), abi.encode(true));
        bool skipCheck = priceOracle.exposed_validatePriceFeed(priceFeed, 3600);
        assertFalse(skipCheck, "skipCheck is unexpectedly true");

        // non-zero staleness period while skipCheck = true
        vm.mockCall(priceFeed, abi.encodeCall(IPriceFeed.skipPriceCheck, ()), abi.encode(true));
        vm.expectRevert(IncorrectParameterException.selector);
        priceOracle.exposed_validatePriceFeed(priceFeed, 3600);

        skipCheck = priceOracle.exposed_validatePriceFeed(priceFeed, 0);
        assertTrue(skipCheck, "skipCheck is unexpectedly false");
    }

    /// @notice U:[PO-9]: `_getValidatedPrice` works as expected
    function test_U_PO_09_getValidatedPrice_works_as_expected() public {
        address priceFeed = makeAddr("PRICE_FEED");
        uint256 stalenessPeriod = 20;

        // returns answer if `skipCheck` is true
        vm.mockCall(
            priceFeed,
            abi.encodeCall(IPriceFeed.latestRoundData, ()),
            abi.encode(uint80(0), -123, uint256(0), block.timestamp - stalenessPeriod - 1, uint80(0))
        );
        vm.expectCall(priceFeed, abi.encodeCall(IPriceFeed.latestRoundData, ()));
        assertEq(priceOracle.exposed_getValidatedPrice(priceFeed, 20, true), -123, "Incorrect price");

        // reverts on negative price if `skipCheck` is false
        vm.mockCall(
            priceFeed,
            abi.encodeCall(IPriceFeed.latestRoundData, ()),
            abi.encode(uint80(0), -123, uint256(0), block.timestamp - stalenessPeriod + 1, uint80(0))
        );
        vm.expectCall(priceFeed, abi.encodeCall(IPriceFeed.latestRoundData, ()));
        vm.expectRevert(IncorrectPriceException.selector);
        priceOracle.exposed_getValidatedPrice(priceFeed, 20, false);

        // reverts on stale price if `skipCheck` is false
        vm.mockCall(
            priceFeed,
            abi.encodeCall(IPriceFeed.latestRoundData, ()),
            abi.encode(uint80(0), 123, uint256(0), block.timestamp - stalenessPeriod - 1, uint80(0))
        );
        vm.expectCall(priceFeed, abi.encodeCall(IPriceFeed.latestRoundData, ()));
        vm.expectRevert(StalePriceException.selector);
        priceOracle.exposed_getValidatedPrice(priceFeed, 20, false);

        // returns answer if `skipCheck` is false
        vm.mockCall(
            priceFeed,
            abi.encodeCall(IPriceFeed.latestRoundData, ()),
            abi.encode(uint80(0), 123, uint256(0), block.timestamp - stalenessPeriod + 1, uint80(0))
        );
        vm.expectCall(priceFeed, abi.encodeCall(IPriceFeed.latestRoundData, ()));
        assertEq(priceOracle.exposed_getValidatedPrice(priceFeed, 20, false), 123, "Incorrect price");
    }
}
