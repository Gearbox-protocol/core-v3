// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../interfaces/IAddressProviderV3.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccountFactoryV3} from "../../core/AccountFactoryV3.sol";
import {IACL} from "../../interfaces/IACL.sol";
import {IContractsRegister} from "../../interfaces/IContractsRegister.sol";

import {IWETH} from "../../interfaces/external/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CreditFacadeV3} from "../../credit/CreditFacadeV3.sol";
import {CreditConfiguratorV3} from "../../credit/CreditConfiguratorV3.sol";
import {MultiCall} from "../../interfaces/ICreditFacadeV3.sol";
import {MultiCallBuilder} from "../lib/MultiCallBuilder.sol";
import {PoolV3} from "../../pool/PoolV3.sol";
import {PoolQuotaKeeperV3} from "../../pool/PoolQuotaKeeperV3.sol";
import {GaugeV3} from "../../pool/GaugeV3.sol";
import {CreditManagerFactory} from "../suites/CreditManagerFactory.sol";

import {ICreditFacadeV3Multicall} from "../../interfaces/ICreditFacadeV3.sol";

import {CreditManagerV3} from "../../credit/CreditManagerV3.sol";
import {IPriceOracleV3} from "../../interfaces/IPriceOracleV3.sol";
import {PoolFactory} from "../suites/PoolFactory.sol";

import {TokensTestSuite} from "../suites/TokensTestSuite.sol";
import {NetworkDetector} from "@gearbox-protocol/sdk-gov/contracts/NetworkDetector.sol";

import {IPoolV3DeployConfig, CreditManagerV3DeployParams, CollateralTokenHuman} from "../interfaces/ICreditConfig.sol";
import {MockCreditConfig} from "../config/MockCreditConfig.sol";
import {TestHelper} from "../lib/helper.sol";
import {ERC20Mock} from "../mocks/token/ERC20Mock.sol";
import {DegenNFTMock} from "../mocks/token/DegenNFTMock.sol";
import "../lib/constants.sol";
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import {PriceFeedMock} from "../mocks/oracles/PriceFeedMock.sol";
import {BalanceHelper} from "./BalanceHelper.sol";
import {BotListV3} from "../../core/BotListV3.sol";
// MOCKS
import {AdapterMock} from "../mocks/core/AdapterMock.sol";
import {TargetContractMock} from "../mocks/core/TargetContractMock.sol";
import {AddressProviderV3ACLMock} from "../mocks/core/AddressProviderV3ACLMock.sol";

import {GenesisFactory} from "../suites/GenesisFactory.sol";

import {ConfigManager} from "../config/ConfigManager.sol";
import "forge-std/console.sol";

