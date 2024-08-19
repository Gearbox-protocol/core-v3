// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../../interfaces/IExceptions.sol";
import {IPriceOracleV3Events, PriceFeedParams, PriceUpdate} from "../../../interfaces/IPriceOracleV3.sol";
import {IPriceFeed, IUpdatablePriceFeed} from "../../../interfaces/base/IPriceFeed.sol";

import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";
import {PriceFeedMock} from "../../mocks/oracles/PriceFeedMock.sol";
import {UpdatablePriceFeedMock} from "../../mocks/oracles/UpdatablePriceFeedMock.sol";
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

        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        priceOracle.getPrice(token);
        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        priceOracle.convertToUSD(2e18, token);
        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        priceOracle.convertFromUSD(3.6e8, token);

        vm.prank(configurator);
        priceOracle.setPriceFeed(token, mainFeed, 3600);
        assertEq(priceOracle.getPrice(token), 2e8);
        assertEq(priceOracle.convertToUSD(2e18, token), 4e8);
        assertEq(priceOracle.convertFromUSD(3.6e8, token), 1.8e18);
    }

    /// @notice U:[PO-2]: `getSafePrice` and `getReservePrice` work as expected
    function test_U_PO_02_getSafePrice_and_getReservePrice_work_as_expected() public {
        address token = address(new ERC20Mock("Test Token", "TEST", 18));
        address mainFeed = address(new PriceFeedMock(2e8, 8));
        address reserveFeed = address(new PriceFeedMock(1.8e8, 8));

        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        priceOracle.getSafePrice(token);
        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        priceOracle.getReservePrice(token);
        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        priceOracle.safeConvertToUSD(2e18, token);

        // no reserve price feed => safe price = 0
        vm.prank(configurator);
        priceOracle.setPriceFeed(token, mainFeed, 3600);
        assertEq(priceOracle.getSafePrice(token), 0);
        assertEq(priceOracle.safeConvertToUSD(2e18, token), 0);
        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        priceOracle.getReservePrice(token);

        // safe price = min(main price, reserve price)
        vm.prank(configurator);
        priceOracle.setReservePriceFeed(token, reserveFeed, 3600);
        assertEq(priceOracle.getSafePrice(token), 1.8e8);
        assertEq(priceOracle.safeConvertToUSD(2e18, token), 3.6e8);
        assertEq(priceOracle.getReservePrice(token), 1.8e8);

        // trusted main price feed => safe price = main price
        vm.prank(configurator);
        priceOracle.setReservePriceFeed(token, mainFeed, 3600);
        assertEq(priceOracle.getSafePrice(token), 2e8);
        assertEq(priceOracle.safeConvertToUSD(2e18, token), 4e8);
        assertEq(priceOracle.getReservePrice(token), 2e8);

        // unset reserve price feed => safe price = 0
        vm.prank(configurator);
        priceOracle.setPriceFeed(token, mainFeed, 3600);
        assertEq(priceOracle.getSafePrice(token), 0);
        assertEq(priceOracle.safeConvertToUSD(2e18, token), 0);
        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        priceOracle.getReservePrice(token);
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
        priceOracle.setPriceFeed(address(0), priceFeed, 0);

        vm.expectRevert(ZeroAddressException.selector);
        priceOracle.setPriceFeed(token, address(0), 0);

        vm.expectRevert(CallerNotControllerOrConfiguratorException.selector);
        priceOracle.setPriceFeed(token, priceFeed, 0);

        // setting the price feed
        // - must validate token and set decimals
        // - must add token to the set
        vm.mockCall(token, abi.encodeCall(ERC20.decimals, ()), abi.encode(uint8(18)));

        vm.expectCall(token, abi.encodeCall(ERC20.decimals, ()));
        vm.expectCall(priceFeed, abi.encodeCall(IPriceFeed.skipPriceCheck, ()));

        vm.expectEmit(true, true, true, true);
        emit SetPriceFeed(token, priceFeed, 3600, false);

        vm.prank(configurator);
        priceOracle.setPriceFeed(token, priceFeed, 3600);

        PriceFeedParams memory params = priceOracle.priceFeedParams(token);
        assertEq(params.priceFeed, priceFeed, "Incorrect priceFeed");
        assertEq(params.stalenessPeriod, 3600, "Incorrect stalenessPeriod");
        assertEq(params.skipCheck, false, "Incorrect skipCheck");
        assertEq(params.tokenDecimals, 18, "Incorrect decimals");

        address[] memory tokens = priceOracle.getTokens();
        assertEq(tokens.length, 1, "Incorrect number of tokens");
        assertEq(tokens[0], token, "Incorrect token");

        // updating the price feed
        // - must not validate token for the second time
        // - must unset reserve feed if it is equal to the new main feed
        vm.mockCallRevert(token, abi.encodeCall(ERC20.decimals, ()), "should not be called");
        priceOracle.hackReservePriceFeedParams(token, params);

        vm.expectCall(priceFeed, abi.encodeCall(IPriceFeed.skipPriceCheck, ()));

        vm.expectEmit(true, true, true, true);
        emit SetPriceFeed(token, priceFeed, 3600, false);

        vm.expectEmit(true, true, true, true);
        emit SetReservePriceFeed(token, address(0), 0, false);

        vm.prank(configurator);
        priceOracle.setPriceFeed(token, priceFeed, 3600);

        params = priceOracle.priceFeedParams(token);
        assertEq(params.priceFeed, priceFeed, "Incorrect priceFeed");
        assertEq(params.stalenessPeriod, 3600, "Incorrect stalenessPeriod");
        assertEq(params.skipCheck, false, "Incorrect skipCheck");
        assertEq(params.tokenDecimals, 18, "Incorrect decimals");

        PriceFeedParams memory reserveParams = priceOracle.reservePriceFeedParams(token);
        assertEq(reserveParams.priceFeed, address(0), "Reserve priceFeed not unset");
        assertEq(reserveParams.stalenessPeriod, 0, "Reserve stalenessPeriod not unset");
        assertEq(reserveParams.skipCheck, false, "Reserve skipCheck not unset");
        assertEq(reserveParams.tokenDecimals, 0, "Reserve decimals not unset");
    }

    /// @notice U:[PO-4]: `setReservePriceFeed` works as expected
    function test_U_PO_04_setReservePriceFeed_works_as_expected() public {
        address token = makeAddr("TOKEN");
        address mainFeed = makeAddr("MAIN_FEED");
        address reserveFeed = address(new PriceFeedMock(42, 8));

        // revert cases
        vm.expectRevert(ZeroAddressException.selector);
        priceOracle.setReservePriceFeed(address(0), reserveFeed, 0);

        vm.expectRevert(ZeroAddressException.selector);
        priceOracle.setReservePriceFeed(token, address(0), 0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        priceOracle.setReservePriceFeed(token, reserveFeed, 0);

        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        vm.prank(configurator);
        priceOracle.setReservePriceFeed(token, reserveFeed, 0);

        // setting the reserve price feed
        // - must copy decimals from main feed
        // - must invert main feed active status
        priceOracle.hackPriceFeedParams(token, PriceFeedParams(mainFeed, 0, false, 18));

        vm.expectCall(reserveFeed, abi.encodeCall(IPriceFeed.skipPriceCheck, ()));

        vm.expectEmit(true, true, true, true);
        emit SetReservePriceFeed(token, reserveFeed, 3600, false);

        vm.prank(configurator);
        priceOracle.setReservePriceFeed(token, reserveFeed, 3600);

        PriceFeedParams memory params = priceOracle.reservePriceFeedParams(token);
        assertEq(params.priceFeed, reserveFeed, "Incorrect priceFeed");
        assertEq(params.stalenessPeriod, 3600, "Incorrect stalenessPeriod");
        assertEq(params.skipCheck, false, "Incorrect skipCheck");
        assertEq(params.tokenDecimals, 18, "Incorrect decimals");
    }

    /// @notice U:[PO-5]: `addUpdatablePriceFeed` works as expected
    function test_U_PO_05_addUpdatablePriceFeed_works_as_expected() public {
        UpdatablePriceFeedMock priceFeed = new UpdatablePriceFeedMock();
        priceFeed.setUpdatable(UpdatablePriceFeedMock.FlagState.REVERT);
        PriceUpdate[] memory updates = new PriceUpdate[](1);
        updates[0] = PriceUpdate(address(priceFeed), "DUMMY DATA");

        // revert cases
        vm.expectRevert(ZeroAddressException.selector);
        priceOracle.addUpdatablePriceFeed(address(0));

        vm.expectRevert(CallerNotConfiguratorException.selector);
        priceOracle.addUpdatablePriceFeed(address(priceFeed));

        vm.expectRevert(PriceFeedIsNotUpdatableException.selector);
        vm.prank(configurator);
        priceOracle.addUpdatablePriceFeed(address(priceFeed));

        vm.expectRevert(PriceFeedIsNotUpdatableException.selector);
        priceOracle.updatePrices(updates);

        // adding price feed
        priceFeed.setUpdatable(UpdatablePriceFeedMock.FlagState.TRUE);

        vm.expectEmit(true, true, true, true);
        emit AddUpdatablePriceFeed(address(priceFeed));

        vm.prank(configurator);
        priceOracle.addUpdatablePriceFeed(address(priceFeed));

        address[] memory feeds = priceOracle.getUpdatablePriceFeeds();
        assertEq(feeds.length, 1, "Price feed not added to the set");
        assertEq(feeds[0], address(priceFeed), "Wrong price feed added to the set");

        //  updating price feed
        vm.expectCall(address(priceFeed), abi.encodeCall(priceFeed.updatePrice, ("DUMMY DATA")));
        priceOracle.updatePrices(updates);
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

        // non-zero staleness period while skipCheck = true
        vm.mockCall(priceFeed, abi.encodeCall(IPriceFeed.skipPriceCheck, ()), abi.encode(true));
        vm.expectRevert(IncorrectParameterException.selector);
        priceOracle.exposed_validatePriceFeed(priceFeed, 3600);

        bool skipCheck = priceOracle.exposed_validatePriceFeed(priceFeed, 0);
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
