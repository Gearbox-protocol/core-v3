// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../../interfaces/IAddressProviderV3.sol";
import {TokensTestSuite} from "../suites/TokensTestSuite.sol";
import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CreditFacadeV3} from "../../credit/CreditFacadeV3.sol";
import {CreditConfiguratorV3} from "../../credit/CreditConfiguratorV3.sol";
import {MultiCall} from "../../interfaces/ICreditFacadeV3.sol";
import {MultiCallBuilder} from "../lib/MultiCallBuilder.sol";
import {PoolV3} from "../../pool/PoolV3.sol";
import {ICreditFacadeV3Multicall} from "../../interfaces/ICreditFacadeV3.sol";
import {ICreditManagerV3Events} from "../../interfaces/ICreditManagerV3.sol";
import {CreditManagerV3} from "../../credit/CreditManagerV3.sol";
import {IPriceOracleV2, IPriceOracleV2Ext} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracleV2.sol";
import {IWithdrawalManagerV3} from "../../interfaces/IWithdrawalManagerV3.sol";

import {TokensTestSuite} from "../suites/TokensTestSuite.sol";
import {CreditFacadeTestSuite} from "../suites/CreditFacadeTestSuite.sol";
// import { TokensTestSuite, Tokens } from "../suites/TokensTestSuite.sol";
import {CreditConfig} from "../config/CreditConfig.sol";
import {TestHelper} from "../lib/helper.sol";
import {ERC20Mock} from "../mocks/token/ERC20Mock.sol";
import "../lib/constants.sol";
import {Tokens} from "../config/Tokens.sol";
import {PriceFeedMock} from "../mocks/oracles/PriceFeedMock.sol";
import {BalanceHelper} from "./BalanceHelper.sol";
import {BotListV3} from "../../core/BotListV3.sol";
import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";
// MOCKS
import {AdapterMock} from "../mocks/core/AdapterMock.sol";
import {TargetContractMock} from "../mocks/core/TargetContractMock.sol";

contract CreditFacadeTestHelper is TestHelper, BalanceHelper {
    uint256 constant WETH_TEST_AMOUNT = 5 * WAD;

    TargetContractMock targetMock;
    AdapterMock adapterMock;

    AccountFactory accountFactory;

    BotListV3 botList;

    CreditManagerV3 public creditManager;
    CreditFacadeV3 public creditFacade;
    CreditConfiguratorV3 public creditConfigurator;

    CreditFacadeTestSuite public cft;

    address public underlying;

    IAddressProviderV3 addressProvider;
    IWETH wethToken;

    PoolV3 pool;
    IPriceOracleV2 priceOracle;
    IWithdrawalManagerV3 withdrawalManager;

    CreditConfig creditConfig;

    bool whitelisted;
    bool expirable;

    modifier notExpirableCase() {
        _notExpirable();
        _;
    }

    modifier expirableCase() {
        _expirable();
        _;
    }

    modifier allExpirableCases() {
        uint256 snapshot = vm.snapshot();
        _notExpirable();
        _;
        vm.revertTo(snapshot);

        _expirable();
        _;
    }

    modifier withoutDegenNFT() {
        _withoutDegenNFT();
        _;
    }

    modifier withDegenNFT() {
        _withDegenNFT();
        _;
    }

    modifier allDegenNftCases() {
        uint256 snapshot = vm.snapshot();

        _withoutDegenNFT();
        _;
        vm.revertTo(snapshot);

        _withDegenNFT();
        _;
    }

    function setUp() public {
        _setUp(Tokens.DAI);
    }

    function _setUp(Tokens _underlying) internal {
        _setUp(_underlying, false, false, false, 1);
    }

    function _setUp(
        Tokens _underlying,
        bool withDegenNFT,
        bool withExpiration,
        bool supportQuotas,
        uint8 accountFactoryVer
    ) internal {
        tokenTestSuite = new TokensTestSuite();
        tokenTestSuite.topUpWETH{value: 100 * WAD}();

        CreditConfig creditConfig = new CreditConfig(
            tokenTestSuite,
            _underlying
        );

        cft = new CreditFacadeTestSuite({ _creditConfig: creditConfig,
         _supportQuotas: supportQuotas,
         withDegenNFT: withDegenNFT,
         withExpiration:  withExpiration,
         accountFactoryVer:  accountFactoryVer});

        underlying = tokenTestSuite.addressOf(_underlying);
        creditManager = cft.creditManager();
        creditFacade = cft.creditFacade();
        creditConfigurator = cft.creditConfigurator();

        accountFactory = cft.af();
        botList = cft.botList();

        targetMock = new TargetContractMock();
        adapterMock = new AdapterMock(
            address(creditManager),
            address(targetMock)
        );

        vm.prank(CONFIGURATOR);
        creditConfigurator.allowAdapter(address(adapterMock));

        vm.label(address(adapterMock), "AdapterMock");
        vm.label(address(targetMock), "TargetContractMock");
    }

    ///
    /// HELPERS

    function _withoutDegenNFT() internal {
        whitelisted = false;
    }

    function _withDegenNFT() internal {
        whitelisted = true;
    }

    function _notExpirable() internal {
        expirable = false;
        _deploy();
    }

    function _expirable() internal {
        expirable = true;
        _deploy();
    }

    function _deploy() internal {
        creditConfig = new CreditConfig(tokenTestSuite, Tokens.DAI);

        cft =
        new CreditFacadeTestSuite({ _creditConfig: creditConfig, _supportQuotas: true, withDegenNFT: whitelisted, withExpiration: expirable, accountFactoryVer: 1});

        addressProvider = cft.addressProvider();

        pool = cft.pool();
        withdrawalManager = cft.withdrawalManager();

        creditManager = cft.creditManager();
        creditFacade = cft.creditFacade();

        priceOracle = IPriceOracleV2(creditManager.priceOracle());
        underlying = creditManager.underlying();
    }

    /// @dev Opens credit account for testing management functions
    function _openCreditAccount()
        internal
        returns (uint256 debt, uint256 cumulativeIndexLastUpdate, address creditAccount)
    {
        return cft.openCreditAccount();
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
        uint256 accountAmount = cft.creditAccountAmount();

        tokenTestSuite.mint(underlying, USER, accountAmount);

        vm.startPrank(USER);
        creditAccount = _openCreditAccount(accountAmount, USER, 100, 0);

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
        address weth = tokenTestSuite.addressOf(Tokens.WETH);

        vm.startPrank(tester);
        if (tester.balance > 0) {
            IWETH(weth).deposit{value: tester.balance}();
        }

        IERC20(weth).transfer(address(this), tokenTestSuite.balanceOf(Tokens.WETH, tester));

        vm.stopPrank();
        expectBalance(Tokens.WETH, tester, 0);

        vm.deal(tester, WETH_TEST_AMOUNT);
    }
}