contract IntegrationTestHelper is TestHelper, BalanceHelper, ConfigManager {
    uint256 constant WETH_TEST_AMOUNT = 5 * WAD;
    uint256 chainId;

    // CORE
    IACL acl;
    IAddressProviderV3 addressProvider;
    IContractsRegister cr;
    AccountFactoryV3 accountFactory;
    IPriceOracleV3 priceOracle;
    BotListV3 botList;

    /// POOL & CREDIT MANAGER
    PoolV3 public pool;
    PoolQuotaKeeperV3 public poolQuotaKeeper;
    GaugeV3 public gauge;

    DegenNFTMock public degenNFT;

    CreditManagerV3 public creditManager;
    CreditFacadeV3 public creditFacade;
    CreditConfiguratorV3 public creditConfigurator;

    CreditManagerV3[] public creditManagers;
    CreditFacadeV3[] public creditFacades;
    CreditConfiguratorV3[] public creditConfigurators;

    TargetContractMock targetMock;
    AdapterMock adapterMock;

    address public weth;

    bool public anyUnderlying = true;
    Tokens public underlyingT = Tokens.DAI;

    address public underlying;

    bool anyDegenNFT = true;
    bool whitelisted;

    bool anyExpirable = true;
    bool expirable;

    bool installAdapterMock = false;

    bool runOnFork;

    uint256 configAccountAmount;
    uint256 creditAccountAmount;

    modifier notExpirableCase() {
        expirable = false;
        anyExpirable = false;
        _;
    }

    modifier expirableCase() {
        expirable = true;
        anyExpirable = false;
        _;
    }

    modifier allExpirableCases() {
        anyExpirable = false;
        uint256 snapshot = vm.snapshot();
        expirable = false;
        _;
        vm.revertTo(snapshot);

        expirable = true;
        _;
    }

    modifier withoutDegenNFT() {
        anyDegenNFT = false;
        whitelisted = false;
        _;
    }

    modifier withDegenNFT() {
        anyDegenNFT = false;
        whitelisted = true;
        _;
    }

    modifier allDegenNftCases() {
        anyDegenNFT = false;
        uint256 snapshot = vm.snapshot();

        whitelisted = false;
        _;
        vm.revertTo(snapshot);

        whitelisted = true;
        _;
    }

    modifier withUnderlying(Tokens t) {
        anyUnderlying = false;
        underlyingT = t;
        _;
    }

    modifier withAdapterMock() {
        installAdapterMock = true;
        _;
    }

    modifier creditTest() {
        _setupCore();

        _deployMockCreditAndPool();

        if (installAdapterMock) {
            targetMock = new TargetContractMock();
            adapterMock = new AdapterMock(address(creditManager), address(targetMock));

            vm.prank(CONFIGURATOR);
            creditConfigurator.allowAdapter(address(adapterMock));
        }

        _;
    }

    modifier attachTest() {
        _attachCore();

        address creditManagerAddr;

        bool skipTest = false;

        try vm.envAddress("ATTACH_CREDIT_MANAGER") returns (address) {
            creditManagerAddr = vm.envAddress("ATTACH_CREDIT_MANAGER");
        } catch {
            revert("Credit manager address not set");
        }

        if (!_attachCreditManager(creditManagerAddr)) {
            console.log("Skipped");
            skipTest = true;
        }

        if (!skipTest) {
            _;
        }
    }

    constructor() {
        new Roles();
        NetworkDetector nd = new NetworkDetector();

        chainId = nd.chainId();
    }

    function _setupCore() internal {
        tokenTestSuite = new TokensTestSuite();
        vm.deal(address(this), 100 * WAD);
        tokenTestSuite.topUpWETH{value: 100 * WAD}();

        weth = tokenTestSuite.addressOf(Tokens.WETH);

        vm.startPrank(CONFIGURATOR);
        GenesisFactory gp = new GenesisFactory(weth, DUMB_ADDRESS);
        if (chainId == 1337 || chainId == 31337) gp.addPriceFeeds(tokenTestSuite.getPriceFeeds());
        addressProvider = gp.addressProvider();
        vm.stopPrank();

        _initCoreContracts();
    }

    function _attachCore() internal {
        tokenTestSuite = new TokensTestSuite();
        try vm.envAddress("ATTACH_ADDRESS_PROVIDER") returns (address val) {
            addressProvider = IAddressProviderV3(val);
        } catch {
            revert("ATTACH_ADDRESS_PROVIDER is not provided");
        }

        console.log("Starting mainnet test with address provider: %s", address(addressProvider));
        _initCoreContracts();
    }

    function _initCoreContracts() internal {
        acl = IACL(addressProvider.getAddressOrRevert(AP_ACL, NO_VERSION_CONTROL));
        cr = IContractsRegister(addressProvider.getAddressOrRevert(AP_CONTRACTS_REGISTER, NO_VERSION_CONTROL));
        accountFactory = AccountFactoryV3(addressProvider.getAddressOrRevert(AP_ACCOUNT_FACTORY, 3_10));
        priceOracle = IPriceOracleV3(addressProvider.getAddressOrRevert(AP_PRICE_ORACLE, 3_10));
        botList = BotListV3(payable(addressProvider.getAddressOrRevert(AP_BOT_LIST, 3_10)));
    }

    function _attachPool(address _pool) internal returns (bool isCompatible) {
        pool = PoolV3(_pool);

        poolQuotaKeeper = PoolQuotaKeeperV3(pool.poolQuotaKeeper());
        gauge = GaugeV3(poolQuotaKeeper.gauge());

        underlying = pool.asset();

        if (!anyUnderlying && underlying != tokenTestSuite.addressOf(underlyingT)) {
            return false;
        }

        return true;
    }

    function _attachCreditManager(address _creditManager) internal returns (bool isCompatible) {
        creditManager = CreditManagerV3(_creditManager);
        creditFacade = CreditFacadeV3(creditManager.creditFacade());
        creditConfigurator = CreditConfiguratorV3(creditManager.creditConfigurator());

        address _degenNFT = creditFacade.degenNFT();

        if (!_attachPool(creditManager.pool())) {
            return false;
        }

        if (!anyExpirable && creditFacade.expirable() != expirable) {
            return false;
        }

        if (!anyDegenNFT && whitelisted != (_degenNFT != address(0))) {
            return false;
        }
        if (configAccountAmount == 0) {
            uint256 minDebt;
            (minDebt, creditAccountAmount) = creditFacade.debtLimits();

            uint256 remainingBorrowable = pool.creditManagerBorrowable(address(creditManager));

            if (remainingBorrowable < 10 * minDebt) {
                uint256 depositAmount = 10 * minDebt;
                {
                    if (pool.expectedLiquidity() != 0) {
                        uint256 utilization =
                            WAD * (pool.expectedLiquidity() - pool.availableLiquidity()) / pool.expectedLiquidity();
                        if (utilization > 85 * WAD / 100) {
                            depositAmount +=
                                pool.expectedLiquidity() * utilization / (75 * WAD / 100) - pool.expectedLiquidity();
                        }
                    }
                }

                tokenTestSuite.mint(underlying, INITIAL_LP, depositAmount);
                tokenTestSuite.approve(underlying, INITIAL_LP, address(pool));

                vm.prank(INITIAL_LP);
                pool.deposit(depositAmount, INITIAL_LP);

                address configurator = IACL(addressProvider.getAddressOrRevert(AP_ACL, NO_VERSION_CONTROL)).owner();
                uint256 currentLimit = pool.creditManagerDebtLimit(address(creditManager));
                vm.prank(configurator);
                pool.setCreditManagerDebtLimit(address(creditManager), currentLimit + depositAmount);
            }

            creditAccountAmount = Math.min(creditAccountAmount, Math.max(remainingBorrowable / 2, minDebt));
            creditAccountAmount = Math.min(creditAccountAmount, minDebt * 5);
        } else {
            creditAccountAmount = configAccountAmount;
        }

        if (_degenNFT != address(0)) {
            address minter = DegenNFTMock(_degenNFT).minter();

            vm.prank(minter);
            DegenNFTMock(_degenNFT).mint(USER, 1000);
        }

        return true;
    }

    function _deployPool(IPoolV3DeployConfig config) internal {
        uint256 initialBalance = 10 * config.getAccountAmount();
        underlyingT = config.underlying();

        underlying = tokenTestSuite.addressOf(underlyingT);

        PoolFactory pf = new PoolFactory(address(addressProvider), config, underlying, true, tokenTestSuite);

        pool = pf.pool();
        gauge = pf.gauge();
        poolQuotaKeeper = pf.poolQuotaKeeper();

        vm.warp(block.timestamp + 7 days);
        vm.prank(CONFIGURATOR);
        gauge.updateEpoch();

        tokenTestSuite.mint(underlying, INITIAL_LP, initialBalance);
        tokenTestSuite.approve(underlying, INITIAL_LP, address(pool));

        vm.prank(INITIAL_LP);
        pool.deposit(initialBalance, INITIAL_LP);

        AddressProviderV3ACLMock(address(addressProvider)).addPool(address(pool));

        vm.label(address(pool), "Pool");
    }

    function _deployMockCreditAndPool() internal {
        require(underlyingT == Tokens.DAI, "IntegrationTestHelper: Only DAI mock config is supported");
        IPoolV3DeployConfig creditConfig = new MockCreditConfig();
        _deployCreditAndPool(creditConfig);
    }

    function _deployCreditAndPool(string memory configSymbol) internal {
        IPoolV3DeployConfig config = getDeployConfig(configSymbol);
        _deployCreditAndPool(config);
    }

    function _deployCreditAndPool(IPoolV3DeployConfig config) internal {
        _deployPool(config);

        creditAccountAmount = config.getAccountAmount();
        configAccountAmount = creditAccountAmount;
        CreditManagerV3DeployParams[] memory allCms = config.creditManagers();

        degenNFT = new DegenNFTMock("Degen NFT", "DNFT");
        degenNFT.mint(USER, 1000);

        uint256 len = allCms.length;

        for (uint256 i; i < len; ++i) {
            CreditManagerV3DeployParams memory cmParams = allCms[i];

            if (anyDegenNFT) {
                whitelisted = cmParams.whitelisted;
            }

            CreditManagerFactory cmf = new CreditManagerFactory({
                addressProvider: address(addressProvider),
                pool: address(pool),
                degenNFT: (whitelisted) ? address(degenNFT) : address(0),
                expirable: (anyExpirable) ? cmParams.expirable : expirable,
                maxEnabledTokens: cmParams.maxEnabledTokens,
                feeInterest: cmParams.feeInterest,
                name: cmParams.name
            });

            creditManager = cmf.creditManager();
            creditFacade = cmf.creditFacade();
            creditConfigurator = cmf.creditConfigurator();

            vm.startPrank(CONFIGURATOR);
            creditConfigurator.setMaxDebtLimit(cmParams.maxDebt);
            creditConfigurator.setMinDebtLimit(cmParams.minDebt);
            creditConfigurator.setFees(
                cmParams.feeLiquidation,
                cmParams.liquidationPremium,
                cmParams.feeLiquidationExpired,
                cmParams.liquidationPremiumExpired
            );
            vm.stopPrank();

            _addCollateralTokens(cmParams.collateralTokens);

            AddressProviderV3ACLMock(address(addressProvider)).addCreditManager(address(creditManager));

            if (expirable) {
                vm.prank(CONFIGURATOR);
                creditConfigurator.setExpirationDate(uint40(block.timestamp + 1));
            }

            vm.prank(CONFIGURATOR);
            AccountFactoryV3(address(accountFactory)).addCreditManager(address(creditManager));

            vm.prank(CONFIGURATOR);
            poolQuotaKeeper.addCreditManager(address(creditManager));

            vm.prank(CONFIGURATOR);
            pool.setCreditManagerDebtLimit(address(creditManager), cmParams.poolLimit);

            vm.prank(CONFIGURATOR);
            botList.setCreditManagerApprovedStatus(address(creditManager), true);

            vm.label(address(creditFacade), "CreditFacadeV3");
            vm.label(address(creditManager), "CreditManagerV3");
            vm.label(address(creditConfigurator), "CreditConfiguratorV3");

            tokenTestSuite.mint(underlying, USER, creditAccountAmount);
            tokenTestSuite.mint(underlying, FRIEND, creditAccountAmount);

            tokenTestSuite.approve(underlying, USER, address(creditManager));
            tokenTestSuite.approve(underlying, FRIEND, address(creditManager));

            creditManagers.push(creditManager);
            creditFacades.push(creditFacade);
            creditConfigurators.push(creditConfigurator);
        }

        if (len > 1) {
            creditManager = creditManagers[0];
            creditFacade = creditFacades[0];
            creditConfigurator = creditConfigurators[0];
        }
    }

    // /// @dev Opens credit account for testing management functions
    // function _openCreditAccount()
    //     internal
    //     returns (uint256 debt, uint256 cumulativeIndexLastUpdate, address creditAccount)
    // {
    //     debt = creditAccountAmount;

    //     cumulativeIndexLastUpdate = pool.baseInterestIndex();
    //     // pool.setCumulativeIndexNow(cumulativeIndexLastUpdate);

    //     vm.prank(address(creditFacade));

    //     // Existing address case
    //     creditAccount = creditManager.openCreditAccount(debt, USER);

    //     // Increase block number cause it's forbidden to close credit account in the same block
    //     vm.roll(block.number + 1);
    //     // vm.warp(block.timestamp + 100 days);

    //     // pool.setCumulativeIndexNow(cumulativeIndexAtClose);
    // }

    function _addAndEnableTokens(address creditAccount, uint256 numTokens, uint256 balance) internal {
        for (uint256 i = 0; i < numTokens; i++) {
            ERC20Mock t = new ERC20Mock("new token", "nt", 18);
            PriceFeedMock pf = new PriceFeedMock(10 ** 8, 8);

            vm.startPrank(CONFIGURATOR);
            creditManager.addToken(address(t));
            IPriceOracleV3(address(priceOracle)).setPriceFeed(address(t), address(pf), 1 hours);
            creditManager.setCollateralTokenData(address(t), 8000, 8000, type(uint40).max, 0);
            vm.stopPrank();

            t.mint(creditAccount, balance);
        }
    }

    ///
    /// HELPERS
    ///

    function _openCreditAccount(uint256 amount, address onBehalfOf, uint16 leverageFactor, uint16 referralCode)
        internal
        returns (address)
    {
        uint256 debt = (amount * leverageFactor) / 100; // LEVERAGE_DECIMALS; // F:[FA-5]

        return creditFacade.openCreditAccount(
            onBehalfOf,
            debt == 0
                ? MultiCallBuilder.build(
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, amount))
                    })
                )
                : MultiCallBuilder.build(
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (debt))
                    }),
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, amount))
                    })
                ),
            referralCode
        );
    }

    function _openTestCreditAccount() internal returns (address creditAccount, uint256 balance) {
        tokenTestSuite.mint(underlying, USER, creditAccountAmount);

        vm.startPrank(USER);
        creditAccount = _openCreditAccount(creditAccountAmount, USER, 100, 0);

        vm.stopPrank();

        balance = IERC20(underlying).balanceOf(creditAccount);

        vm.label(creditAccount, "creditAccount");
    }

    function expectTokenIsEnabled(address creditAccount, address token, bool expectedState) internal {
        expectTokenIsEnabled(creditAccount, token, expectedState, "");
    }

    function expectTokenIsEnabled(address creditAccount, address token, bool expectedState, string memory reason)
        internal
    {
        bool state = creditManager.getTokenMaskOrRevert(token) & creditManager.enabledTokensMaskOf(creditAccount) != 0;

        if (state != expectedState && bytes(reason).length != 0) {
            emit log_string(reason);
        }

        assertTrue(
            state == expectedState,
            string(
                abi.encodePacked(
                    "Token ",
                    IERC20Metadata(token).symbol(),
                    state ? " enabled as not expetcted" : " not enabled as expected "
                )
            )
        );
    }

    function _makeAccountsLiquitable() internal {
        vm.startPrank(CONFIGURATOR);
        uint256 idx = creditManager.collateralTokensCount() - 1;
        while (idx != 0) {
            address token = creditManager.getTokenByMask(1 << (idx--));
            creditConfigurator.setLiquidationThreshold(token, 0);
        }
        creditConfigurator.setFees(200, 9000, 100, 9500);
        vm.stopPrank();

        // switch to new block to be able to close account
        vm.roll(block.number + 1);
    }

    function expectSafeAllowance(address creditAccount, address target) internal {
        uint256 len = creditManager.collateralTokensCount();
        for (uint256 i = 0; i < len; i++) {
            (address token,) = creditManager.collateralTokenByMask(1 << i);
            assertLe(IERC20(token).allowance(creditAccount, target), 1, "allowance is too high");
        }
    }

    function expectTokenIsEnabled(address creditAccount, Tokens t, bool expectedState) internal {
        expectTokenIsEnabled(creditAccount, t, expectedState, "");
    }

    function expectTokenIsEnabled(address creditAccount, Tokens t, bool expectedState, string memory reason) internal {
        expectTokenIsEnabled(creditAccount, tokenTestSuite.addressOf(t), expectedState, reason);
    }

    function addCollateral(Tokens t, uint256 amount) internal {
        tokenTestSuite.mint(t, USER, amount);
        tokenTestSuite.approve(t, USER, address(creditManager));

        vm.startPrank(USER);
        // TODO: rewrite using addCollateral in mc
        // creditFacade.addCollateral(USER, tokenTestSuite.addressOf(t), amount);
        vm.stopPrank();
    }

    function _checkForWETHTest() internal {
        _checkForWETHTest(USER);
    }

    function _checkForWETHTest(address tester) internal {
        expectBalance(Tokens.WETH, tester, WETH_TEST_AMOUNT);

        expectEthBalance(tester, 0);
    }

    function _prepareForWETHTest() internal {
        _prepareForWETHTest(USER);
    }

    function _prepareForWETHTest(address tester) internal {
        vm.startPrank(tester);
        if (tester.balance > 0) {
            IWETH(weth).deposit{value: tester.balance}();
        }

        IERC20(weth).transfer(address(this), tokenTestSuite.balanceOf(Tokens.WETH, tester));

        vm.stopPrank();
        expectBalance(Tokens.WETH, tester, 0);

        vm.deal(tester, WETH_TEST_AMOUNT);
    }

    function makeTokenQuoted(address token, uint16 rate, uint96 limit) internal {
        vm.startPrank(CONFIGURATOR);
        gauge.addQuotaToken(token, rate, rate);
        poolQuotaKeeper.setTokenLimit(token, limit);

        vm.warp(block.timestamp + 7 days);
        gauge.updateEpoch();

        // uint256 tokenMask = creditManager.getTokenMaskOrRevert(token);
        // uint256 limitedMask = creditManager.quotedTokensMask();

        vm.stopPrank();
    }

    function executeOneLineMulticall(address creditAccount, address target, bytes memory callData) internal {
        creditFacade.multicall(creditAccount, MultiCallBuilder.build(MultiCall({target: target, callData: callData})));
    }

    function _addCollateralTokens(CollateralTokenHuman[] memory clts) internal {
        for (uint256 i = 0; i < clts.length; ++i) {
            address token = tokenTestSuite.addressOf(clts[i].token);

            vm.prank(CONFIGURATOR);
            creditConfigurator.addCollateralToken(token, clts[i].lt);
        }
    }
}
