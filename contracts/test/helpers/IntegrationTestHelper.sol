// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../../interfaces/IAddressProviderV3.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";
import {AccountFactoryV3} from "../../core/AccountFactoryV3.sol";

import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CreditFacadeV3} from "../../credit/CreditFacadeV3.sol";
import {CreditConfiguratorV3} from "../../credit/CreditConfiguratorV3.sol";
import {MultiCall} from "../../interfaces/ICreditFacadeV3.sol";
import {MultiCallBuilder} from "../lib/MultiCallBuilder.sol";
import {PoolV3} from "../../pool/PoolV3.sol";
import {PoolQuotaKeeperV3} from "../../pool/PoolQuotaKeeperV3.sol";
import {GaugeV3} from "../../governance/GaugeV3.sol";
import {DegenNFTV2} from "@gearbox-protocol/core-v2/contracts/tokens/DegenNFTV2.sol";
import {CreditManagerFactory} from "../suites/CreditManagerFactory.sol";

import {ICreditFacadeV3Multicall} from "../../interfaces/ICreditFacadeV3.sol";

import {CreditManagerV3} from "../../credit/CreditManagerV3.sol";
import {IPriceOracleV2, IPriceOracleV2Ext} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracleV2.sol";
import {IWithdrawalManagerV3} from "../../interfaces/IWithdrawalManagerV3.sol";
import {CreditManagerOpts, CollateralToken} from "../../credit/CreditConfiguratorV3.sol";
import {PoolFactory} from "../suites/PoolFactory.sol";

import {TokensTestSuite} from "../suites/TokensTestSuite.sol";

// import { TokensTestSuite, Tokens } from "../suites/TokensTestSuite.sol";
import {CreditConfig} from "../config/CreditConfig.sol";
import {TestHelper} from "../lib/helper.sol";
import {ERC20Mock} from "../mocks/token/ERC20Mock.sol";
import "../lib/constants.sol";
import {Tokens} from "@gearbox-protocol/sdk/contracts/Tokens.sol";
import {PriceFeedMock} from "../mocks/oracles/PriceFeedMock.sol";
import {BalanceHelper} from "./BalanceHelper.sol";
import {BotListV3} from "../../core/BotListV3.sol";
import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";
// MOCKS
import {AdapterMock} from "../mocks/core/AdapterMock.sol";
import {TargetContractMock} from "../mocks/core/TargetContractMock.sol";

import {GenesisFactory} from "../suites/GenesisFactory.sol";
import "forge-std/console.sol";

