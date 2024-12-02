// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";

import {AccountFactoryV3} from "../../core/AccountFactoryV3.sol";
import {AddressProviderV3} from "../../core/AddressProviderV3.sol";
import {BotListV3} from "../../core/BotListV3.sol";
import {PriceOracleV3} from "../../core/PriceOracleV3.sol";

import {CreditConfiguratorV3, CreditManagerOpts} from "../../credit/CreditConfiguratorV3.sol";
import {CreditManagerV3} from "../../credit/CreditManagerV3.sol";

import {GaugeV3} from "../../governance/GaugeV3.sol";
import {EPOCH_LENGTH, GearStakingV3, VotingContractStatus} from "../../governance/GearStakingV3.sol";

import {LinearInterestRateModelV3} from "../../pool/LinearInterestRateModelV3.sol";
import {PoolQuotaKeeperV3} from "../../pool/PoolQuotaKeeperV3.sol";
import {PoolV3} from "../../pool/PoolV3.sol";

import {PriceFeedMock} from "../mocks/oracles/PriceFeedMock.sol";
import {ERC20Mock} from "../mocks/token/ERC20Mock.sol";
import {WETHMock} from "../mocks/token/WETHMock.sol";

import {CreditManagerFactory} from "../suites/CreditManagerFactory.sol";

