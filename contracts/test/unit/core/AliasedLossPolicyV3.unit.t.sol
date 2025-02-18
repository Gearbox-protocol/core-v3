// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ILossPolicy} from "../../../interfaces/base/ILossPolicy.sol";
import {IPriceFeedStore, PriceUpdate} from "../../../interfaces/base/IPriceFeedStore.sol";
import {IPriceOracleV3} from "../../../interfaces/IPriceOracleV3.sol";
import {IAliasedLossPolicyV3Events} from "../../../interfaces/IAliasedLossPolicyV3.sol";
import {PriceFeedParams} from "../../../interfaces/IPriceOracleV3.sol";
import {ICreditManagerV3} from "../../../interfaces/ICreditManagerV3.sol";
import {ICreditAccountV3} from "../../../interfaces/ICreditAccountV3.sol";
import {IPoolQuotaKeeperV3} from "../../../interfaces/IPoolQuotaKeeperV3.sol";
import {TokenIsNotQuotedException, CallerNotConfiguratorException} from "../../../interfaces/IExceptions.sol";

import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";
import {PoolMock} from "../../mocks/pool/PoolMock.sol";
import {PoolQuotaKeeperMock} from "../../mocks/pool/PoolQuotaKeeperMock.sol";
import {PriceFeedMock} from "../../mocks/oracles/PriceFeedMock.sol";
import {PriceFeedStoreMock} from "../../mocks/oracles/PriceFeedStoreMock.sol";
import {PriceOracleMock} from "../../mocks/oracles/PriceOracleMock.sol";
import {
    AddressProviderV3ACLMock,
    AP_PRICE_FEED_STORE,
    NO_VERSION_CONTROL
} from "../../mocks/core/AddressProviderV3ACLMock.sol";

import {AliasedLossPolicyV3} from "../../../core/AliasedLossPolicyV3.sol";
import {AliasedLossPolicyV3Harness} from "./AliasedLossPolicyV3Harness.sol";

