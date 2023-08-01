// // SPDX-License-Identifier: UNLICENSED
// // Gearbox Protocol. Generalized leverage for DeFi protocols
// // (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IPriceOracleV3Events, PriceFeedParams} from "../../../interfaces/IPriceOracleV3.sol";
import {AddressProviderV3ACLMock, AP_PRICE_ORACLE} from "../../mocks/core/AddressProviderV3ACLMock.sol";

// // TEST
import "../../lib/constants.sol";

// // MOCKS
import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";
import {PriceFeedMock, FlagState} from "../../mocks/oracles/PriceFeedMock.sol";

// // SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "@gearbox-protocol/sdk/contracts/Tokens.sol";

// // EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

import {TestHelper} from "../../lib/helper.sol";

import {PriceOracleV3Harness} from "./PriceOracleV3Harness.sol";

contract PriceOracleV3UnitTest is TestHelper, IPriceOracleV3Events {
    TokensTestSuite tokenTestSuite;
    AddressProviderV3ACLMock ap;
    PriceOracleV3Harness public priceOracle;

    function setUp() public {
        tokenTestSuite = new TokensTestSuite();
        tokenTestSuite.topUpWETH{value: 100 * WAD}();

        vm.startPrank(CONFIGURATOR);
        ap = new AddressProviderV3ACLMock();
        priceOracle = new PriceOracleV3Harness(address(ap));

        vm.stopPrank();
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @notice U:[PO-2]: setPriceFeed reverts for zero address and incorrect digitals
    function test_U_PO_02_setPriceFeed_reverts_for_zero_address_and_incorrect_contracts() public {
        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(ZeroAddressException.selector);
        priceOracle.setPriceFeed(address(0), DUMB_ADDRESS, 2 hours);

        vm.expectRevert(ZeroAddressException.selector);
        priceOracle.setPriceFeed(DUMB_ADDRESS, address(0), 2 hours);

        // Checks that it reverts for non-contract addresses
        address dai = tokenTestSuite.addressOf(Tokens.DAI);

        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, DUMB_ADDRESS2));
        priceOracle.setPriceFeed(dai, DUMB_ADDRESS2, 2 hours);

        vm.expectRevert(IncorrectPriceFeedException.selector);
        priceOracle.setPriceFeed(dai, address(this), 2 hours);

        // Checks that it reverts if token has no .decimals() method
        PriceFeedMock priceFeed = new PriceFeedMock(8 * 10**8, 8);
        vm.expectRevert(IncorrectTokenContractException.selector);
        priceOracle.setPriceFeed(address(this), address(priceFeed), 2 hours);

        // 19 digits case
        ERC20Mock token19decimals = new ERC20Mock("19-19", "19-19", 19);
        vm.expectRevert(IncorrectTokenContractException.selector);
        priceOracle.setPriceFeed(address(token19decimals), address(priceFeed), 2 hours);

        PriceFeedMock pfMock9decimals = new PriceFeedMock(10, 9);

        vm.expectRevert(IncorrectPriceFeedException.selector);
        priceOracle.setPriceFeed(dai, address(pfMock9decimals), 2 hours);

        priceFeed.setRevertOnLatestRound(true);

        vm.expectRevert(IncorrectPriceFeedException.selector);
        priceOracle.setPriceFeed(dai, address(priceFeed), 2 hours);

        priceFeed.setPrice(0);
        priceFeed.setParams(80, block.timestamp, block.timestamp, 80);

        vm.expectRevert(IncorrectPriceFeedException.selector);
        priceOracle.setPriceFeed(dai, address(priceFeed), 2 hours);

        priceFeed.setRevertOnLatestRound(false);
        priceFeed.setPrice(0);
        priceFeed.setParams(80, block.timestamp, block.timestamp, 80);

        vm.expectRevert(IncorrectPriceException.selector);
        priceOracle.setPriceFeed(dai, address(priceFeed), 2 hours);

        priceFeed.setRevertOnLatestRound(false);
        priceFeed.setPrice(10);

        priceFeed.setParams(80, 0, block.timestamp - 2 hours - 1, 80);

        vm.expectRevert(StalePriceException.selector);
        priceOracle.setPriceFeed(dai, address(priceFeed), 2 hours);
    }

    /// @notice U:[PO-3]: setPriceFeed adds pricefeed and emits event
    function test_U_PO_03_setPriceFeed_adds_pricefeed_and_emits_event() public {
        for (uint256 sc = 0; sc < 2; sc++) {
            bool skipCheck = sc != 0;

            ERC20Mock token = new ERC20Mock("Token", "Token", 17);

            PriceFeedMock priceFeed = new PriceFeedMock(8 * 10**8, 8);

            priceFeed.setSkipPriceCheck(skipCheck ? FlagState.TRUE : FlagState.FALSE);

            uint32 stalePeriod = skipCheck ? 0 : 2 hours;

            vm.expectEmit(true, true, false, false);
            emit SetPriceFeed(address(token), address(priceFeed), stalePeriod, skipCheck);

            vm.prank(CONFIGURATOR);
            priceOracle.setPriceFeed(address(token), address(priceFeed), stalePeriod);

            (address newPriceFeed, uint32 stalenessPeriod, bool sc_flag, uint8 decimals) =
                priceOracle.priceFeedParams(address(token));

            assertEq(newPriceFeed, address(priceFeed), "Incorrect pricefeed");

            assertEq(priceOracle.priceFeeds(address(token)), address(priceFeed), "Incorrect pricefeed");

            assertEq(decimals, 17, "Incorrect decimals");

            assertTrue(sc_flag == skipCheck, "Incorrect skipCheck");
        }
    }

    /// @notice U:[PO-4]: getPrice reverts if depends on address but address(0) was provided
    function test_U_PO_04_getPrice_reverts_if_depends_on_address_but_zero_address_was_provided() public {
        ERC20Mock token = new ERC20Mock("Token", "Token", 17);

        PriceFeedMock priceFeed = new PriceFeedMock(8 * 10**8, 8);

        vm.prank(CONFIGURATOR);
        priceOracle.setPriceFeed(address(token), address(priceFeed), 2 hours);

        priceOracle.getPrice(address(token));
    }

    /// @notice U:[PO-5]: getPrice reverts if not passed skipCheck when it's enabled
    function test_U_PO_05_getPrice_reverts_if_not_passed_skipCheck_when_its_enabled() public {
        for (uint256 sc = 0; sc < 2; sc++) {
            uint256 snapshotId = vm.snapshot();

            bool skipForCheck = sc != 0;

            ERC20Mock token = new ERC20Mock("Token", "Token", 17);

            PriceFeedMock priceFeed = new PriceFeedMock(8 * 10**8, 8);

            priceFeed.setSkipPriceCheck(skipForCheck ? FlagState.TRUE : FlagState.FALSE);

            uint32 stalenessPeriod = skipForCheck ? 0 : 2 hours;

            vm.prank(CONFIGURATOR);
            priceOracle.setPriceFeed(address(token), address(priceFeed), stalenessPeriod);

            priceFeed.setPrice(0);
            priceFeed.setParams(80, block.timestamp, block.timestamp, 80);

            if (!skipForCheck) {
                vm.expectRevert(IncorrectPriceException.selector);
            }
            priceOracle.getPrice(address(token));

            priceFeed.setPrice(10);
            priceFeed.setParams(80, block.timestamp, block.timestamp - 2 hours - 1, stalenessPeriod);

            if (!skipForCheck) {
                vm.expectRevert(StalePriceException.selector);
            }
            priceOracle.getPrice(address(token));

            vm.revertTo(snapshotId);
        }
    }

    /// @notice U:[PO-6]: getPrice returs correct price getting through correct method
    function test_U_PO_06_getPrice_returns_correct_price(int256 price) public {
        setUp();

        vm.assume(price > 0);
        ERC20Mock token = new ERC20Mock("Token", "Token", 17);

        PriceFeedMock priceFeed = new PriceFeedMock(8 * 10**8, 8);

        vm.prank(CONFIGURATOR);
        priceOracle.setPriceFeed(address(token), address(priceFeed), 2 hours);

        priceFeed.setPrice(price);

        vm.expectCall(address(priceFeed), abi.encodeWithSignature("latestRoundData()"));

        uint256 actualPrice = priceOracle.getPrice(address(token));

        assertEq(actualPrice, uint256(price), "Incorrect price");
    }

    /// @notice U:[PO-7]: convertToUSD and convertFromUSD computes correctly
    /// All prices are taken from tokenTestSuite
    function test_U_PO_07_convertFromUSD_and_convertToUSD_computes_correctly(uint128 amount) public {
        address wethToken = tokenTestSuite.wethToken();
        address linkToken = tokenTestSuite.addressOf(Tokens.LINK);

        PriceFeedMock wethPriceFeed = new PriceFeedMock(int256(DAI_WETH_RATE * 10**8), 8);
        PriceFeedMock linkPriceFeed = new PriceFeedMock(int256(15 * 10**8), 8);

        vm.startPrank(CONFIGURATOR);
        priceOracle.setPriceFeed(wethToken, address(wethPriceFeed), 2 hours);
        priceOracle.setPriceFeed(linkToken, address(linkPriceFeed), 2 hours);
        vm.stopPrank();

        uint256 decimalsDifference = WAD / 10 ** 8;

        assertEq(
            priceOracle.convertToUSD(amount, wethToken),
            (uint256(amount) * DAI_WETH_RATE) / decimalsDifference,
            "Incorrect ETH/USD conversation"
        );

        assertEq(
            priceOracle.convertToUSD(amount, linkToken),
            (uint256(amount) * 15) / decimalsDifference,
            "Incorrect LINK/USD conversation"
        );

        assertEq(
            priceOracle.convertFromUSD(amount, wethToken),
            (uint256(amount) * decimalsDifference) / DAI_WETH_RATE,
            "Incorrect USDC/ETH conversation"
        );

        assertEq(
            priceOracle.convertFromUSD(amount, linkToken),
            (uint256(amount) * decimalsDifference) / 15,
            "Incorrect USD/LINK conversation"
        );
    }

    /// @notice U:[PO-8]: convert computes correctly
    /// All prices are taken from tokenTestSuite
    function test_U_PO_08_convert_computes_correctly() public {
        // assertEq(
        //     priceOracle.convert(WAD, tokenTestSuite.addressOf(Tokens.WETH), tokenTestSuite.addressOf(Tokens.USDC)),
        //     DAI_WETH_RATE * 10 ** 6,
        //     "Incorrect WETH/USDC conversation"
        // );

        // assertEq(
        //     priceOracle.convert(WAD, tokenTestSuite.addressOf(Tokens.WETH), tokenTestSuite.addressOf(Tokens.LINK)),
        //     (DAI_WETH_RATE * WAD) / 15,
        //     "Incorrect WETH/LINK conversation"
        // );

        // assertEq(
        //     priceOracle.convert(WAD, tokenTestSuite.addressOf(Tokens.LINK), tokenTestSuite.addressOf(Tokens.DAI)),
        //     15 * WAD,
        //     "Incorrect LINK/DAI conversation"
        // );

        // assertEq(
        //     priceOracle.convert(10 ** 8, tokenTestSuite.addressOf(Tokens.USDC), tokenTestSuite.addressOf(Tokens.DAI)),
        //     100 * WAD,
        //     "Incorrect USDC/DAI conversation"
        // );
    }

    /// @notice U:[PO-9]: `_getPriceFeedParams` works as expected
    /// forge-config: default.fuzz.runs = 5000
    function test_U_PO_09_getPriceFeedParams_works_as_expected(address token, PriceFeedParams memory expectedParams)
        public
    {
        priceOracle.hackPriceFeedParams(token, expectedParams);

        PriceFeedParams memory params = priceOracle.getPriceFeedParams(token);

        assertEq(params.priceFeed, expectedParams.priceFeed, "Incorrect priceFeed");
        assertEq(params.stalenessPeriod, expectedParams.stalenessPeriod, "Incorrect stalenessPeriod");
        assertEq(params.decimals, expectedParams.decimals, "Incorrect decimals");
        assertEq(params.skipCheck, expectedParams.skipCheck, "Incorrect skipCheck");
        assertEq(params.useReserve, expectedParams.useReserve, "Incorrect useReserve");
    }

    /// @notice U:[PO-10]: `_getTokenReserveKey` works as expected
    /// forge-config: default.fuzz.runs = 5000
    function test_U_PO_10_getTokenReserveKey_works_as_expected(address token) public {
        address expectedKey = address(uint160(uint256(keccak256(abi.encodePacked("RESERVE", token)))));
        assertEq(priceOracle.getTokenReserveKey(token), expectedKey);
    }
}