contract IntegrationTestHelper is TestHelper, BalanceHelper {
    uint256 constant WETH_TEST_AMOUNT = 5 * WAD;

    // CORE
    IAddressProviderV3 addressProvider;
    ContractsRegister cr;
    AccountFactory accountFactory;
    IPriceOracleV2 priceOracle;
    IWithdrawalManagerV3 withdrawalManager;
    BotListV3 botList;

    /// POOL & CREDIT MANAGER
    PoolV3 pool;
    PoolQuotaKeeperV3 public poolQuotaKeeper;
    GaugeV3 public gauge;

    DegenNFTV2 public degenNFT;

    CreditManagerV3 public creditManager;
    CreditFacadeV3 public creditFacade;
    CreditConfiguratorV3 public creditConfigurator;

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

    bool anySupportsQuotas = true;
    bool supportsQuotas;

    bool anyAccountFactory = true;
    uint256 accountFactoryVersion = 1;

    bool installAdapterMock = false;

    bool runOnFork;

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

    modifier withoutQuotas() {
        anySupportsQuotas = false;
        supportsQuotas = false;
        _;
    }

    modifier withQuotas() {
        anySupportsQuotas = false;
        supportsQuotas = true;
        _;
    }

    modifier withAllQuotas() {
        anySupportsQuotas = false;

        uint256 snapshot = vm.snapshot();

        supportsQuotas = true;
        _;
        vm.revertTo(snapshot);
        supportsQuotas = false;
        _;
    }

    modifier withAccountFactoryV1() {
        anyAccountFactory = false;
        accountFactoryVersion = 1;
        _;
    }

    modifier withAccountFactoryV3() {
        anyAccountFactory = false;
        accountFactoryVersion = 3_00;
        _;
    }

    modifier withAllAccountFactories() {
        anyAccountFactory = false;
        uint256 snapshot = vm.snapshot();

        accountFactoryVersion = 1;
        _;
        vm.revertTo(snapshot);

        accountFactoryVersion = 3_00;
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

        bool skipTest = false;

        if (runOnFork) {
            address creditManagerAddr;

            try vm.envAddress("ETH_FORK_CREDIT_MANAGER") returns (address) {
                creditManagerAddr = vm.envAddress("ETH_FORK_CREDIT_MANAGER");
            } catch {
                revert("Credit manager address not set");
            }

            if (!_attachCreditManager(creditManagerAddr)) {
                console.log("Skipped");
                skipTest = true;
            }
        } else {
            _deployCreditAndPool();
        }

        if (!skipTest) {
            if (installAdapterMock) {
                targetMock = new TargetContractMock();
                adapterMock = new AdapterMock(address(creditManager), address(targetMock));

                vm.prank(CONFIGURATOR);
                creditConfigurator.allowAdapter(address(adapterMock));
            }
            _;
        }
    }

    function _setupCore() internal {
        new Roles();
        if (block.chainid == 1337) {
            uint8 networkId;
            bool useExisting;

            try vm.envInt("ETH_FORK_NETWORK_ID") returns (int256 val) {
                networkId = uint8(uint256(val));
            } catch {
                networkId = 1;
            }

            try vm.envBool("ETH_FORK_USE_EXISTING") returns (bool val) {
                useExisting = val;
            } catch {
                useExisting = false;
            }

            try vm.envAddress("ETH_FORK_ADDRESS_PROVIDER") returns (address val) {
                addressProvider = IAddressProviderV3(val);
            } catch {
                revert("ETH_FORK_ADDRESS_PROVIDER is not provided");
            }

            console.log("Starting mainnet test with address provider: %s", address(addressProvider));

            /// TRANSFER OWNERSHIP TO CONFIGURATOR
        } else {
            tokenTestSuite = new TokensTestSuite();
            tokenTestSuite.topUpWETH{value: 100 * WAD}();

            weth = tokenTestSuite.addressOf(Tokens.WETH);

            CreditConfig creditConfig = new CreditConfig(
            tokenTestSuite,
            underlyingT
        );

            vm.startPrank(CONFIGURATOR);
            GenesisFactory gp = new GenesisFactory(weth, DUMB_ADDRESS, accountFactoryVersion);

            gp.acl().claimOwnership();

            gp.acl().addPausableAdmin(CONFIGURATOR);
            gp.acl().addUnpausableAdmin(CONFIGURATOR);

            gp.acl().transferOwnership(address(gp));
            gp.claimACLOwnership();

            gp.addPriceFeeds(creditConfig.getPriceFeeds());
            gp.acl().claimOwnership();

            addressProvider = gp.addressProvider();

            vm.stopPrank();
        }

        cr = ContractsRegister(addressProvider.getAddressOrRevert(AP_CONTRACTS_REGISTER, 1));
        accountFactory = AccountFactory(addressProvider.getAddressOrRevert(AP_ACCOUNT_FACTORY, NO_VERSION_CONTROL));
        priceOracle = IPriceOracleV2(addressProvider.getAddressOrRevert(AP_PRICE_ORACLE, 2));
        withdrawalManager = IWithdrawalManagerV3(addressProvider.getAddressOrRevert(AP_WITHDRAWAL_MANAGER, 3_00));
        botList = BotListV3(payable(addressProvider.getAddressOrRevert(AP_BOT_LIST, 3_00)));
    }

    function _attachPool(address _pool) internal returns (bool isCompartible) {
        pool = PoolV3(_pool);
        if (!anySupportsQuotas && pool.supportsQuotas() != supportsQuotas) {
            return false;
        }

        if (supportsQuotas) {
            poolQuotaKeeper = PoolQuotaKeeperV3(pool.poolQuotaKeeper());
            gauge = GaugeV3(poolQuotaKeeper.gauge());
        }

        underlying = pool.asset();

        if (!anyUnderlying && underlying != tokenTestSuite.addressOf(underlyingT)) {
            return false;
        }

        return true;
    }

    function _attachCreditManager(address _creditManager) internal returns (bool isCompartible) {
        creditManager = CreditManagerV3(_creditManager);
        creditFacade = CreditFacadeV3(creditManager.creditFacade());

        if (!_attachPool(creditManager.pool())) {
            return false;
        }

        if (!anyExpirable && creditFacade.expirable() != expirable) {
            return false;
        }

        if (!anyDegenNFT && whitelisted != (creditFacade.degenNFT() != address(0))) {
            return false;
        }

        (, creditAccountAmount) = creditFacade.debtLimits();
    }

    function _deployPool(uint256 initialBalance) internal {
        underlying = tokenTestSuite.addressOf(underlyingT);

        PoolFactory pf = new PoolFactory(address(addressProvider), underlying, supportsQuotas);

        pool = pf.pool();
        gauge = pf.gauge();
        poolQuotaKeeper = pf.poolQuotaKeeper();

        tokenTestSuite.mint(underlying, INITIAL_LP, initialBalance);
        tokenTestSuite.approve(underlying, INITIAL_LP, address(pool));

        vm.prank(INITIAL_LP);
        pool.deposit(initialBalance, INITIAL_LP);

        vm.prank(CONFIGURATOR);
        cr.addPool(address(pool));

        vm.label(address(pool), "Pool");
    }

    function _deployCreditAndPool() internal {
        CreditConfig creditConfig = new CreditConfig(
            tokenTestSuite,
            underlyingT
        );

        _deployPool(10 * creditConfig.getAccountAmount());

        // uint128 minDebt = creditConfig.minDebt();
        // uint128 maxDebt = creditConfig.maxDebt();

        creditAccountAmount = creditConfig.getAccountAmount();

        CreditManagerOpts memory cmOpts = creditConfig.getCreditOpts();

        cmOpts.expirable = expirable;

        if (whitelisted) {
            degenNFT = new DegenNFTV2(
            address(addressProvider),
            "DegenNFTV2",
            "Gear-Degen"
        );

            vm.prank(CONFIGURATOR);
            degenNFT.setMinter(CONFIGURATOR);

            cmOpts.degenNFT = address(degenNFT);
        }

        CreditManagerFactory cmf = new CreditManagerFactory(
            address(addressProvider),
            address(pool),
            cmOpts,
            0
        );

        creditManager = cmf.creditManager();
        creditFacade = cmf.creditFacade();
        creditConfigurator = cmf.creditConfigurator();

        vm.prank(CONFIGURATOR);
        cr.addCreditManager(address(creditManager));

        if (whitelisted) {
            vm.prank(CONFIGURATOR);
            degenNFT.addCreditFacade(address(creditFacade));
        }

        if (expirable) {
            vm.prank(CONFIGURATOR);
            creditConfigurator.setExpirationDate(uint40(block.timestamp + 1));
        }

        if (accountFactoryVersion == 3_00) {
            vm.prank(CONFIGURATOR);
            AccountFactoryV3(address(accountFactory)).addCreditManager(address(creditManager));
        }

        if (supportsQuotas) {
            vm.prank(CONFIGURATOR);
            poolQuotaKeeper.addCreditManager(address(creditManager));
        }

        vm.prank(CONFIGURATOR);
        pool.setCreditManagerDebtLimit(address(creditManager), type(uint256).max);

        vm.prank(CONFIGURATOR);
        botList.setApprovedCreditManagerStatus(address(creditManager), true);

        vm.label(address(creditFacade), "CreditFacadeV3");
        vm.label(address(creditManager), "CreditManagerV3");
        vm.label(address(creditConfigurator), "CreditConfiguratorV3");

        tokenTestSuite.mint(underlying, USER, creditAccountAmount);
        tokenTestSuite.mint(underlying, FRIEND, creditAccountAmount);

        vm.prank(USER);
        IERC20(underlying).approve(address(creditManager), type(uint256).max);

        vm.prank(FRIEND);
        IERC20(underlying).approve(address(creditManager), type(uint256).max);
    }

    /// @dev Opens credit account for testing management functions
    function _openCreditAccount()
        internal
        returns (uint256 debt, uint256 cumulativeIndexLastUpdate, address creditAccount)
    {
        debt = creditAccountAmount;

        cumulativeIndexLastUpdate = pool.calcLinearCumulative_RAY();
        // pool.setCumulativeIndexNow(cumulativeIndexLastUpdate);

        vm.prank(address(creditFacade));

        // Existing address case
        creditAccount = creditManager.openCreditAccount(debt, USER);

        // Increase block number cause it's forbidden to close credit account in the same block
        vm.roll(block.number + 1);
        // vm.warp(block.timestamp + 100 days);

        // pool.setCumulativeIndexNow(cumulativeIndexAtClose);
    }

    function _addAndEnableTokens(address creditAccount, uint256 numTokens, uint256 balance) internal {
        for (uint256 i = 0; i < numTokens; i++) {
            ERC20Mock t = new ERC20Mock("new token", "nt", 18);
            PriceFeedMock pf = new PriceFeedMock(10**8, 8);

            vm.startPrank(CONFIGURATOR);
            creditManager.addToken(address(t));
            IPriceOracleV2Ext(address(priceOracle)).addPriceFeed(address(t), address(pf));
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
        uint256 borrowedAmount = (amount * leverageFactor) / 100; // LEVERAGE_DECIMALS; // F:[FA-5]

        return creditFacade.openCreditAccount(
            borrowedAmount,
            onBehalfOf,
            MultiCallBuilder.build(
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
        vm.prank(CONFIGURATOR);
        creditConfigurator.setFees(1000, 200, 9000, 100, 9500);

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
        require(supportsQuotas, "Test suite does not support quotas");

        vm.startPrank(CONFIGURATOR);
        gauge.addQuotaToken(token, rate, rate);
        poolQuotaKeeper.setTokenLimit(token, limit);

        vm.warp(block.timestamp + 7 days);
        gauge.updateEpoch();

        // uint256 tokenMask = creditManager.getTokenMaskOrRevert(token);
        // uint256 limitedMask = creditManager.quotedTokensMask();

        creditConfigurator.makeTokenQuoted(token);

        vm.stopPrank();
    }
}