/// @title Aliased Loss Policy V3 unit test
/// @notice U:[ALP]: Unit tests for aliased loss policy
contract AliasedLossPolicyV3UnitTest is Test, IAliasedLossPolicyV3Events {
    event SetAccessMode(ILossPolicy.AccessMode mode);
    event SetChecksEnabled(bool enabled);

    AliasedLossPolicyV3Harness lossPolicy;

    address configurator;
    address caller;

    ERC20Mock underlying;
    ERC20Mock token;
    PriceFeedMock priceFeed;

    AddressProviderV3ACLMock addressProviderMock;
    PriceFeedStoreMock priceFeedStoreMock;
    PoolMock poolMock;
    PoolQuotaKeeperMock poolQuotaKeeperMock;
    PriceOracleMock priceOracleMock;

    address creditAccount;
    address creditManager;

    function setUp() public {
        configurator = makeAddr("CONFIGURATOR");
        caller = makeAddr("CALLER");

        underlying = new ERC20Mock("Test Underlying", "TEST_UNDERLYING", 18);
        token = new ERC20Mock("Test Token", "TEST", 18);
        priceFeed = new PriceFeedMock(1e8, 8);

        vm.prank(configurator);
        addressProviderMock = new AddressProviderV3ACLMock();
        priceFeedStoreMock =
            PriceFeedStoreMock(addressProviderMock.getAddressOrRevert(AP_PRICE_FEED_STORE, NO_VERSION_CONTROL));

        poolMock = new PoolMock(address(addressProviderMock), address(underlying));
        poolQuotaKeeperMock = new PoolQuotaKeeperMock(address(poolMock), address(underlying));
        poolMock.setPoolQuotaKeeper(address(poolQuotaKeeperMock));

        priceOracleMock = new PriceOracleMock();
        priceOracleMock.setPrice(address(underlying), 10e8);
        priceOracleMock.setPrice(address(token), 0.9e8);

        lossPolicy = new AliasedLossPolicyV3Harness(address(poolMock), address(addressProviderMock));

        creditAccount = makeAddr("CREDIT_ACCOUNT");
        creditManager = makeAddr("CREDIT_MANAGER");
        vm.mockCall(creditAccount, abi.encodeCall(ICreditAccountV3.creditManager, ()), abi.encode(creditManager));
        vm.mockCall(creditManager, abi.encodeCall(ICreditManagerV3.enabledTokensMaskOf, (creditAccount)), abi.encode(1));
        vm.mockCall(creditManager, abi.encodeCall(ICreditManagerV3.priceOracle, ()), abi.encode(priceOracleMock));
    }

    /// @notice U:[ALP-1]: Constructor works correctly
    function test_U_ALP_01_constructor_works_correctly() public view {
        assertEq(lossPolicy.pool(), address(poolMock), "Incorrect pool");
        assertEq(lossPolicy.underlying(), address(underlying), "Incorrect underlying");
        assertEq(lossPolicy.priceFeedStore(), address(priceFeedStoreMock), "Incorrect priceFeedStore");
        assertEq(
            uint256(lossPolicy.accessMode()), uint256(ILossPolicy.AccessMode.Permissionless), "Incorrect initial mode"
        );
        assertTrue(lossPolicy.checksEnabled(), "Checks should be enabled initially");

        // Check serialization
        (ILossPolicy.AccessMode mode, bool checks, address[] memory tokens, PriceFeedParams[] memory params) =
            abi.decode(lossPolicy.serialize(), (ILossPolicy.AccessMode, bool, address[], PriceFeedParams[]));
        assertEq(uint256(mode), uint256(ILossPolicy.AccessMode.Permissionless), "Incorrect serialized mode");
        assertTrue(checks, "Incorrect serialized checks");
        assertEq(tokens.length, 0, "Incorrect serialized tokens length");
        assertEq(params.length, 0, "Incorrect serialized params length");
    }

    /// @notice U:[ALP-2]: `setAccessMode` and `setChecksEnabled` work correctly
    function test_U_ALP_02_setAccessMode_and_setChecksEnabled_work_correctly() public {
        // reverts on non-configurator
        vm.expectRevert(CallerNotConfiguratorException.selector);
        lossPolicy.setAccessMode(ILossPolicy.AccessMode.Forbidden);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        lossPolicy.setChecksEnabled(false);

        // setAccessMode works
        vm.expectEmit(true, true, true, true);
        emit SetAccessMode(ILossPolicy.AccessMode.Forbidden);

        vm.prank(configurator);
        lossPolicy.setAccessMode(ILossPolicy.AccessMode.Forbidden);
        assertEq(uint256(lossPolicy.accessMode()), uint256(ILossPolicy.AccessMode.Forbidden));

        // setChecksEnabled works
        vm.expectEmit(true, true, true, true);
        emit SetChecksEnabled(false);

        vm.prank(configurator);
        lossPolicy.setChecksEnabled(false);
        assertFalse(lossPolicy.checksEnabled());
    }

    /// @notice U:[ALP-3]: `setAliasPriceFeed` works correctly
    function test_U_ALP_03_setAliasPriceFeed_works_correctly() public {
        // reverts on non-configurator
        vm.expectRevert(CallerNotConfiguratorException.selector);
        lossPolicy.setAliasPriceFeed(address(token), address(priceFeed));

        // reverts if token is not quoted
        poolQuotaKeeperMock.set_isQuotedToken(false);

        vm.expectRevert(TokenIsNotQuotedException.selector);
        vm.prank(configurator);
        lossPolicy.setAliasPriceFeed(address(token), address(priceFeed));

        // sets price feed correctly
        poolQuotaKeeperMock.set_isQuotedToken(true);
        priceFeedStoreMock.setStalenessPeriod(address(priceFeed), 3600);

        vm.expectEmit(true, true, true, true);
        emit SetAliasPriceFeed(address(token), address(priceFeed), 3600, false);

        vm.prank(configurator);
        lossPolicy.setAliasPriceFeed(address(token), address(priceFeed));

        PriceFeedParams memory params = lossPolicy.getAliasPriceFeedParams(address(token));
        assertEq(params.priceFeed, address(priceFeed), "Incorrect priceFeed");
        assertEq(params.stalenessPeriod, 3600, "Incorrect stalenessPeriod");
        assertEq(params.skipCheck, false, "Incorrect skipCheck");
        assertEq(params.tokenDecimals, 18, "Incorrect tokenDecimals");

        address[] memory tokens = lossPolicy.getTokensWithAlias();
        assertEq(tokens.length, 1, "Incorrect number of tokens");
        assertEq(tokens[0], address(token), "Incorrect token");

        // Check serialization after setting price feed
        (
            ILossPolicy.AccessMode mode,
            bool checks,
            address[] memory serializedTokens,
            PriceFeedParams[] memory serializedParams
        ) = abi.decode(lossPolicy.serialize(), (ILossPolicy.AccessMode, bool, address[], PriceFeedParams[]));
        assertEq(uint256(mode), uint256(ILossPolicy.AccessMode.Permissionless), "Incorrect serialized mode");
        assertTrue(checks, "Incorrect serialized checks");
        assertEq(serializedTokens.length, 1, "Incorrect serialized tokens length");
        assertEq(serializedTokens[0], address(token), "Incorrect serialized token");
        assertEq(serializedParams.length, 1, "Incorrect serialized params length");
        assertEq(serializedParams[0].priceFeed, address(priceFeed), "Incorrect serialized priceFeed");
        assertEq(serializedParams[0].stalenessPeriod, 3600, "Incorrect serialized stalenessPeriod");
        assertEq(serializedParams[0].skipCheck, false, "Incorrect serialized skipCheck");
        assertEq(serializedParams[0].tokenDecimals, 18, "Incorrect serialized tokenDecimals");

        // unsets price feed correctly
        vm.expectEmit(true, true, true, true);
        emit UnsetAliasPriceFeed(address(token));

        vm.prank(configurator);
        lossPolicy.setAliasPriceFeed(address(token), address(0));

        params = lossPolicy.getAliasPriceFeedParams(address(token));
        assertEq(params.priceFeed, address(0), "Price feed not unset");

        tokens = lossPolicy.getTokensWithAlias();
        assertEq(tokens.length, 0, "Token not removed from set");

        // Check serialization after unsetting price feed
        (mode, checks, serializedTokens, serializedParams) =
            abi.decode(lossPolicy.serialize(), (ILossPolicy.AccessMode, bool, address[], PriceFeedParams[]));
        assertEq(uint256(mode), uint256(ILossPolicy.AccessMode.Permissionless), "Incorrect serialized mode");
        assertTrue(checks, "Incorrect serialized checks");
        assertEq(serializedTokens.length, 0, "Incorrect serialized tokens length");
        assertEq(serializedParams.length, 0, "Incorrect serialized params length");
    }

    /// @notice U:[ALP-4]: `isLiquidatable` works correctly in different modes
    function test_U_ALP_04_isLiquidatable_works_correctly_in_different_modes() public {
        address caller2 = makeAddr("CALLER2");
        addressProviderMock.grantRole("LOSS_LIQUIDATOR", caller2);

        ILossPolicy.Params memory liquidatableParams =
            ILossPolicy.Params({totalDebtUSD: 1e8, twvUSD: 0.99e8, extraData: ""});
        ILossPolicy.Params memory nonLiquidatableParams =
            ILossPolicy.Params({totalDebtUSD: 1e8, twvUSD: 1.01e8, extraData: ""});

        // Permissionless mode with checks enabled
        lossPolicy.hackAccessMode(ILossPolicy.AccessMode.Permissionless);
        lossPolicy.hackChecksEnabled(true);

        assertTrue(
            lossPolicy.isLiquidatable(creditAccount, caller, liquidatableParams),
            "permissionless + checks, liquidatable account"
        );
        assertFalse(
            lossPolicy.isLiquidatable(creditAccount, caller, nonLiquidatableParams),
            "permissionless + checks, non-liquidatable account"
        );

        // Permissionless mode with checks disabled
        lossPolicy.hackChecksEnabled(false);

        assertTrue(
            lossPolicy.isLiquidatable(creditAccount, caller, liquidatableParams),
            "permissionless + no checks, liquidatable account"
        );
        assertTrue(
            lossPolicy.isLiquidatable(creditAccount, caller, nonLiquidatableParams),
            "permissionless + no checks, non-liquidatable account"
        );

        // Permissioned mode with checks enabled
        lossPolicy.hackAccessMode(ILossPolicy.AccessMode.Permissioned);
        lossPolicy.hackChecksEnabled(true);

        assertFalse(
            lossPolicy.isLiquidatable(creditAccount, caller, liquidatableParams),
            "permissioned + checks, non-whitelisted caller, liquidatable account"
        );
        assertFalse(
            lossPolicy.isLiquidatable(creditAccount, caller2, nonLiquidatableParams),
            "permissioned + checks, whitelisted caller, non-liquidatable account"
        );
        assertTrue(
            lossPolicy.isLiquidatable(creditAccount, caller2, liquidatableParams),
            "permissioned + checks, whitelisted caller, liquidatable account"
        );

        // Permissioned mode with checks disabled
        lossPolicy.hackChecksEnabled(false);

        assertFalse(
            lossPolicy.isLiquidatable(creditAccount, caller, liquidatableParams),
            "permissioned + no checks, non-whitelisted caller"
        );
        assertTrue(
            lossPolicy.isLiquidatable(creditAccount, caller2, liquidatableParams),
            "permissioned + no checks, whitelisted caller"
        );

        // Forbidden mode (checks don't matter)
        lossPolicy.hackAccessMode(ILossPolicy.AccessMode.Forbidden);

        assertFalse(
            lossPolicy.isLiquidatable(creditAccount, caller, liquidatableParams), "forbidden, non-whitelisted caller"
        );
        assertFalse(
            lossPolicy.isLiquidatable(creditAccount, caller2, liquidatableParams), "forbidden, whitelisted caller"
        );
    }

    /// @notice U:[ALP-5]: `isLiquidatable` calls `updatePrices` if needed
    function test_U_ALP_05_isLiquidatable_calls_updatePrices_if_needed() public {
        lossPolicy.hackAccessMode(ILossPolicy.AccessMode.Permissionless);
        lossPolicy.hackChecksEnabled(true);

        PriceUpdate[] memory updates = new PriceUpdate[](0);
        ILossPolicy.Params memory params =
            ILossPolicy.Params({totalDebtUSD: 1e8, twvUSD: 0.99e8, extraData: abi.encode(updates)});

        vm.expectCall(address(priceFeedStoreMock), abi.encodeCall(IPriceFeedStore.updatePrices, (updates)), 1);
        lossPolicy.isLiquidatable(creditAccount, caller, params);

        params.extraData = "";

        vm.expectCall(address(priceFeedStoreMock), abi.encodePacked(IPriceFeedStore.updatePrices.selector), 0);
        lossPolicy.isLiquidatable(creditAccount, caller, params);
    }

    /// @notice U:[ALP-6]: `getRequiredAliasPriceFeeds` works correctly
    function test_U_ALP_06_getRequiredAliasPriceFeeds_works_correctly() public {
        ERC20Mock token1 = new ERC20Mock("Test Token 1", "TEST1", 18);
        ERC20Mock token2 = new ERC20Mock("Test Token 2", "TEST2", 18);

        address priceFeed1 = makeAddr("PRICE_FEED1");
        address priceFeed2 = makeAddr("PRICE_FEED2");

        vm.mockCall(
            creditManager, abi.encodeCall(ICreditManagerV3.getTokenByMask, (1)), abi.encode(address(underlying))
        );
        vm.mockCall(creditManager, abi.encodeCall(ICreditManagerV3.getTokenByMask, (2)), abi.encode(token1));
        vm.mockCall(creditManager, abi.encodeCall(ICreditManagerV3.getTokenByMask, (4)), abi.encode(token2));

        lossPolicy.hackAddTokenWithAlias(
            address(token1),
            PriceFeedParams({priceFeed: priceFeed1, stalenessPeriod: 3600, skipCheck: false, tokenDecimals: 18})
        );
        lossPolicy.hackAddTokenWithAlias(
            address(token2),
            PriceFeedParams({priceFeed: priceFeed2, stalenessPeriod: 3600, skipCheck: false, tokenDecimals: 18})
        );

        vm.mockCall(creditManager, abi.encodeCall(ICreditManagerV3.enabledTokensMaskOf, (creditAccount)), abi.encode(3));

        address[] memory priceFeeds = lossPolicy.getRequiredAliasPriceFeeds(creditAccount);
        assertEq(priceFeeds.length, 1, "Incorrect number of price feeds");
        assertEq(priceFeeds[0], priceFeed1, "Incorrect first price feed");

        vm.mockCall(creditManager, abi.encodeCall(ICreditManagerV3.enabledTokensMaskOf, (creditAccount)), abi.encode(6));
        priceFeeds = lossPolicy.getRequiredAliasPriceFeeds(creditAccount);
        assertEq(priceFeeds.length, 2, "Incorrect number of price feeds");
        assertEq(priceFeeds[0], priceFeed1, "Incorrect first price feed");
        assertEq(priceFeeds[1], priceFeed2, "Incorrect second price feed");
    }

    /// @notice U:[ALP-7]: `_adjustForAliases` works correctly
    function test_U_ALP_07_adjustForAliases_works_correctly() public {
        ERC20Mock token2 = new ERC20Mock("Test Token 2", "TEST2", 18);

        // Setup mocks for two tokens
        vm.mockCall(
            creditManager,
            abi.encodeCall(ICreditManagerV3.enabledTokensMaskOf, (creditAccount)),
            abi.encode(6) // Tokens with masks 2 and 4 (mask 1 is for underlying)
        );
        vm.mockCall(creditManager, abi.encodeCall(ICreditManagerV3.getTokenByMask, (2)), abi.encode(address(token)));
        vm.mockCall(creditManager, abi.encodeCall(ICreditManagerV3.getTokenByMask, (4)), abi.encode(address(token2)));
        vm.mockCall(
            creditManager,
            abi.encodeCall(ICreditManagerV3.collateralTokenByMask, (2)),
            abi.encode(address(token), uint16(9000))
        );
        vm.mockCall(
            creditManager,
            abi.encodeCall(ICreditManagerV3.collateralTokenByMask, (4)),
            abi.encode(address(token2), uint16(9000))
        );

        // Setup token balances and quotas
        token.mint(creditAccount, 1e18);
        token2.mint(creditAccount, 1e18);
        vm.mockCall(
            address(poolQuotaKeeperMock),
            abi.encodeCall(IPoolQuotaKeeperV3.getQuota, (creditAccount, address(token))),
            abi.encode(2e18, 0)
        );
        vm.mockCall(
            address(poolQuotaKeeperMock),
            abi.encodeCall(IPoolQuotaKeeperV3.getQuota, (creditAccount, address(token2))),
            abi.encode(2e18, 0)
        );

        vm.mockCall(
            address(priceOracleMock),
            abi.encodeCall(IPriceOracleV3.convertToUSD, (1e27, address(underlying))),
            abi.encode(1e18)
        );
        vm.mockCall(
            address(priceOracleMock),
            abi.encodeCall(IPriceOracleV3.convertToUSD, (1e18, address(token))),
            abi.encode(0.9e8)
        );
        vm.mockCall(
            address(priceOracleMock),
            abi.encodeCall(IPriceOracleV3.convertToUSD, (1e18, address(token2))),
            abi.encode(0.8e8)
        );

        // Add alias price feed for token1 only
        lossPolicy.hackAddTokenWithAlias(
            address(token),
            PriceFeedParams({priceFeed: address(priceFeed), stalenessPeriod: 3600, skipCheck: false, tokenDecimals: 18})
        );

        // For token1:
        // - Normal price: 0.9e8 * 90% = 0.81e8
        // - Alias price: 1e8 * 90% = 0.9e8
        // - Difference: +0.09e8
        //
        // For token2:
        // - Normal price: 0.8e8 * 90% = 0.72e8
        // - No alias price
        // - Difference: 0
        //
        // Initial TWV = 1.53e8 (0.81e8 + 0.72e8)
        // Adjustment = 0.09e8 (from token1)
        // Final TWV = 1.53e8 + 0.09e8 = 1.62e8
        uint256 initialTWV = 1.53e8;
        uint256 adjustedTWV = lossPolicy.exposed_adjustForAliases(creditAccount, initialTWV);
        assertEq(adjustedTWV, initialTWV + 0.09e8, "Incorrect adjusted TWV");
    }

    /// @notice U:[ALP-8]: `_getSharedInfo` works correctly
    function test_U_ALP_08_getSharedInfo_works_correctly() public {
        vm.mockCall(
            address(priceOracleMock),
            abi.encodeCall(IPriceOracleV3.convertToUSD, (1e27, address(underlying))),
            abi.encode(1e18)
        );

        AliasedLossPolicyV3.SharedInfo memory info = lossPolicy.exposed_getSharedInfo(creditAccount);
        assertEq(info.creditManager, creditManager, "Incorrect creditManager");
        assertEq(info.priceOracle, address(priceOracleMock), "Incorrect priceOracle");
        assertEq(info.quotaKeeper, address(poolQuotaKeeperMock), "Incorrect quotaKeeper");
        assertEq(info.underlyingPriceRAY, 1e18, "Incorrect underlyingPriceRAY");
    }

    /// @notice U:[ALP-9]: `_getTokenInfo` works correctly
    function test_U_ALP_09_getTokenInfo_works_correctly() public {
        AliasedLossPolicyV3.SharedInfo memory sharedInfo = AliasedLossPolicyV3.SharedInfo({
            creditManager: creditManager,
            priceOracle: address(priceOracleMock),
            quotaKeeper: address(poolQuotaKeeperMock),
            underlyingPriceRAY: 1e18
        });

        uint256 tokenMask = 2;

        // Returns empty info if token has LT = 0
        vm.mockCall(
            creditManager,
            abi.encodeCall(ICreditManagerV3.collateralTokenByMask, (tokenMask)),
            abi.encode(token, uint16(0))
        );
        AliasedLossPolicyV3.TokenInfo memory info =
            lossPolicy.exposed_getTokenInfo(creditAccount, tokenMask, sharedInfo);
        assertEq(info.token, address(token), "Incorrect token");
        assertEq(info.lt, 0, "LT should be 0");
        assertEq(info.balance, 0, "Balance should be 0");
        assertEq(info.quotaUSD, 0, "QuotaUSD should be 0");
        assertEq(info.aliasParams.priceFeed, address(0), "Alias price feed should be 0");

        // Returns empty info if token has no alias
        vm.mockCall(
            creditManager,
            abi.encodeCall(ICreditManagerV3.collateralTokenByMask, (tokenMask)),
            abi.encode(token, uint16(9000))
        );
        info = lossPolicy.exposed_getTokenInfo(creditAccount, tokenMask, sharedInfo);
        assertEq(info.token, address(token), "Incorrect token");
        assertEq(info.lt, 9000, "Incorrect LT");
        assertEq(info.balance, 0, "Balance should be 0");
        assertEq(info.quotaUSD, 0, "QuotaUSD should be 0");
        assertEq(info.aliasParams.priceFeed, address(0), "Alias price feed should be 0");

        // Returns empty info if token has no balance
        lossPolicy.hackAddTokenWithAlias(
            address(token),
            PriceFeedParams({priceFeed: address(priceFeed), stalenessPeriod: 3600, skipCheck: false, tokenDecimals: 18})
        );
        info = lossPolicy.exposed_getTokenInfo(creditAccount, tokenMask, sharedInfo);
        assertEq(info.token, address(token), "Incorrect token");
        assertEq(info.lt, 9000, "Incorrect LT");
        assertEq(info.balance, 0, "Balance should be 0");
        assertEq(info.quotaUSD, 0, "QuotaUSD should be 0");
        assertEq(info.aliasParams.priceFeed, address(priceFeed), "Alias price feed should be set");

        // Returns empty info if token has no quota
        token.mint(creditAccount, 1e18);
        info = lossPolicy.exposed_getTokenInfo(creditAccount, tokenMask, sharedInfo);
        assertEq(info.token, address(token), "Incorrect token");
        assertEq(info.lt, 9000, "Incorrect LT");
        assertEq(info.balance, 1e18, "Incorrect balance");
        assertEq(info.quotaUSD, 0, "QuotaUSD should be 0");
        assertEq(info.aliasParams.priceFeed, address(priceFeed), "Alias price feed should be set");

        // Returns full info when all conditions are met
        vm.mockCall(
            address(poolQuotaKeeperMock),
            abi.encodeCall(IPoolQuotaKeeperV3.getQuota, (creditAccount, address(token))),
            abi.encode(0.1e18, 0)
        );
        info = lossPolicy.exposed_getTokenInfo(creditAccount, tokenMask, sharedInfo);
        assertEq(info.token, address(token), "Incorrect token");
        assertEq(info.lt, 9000, "Incorrect LT");
        assertEq(info.balance, 1e18, "Incorrect balance");
        assertEq(info.quotaUSD, 1e8, "Incorrect quotaUSD");
        assertEq(info.aliasParams.priceFeed, address(priceFeed), "Alias price feed should be set");
    }

    /// @notice U:[ALP-10]: `_getWeightedValueUSD` works correctly
    function test_U_ALP_10_getWeightedValueUSD_works_correctly() public {
        vm.mockCall(
            address(priceOracleMock),
            abi.encodeCall(IPriceOracleV3.convertToUSD, (1e18, address(token))),
            abi.encode(0.9e8)
        );

        AliasedLossPolicyV3.SharedInfo memory sharedInfo = AliasedLossPolicyV3.SharedInfo({
            creditManager: creditManager,
            priceOracle: address(priceOracleMock),
            quotaKeeper: address(poolQuotaKeeperMock),
            underlyingPriceRAY: 1e18
        });

        AliasedLossPolicyV3.TokenInfo memory tokenInfo = AliasedLossPolicyV3.TokenInfo({
            token: address(token),
            lt: 9000,
            balance: 1e18,
            quotaUSD: 1e8,
            aliasParams: PriceFeedParams({
                priceFeed: address(priceFeed),
                stalenessPeriod: 3600,
                skipCheck: false,
                tokenDecimals: 18
            })
        });

        // Normal price
        uint256 weightedValue = lossPolicy.exposed_getWeightedValueUSD(tokenInfo, sharedInfo, false);
        assertEq(weightedValue, 0.81e8, "Incorrect weighted value"); // min(0.9e18 * 90%, 1e8)

        // Alias price
        weightedValue = lossPolicy.exposed_getWeightedValueUSD(tokenInfo, sharedInfo, true);
        assertEq(weightedValue, 0.9e8, "Incorrect weighted value aliased"); // min(1e8 * 90%, 1e8)
    }

    /// @notice U:[ALP-11]: `_convertToUSDAlias` works correctly
    function test_U_ALP_11_convertToUSDAlias_works_correctly() public view {
        PriceFeedParams memory params =
            PriceFeedParams({priceFeed: address(priceFeed), stalenessPeriod: 3600, skipCheck: false, tokenDecimals: 18});

        // Normal case
        uint256 usdValue = lossPolicy.exposed_convertToUSDAlias(params, 1e18);
        assertEq(usdValue, 1e8, "Incorrect USD value");

        // Different token decimals
        params.tokenDecimals = 6;
        usdValue = lossPolicy.exposed_convertToUSDAlias(params, 1e6);
        assertEq(usdValue, 1e8, "Incorrect USD value");
    }
}