contract Deployer is Test {
    address configurator;
    address controller;
    address treasury;
    address weth;
    address gear;

    ACL acl;
    AccountFactoryV3 accountFactory;
    AddressProviderV3 addressProvider;
    BotListV3 botList;
    ContractsRegister contractsRegister;
    GearStakingV3 gearStaking;
    PriceOracleV3 priceOracle;

    address[] tokensList;
    mapping(string => ERC20) tokens;

    mapping(string => PoolV3) pools;
    mapping(string => CreditManagerV3) creditManagers;

    function setUp() public virtual {
        _deployCore();
        _deployTokensAndPriceFeeds();
        _deployPool("DAI");
        _deployPool("USDC");
        _deployCreditManager("DAI");
        _deployCreditManager("USDC");
    }

    // ------- //
    // GETTERS //
    // ------- //

    function _getToken(string memory symbol) internal view returns (ERC20 token) {
        token = tokens[symbol];
        require(address(token) != address(0), string.concat("Deployer: Token ", symbol, " not deployed yet"));
    }

    function _getPool(string memory name) internal view returns (PoolV3 pool) {
        pool = pools[name];
        require(address(pool) != address(0), string.concat("Deployer: Pool ", name, " not deployed yet"));
    }

    function _getQuotaKeeper(string memory poolName) internal view returns (PoolQuotaKeeperV3) {
        return PoolQuotaKeeperV3(_getPool(poolName).poolQuotaKeeper());
    }

    function _getGauge(string memory poolName) internal view returns (GaugeV3) {
        return GaugeV3(_getQuotaKeeper(poolName).gauge());
    }

    function _getQuotedTokens(string memory poolName) internal view returns (address[] memory quotedTokens) {
        uint256 numTokens = tokensList.length;
        quotedTokens = new address[](numTokens);

        uint256 numQuotedTokens;
        GaugeV3 gauge = _getGauge(poolName);
        for (uint256 i; i < numTokens; ++i) {
            if (gauge.isTokenAdded(tokensList[i])) quotedTokens[numQuotedTokens++] = tokensList[i];
        }
        assembly {
            mstore(quotedTokens, numQuotedTokens)
        }
    }

    function _getCreditManager(string memory name) internal view returns (CreditManagerV3 creditManager) {
        creditManager = creditManagers[name];
        require(
            address(creditManager) != address(0), string.concat("Deployer: Credit manager ", name, " not deployed yet")
        );
    }

    // ---- //
    // CORE //
    // ---- //

    function _deployCore() internal {
        configurator = makeAddr("CONFIGURATOR");
        controller = makeAddr("CONTROLLER");
        treasury = makeAddr("TREASURY");

        weth = address(new WETHMock());
        gear = address(new ERC20Mock("Gearbox", "GEAR", 18));

        vm.startPrank(configurator);
        acl = new ACL();
        addressProvider = new AddressProviderV3(address(acl));
        addressProvider.setAddress("TREASURY", treasury, false);
        addressProvider.setAddress("GEAR_TOKEN", gear, false);
        addressProvider.setAddress("WETH_TOKEN", weth, false);

        contractsRegister = new ContractsRegister(address(addressProvider));
        addressProvider.setAddress("CONTRACTS_REGISTER", address(contractsRegister), false);

        accountFactory = new AccountFactoryV3(address(addressProvider));
        addressProvider.setAddress("ACCOUNT_FACTORY", address(accountFactory), false);

        botList = new BotListV3(address(addressProvider));
        addressProvider.setAddress("BOT_LIST", address(botList), true);

        gearStaking = new GearStakingV3(address(addressProvider), block.timestamp);
        addressProvider.setAddress("GEAR_STAKING", address(gearStaking), true);

        priceOracle = new PriceOracleV3(address(addressProvider));
        addressProvider.setAddress("PRICE_ORACLE", address(priceOracle), true);
        priceOracle.setController(controller);
        vm.stopPrank();
    }

    // ------ //
    // TOKENS //
    // ------ //

    struct TokenConfig {
        string name;
        string symbol;
        uint8 decimals;
        int256 price;
        uint32 stalenessPeriod;
        bool trusted;
    }

    function _defaultTokenConfigs() internal pure returns (TokenConfig[] memory configs) {
        configs = new TokenConfig[](5);
        configs[0] = TokenConfig("Wrapped Ether", "WETH", 18, 2_500e8, 1 days, true);
        configs[1] = TokenConfig("Wrapped Bitcoin", "WBTC", 8, 50_000e8, 1 days, true);
        configs[2] = TokenConfig("USD Coin", "USDC", 6, 1e8, 1 days, true);
        configs[3] = TokenConfig("Dai Stablecoin", "DAI", 18, 1e8, 1 days, true);
        configs[4] = TokenConfig("ChainLink Token", "LINK", 18, 15e8, 1 days, true);
    }

    function _deployTokensAndPriceFeeds() internal {
        _deployTokensAndPriceFeeds(_defaultTokenConfigs());
    }

    function _deployTokensAndPriceFeeds(TokenConfig[] memory configs) internal {
        require(address(priceOracle) != address(0), "Deployer: Core not deployed yet");

        vm.startPrank(configurator);
        for (uint256 i; i < configs.length; ++i) {
            TokenConfig memory config = configs[i];
            _addToken(
                config.symbol,
                Strings.equal(config.symbol, "WETH")
                    ? ERC20(weth)
                    : new ERC20Mock(config.name, config.symbol, config.decimals)
            );
            address priceFeed = address(new PriceFeedMock(config.price, 8));
            priceOracle.setPriceFeed(address(tokens[config.symbol]), priceFeed, config.stalenessPeriod, config.trusted);
        }
        vm.stopPrank();
    }

    function _addToken(string memory symbol, ERC20 token) internal {
        require(address(tokens[symbol]) == address(0), string.concat("Deployer: Token ", symbol, " already deployed"));
        tokens[symbol] = token;
        tokensList.push(address(token));
    }

    // ----- //
    // POOLS //
    // ----- //

    struct PoolConfig {
        string underlyingSymbol;
        string name;
        string symbol;
        uint256 totalDebtLimit;
        uint256 deadShares;
        IRMParams irmParams;
        QuotaConfig[] quotas;
    }

    struct IRMParams {
        uint16 U_1;
        uint16 U_2;
        uint16 R_base;
        uint16 R_slope1;
        uint16 R_slope2;
        uint16 R_slope3;
        bool isBorrowingMoreU2Forbidden;
    }

    struct QuotaConfig {
        string symbol;
        uint96 limit;
        uint16 minRate;
        uint16 maxRate;
        uint16 increaseFee;
    }

    function _defaultPoolConfig(string memory underlying) internal pure returns (PoolConfig memory) {
        require(
            Strings.equal(underlying, "DAI") || Strings.equal(underlying, "USDC"),
            string.concat("Deployer: No default pool configuration for ", underlying, " underlying")
        );

        bool isDai = Strings.equal(underlying, "DAI");

        QuotaConfig[] memory quotas = new QuotaConfig[](3);
        quotas[0] = QuotaConfig("WETH", isDai ? 25_000_000e18 : 25_000_000e6, 1, 500, 0);
        quotas[1] = QuotaConfig("WBTC", isDai ? 25_000_000e18 : 25_000_000e6, 1, 500, 0);
        quotas[2] = QuotaConfig("LINK", isDai ? 5_000_000e18 : 5_000_000e6, 100, 1000, 10);

        return PoolConfig({
            underlyingSymbol: underlying,
            name: string.concat("Diesel ", underlying, " v3"),
            symbol: string.concat("d", underlying, "v3"),
            totalDebtLimit: isDai ? 50_000_000e18 : 50_000_000e6,
            deadShares: 1e5,
            irmParams: _defaultIRMParams(),
            quotas: quotas
        });
    }

    function _defaultIRMParams() internal pure returns (IRMParams memory) {
        return IRMParams({
            U_1: 80_00,
            U_2: 90_00,
            R_base: 0,
            R_slope1: 5,
            R_slope2: 20,
            R_slope3: 100_00,
            isBorrowingMoreU2Forbidden: true
        });
    }

    function _deployPool(string memory underlying) internal returns (PoolV3 pool) {
        pool = _deployPool(_defaultPoolConfig(underlying));
    }

    function _deployPool(PoolConfig memory config) internal returns (PoolV3 pool) {
        ERC20 underlying = _getToken(config.underlyingSymbol);
        require(
            address(pools[config.name]) == address(0),
            string.concat("Deployer: Pool ", config.name, " already deployed")
        );

        vm.startPrank(configurator);
        LinearInterestRateModelV3 irm = new LinearInterestRateModelV3(
            config.irmParams.U_1,
            config.irmParams.U_2,
            config.irmParams.R_base,
            config.irmParams.R_slope1,
            config.irmParams.R_slope2,
            config.irmParams.R_slope3,
            config.irmParams.isBorrowingMoreU2Forbidden
        );

        pool = new PoolV3(
            address(addressProvider),
            address(underlying),
            address(irm),
            config.totalDebtLimit,
            config.name,
            config.symbol
        );
        deal(address(underlying), configurator, config.deadShares);
        underlying.approve(address(pool), config.deadShares);
        pool.deposit(config.deadShares, address(0xdead));
        pool.setController(controller);

        GaugeV3 gauge = new GaugeV3(address(pool), address(gearStaking));
        gauge.setController(controller);
        gearStaking.setVotingContractStatus(address(gauge), VotingContractStatus.ALLOWED);

        PoolQuotaKeeperV3 quotaKeeper = new PoolQuotaKeeperV3(address(pool));
        quotaKeeper.setController(controller);
        quotaKeeper.setGauge(address(gauge));
        pool.setPoolQuotaKeeper(address(quotaKeeper));

        pools[config.name] = pool;
        contractsRegister.addPool(address(pool));
        _addToken(config.symbol, pool);

        for (uint256 i; i < config.quotas.length; ++i) {
            QuotaConfig memory quota = config.quotas[i];
            address token = address(_getToken(quota.symbol));
            gauge.addQuotaToken(token, quota.minRate, quota.maxRate);
            quotaKeeper.setTokenLimit(token, quota.limit);
            quotaKeeper.setTokenQuotaIncreaseFee(token, quota.increaseFee);
        }
        gauge.setFrozenEpoch(false);
        vm.stopPrank();
    }

    // --------------- //
    // CREDIT MANAGERS //
    // --------------- //

    struct CreditManagerConfig {
        string poolName;
        string name;
        uint256 debtLimit;
        uint128 minDebt;
        uint128 maxDebt;
        bool expirable;
        CollateralConfig[] collaterals;
    }

    struct CollateralConfig {
        string symbol;
        uint16 liquidationThreshold;
    }

    function _defaultCreditManagerConfig(string memory underlying) internal pure returns (CreditManagerConfig memory) {
        require(
            Strings.equal(underlying, "DAI") || Strings.equal(underlying, "USDC"),
            string.concat("Deployer: No default credit manager configuration for ", underlying, " underlying")
        );

        bool isDai = Strings.equal(underlying, "DAI");

        CollateralConfig[] memory collaterals = new CollateralConfig[](4);
        collaterals[0] = CollateralConfig(isDai ? "USDC" : "DAI", 90_00);
        collaterals[1] = CollateralConfig("WETH", 80_00);
        collaterals[2] = CollateralConfig("WBTC", 80_00);
        collaterals[3] = CollateralConfig("LINK", 75_00);

        return CreditManagerConfig({
            poolName: string.concat("Diesel ", underlying, " v3"),
            name: string.concat(underlying, " v3"),
            debtLimit: isDai ? 25_000_000e18 : 25_000_000e6,
            minDebt: isDai ? 10_000e18 : 10_000e6,
            maxDebt: isDai ? 200_000e18 : 200_000e6,
            expirable: false,
            collaterals: collaterals
        });
    }

    function _deployCreditManager(string memory underlying) internal returns (CreditManagerV3 creditManager) {
        creditManager = _deployCreditManager(_defaultCreditManagerConfig(underlying));
    }

    function _deployCreditManager(CreditManagerConfig memory config) internal returns (CreditManagerV3 creditManager) {
        PoolV3 pool = _getPool(config.poolName);
        require(
            address(creditManagers[config.name]) == address(0),
            string.concat("Deployer: Credit manager ", config.name, " already deployed")
        );

        vm.startPrank(configurator);
        CreditManagerFactory cmf = new CreditManagerFactory(
            address(addressProvider),
            address(pool),
            CreditManagerOpts({
                minDebt: config.minDebt,
                maxDebt: config.maxDebt,
                degenNFT: address(0),
                expirable: config.expirable,
                name: config.name
            }),
            0
        );

        CreditConfiguratorV3 creditConfigurator = cmf.creditConfigurator();
        creditConfigurator.setController(controller);

        creditManager = cmf.creditManager();
        creditManagers[config.name] = creditManager;
        contractsRegister.addCreditManager(address(creditManager));
        PoolV3(pool).setCreditManagerDebtLimit(address(creditManager), config.debtLimit);
        accountFactory.addCreditManager(address(creditManager));
        botList.setCreditManagerApprovedStatus(address(creditManager), true);
        PoolQuotaKeeperV3(PoolV3(pool).poolQuotaKeeper()).addCreditManager(address(creditManager));

        for (uint256 i; i < config.collaterals.length; ++i) {
            CollateralConfig memory collateral = config.collaterals[i];
            address token = address(_getToken(collateral.symbol));
            creditConfigurator.addCollateralToken(token, collateral.liquidationThreshold);
        }
        vm.stopPrank();
    }
}
