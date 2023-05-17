// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

/// MOCKS
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {AccountFactoryMock} from "../../mocks/core/AccountFactoryMock.sol";
import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";

import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";
import {CreditManagerV3Harness} from "./CreditManagerV3Harness.sol";
import {CreditManagerV3Harness_USDT} from "./CreditManagerV3Harness_USDT.sol";
import "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// LIBS & TRAITS
import {UNDERLYING_TOKEN_MASK, BitMask} from "../../../libraries/BitMask.sol";
import {CreditLogic} from "../../../libraries/CreditLogic.sol";
import {USDTFees} from "../../../libraries/USDTFees.sol";

/// INTERFACE
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../../interfaces/IAddressProviderV3.sol";
import {ENTERED} from "../../../traits/ReentrancyGuardTrait.sol";
import {ICreditAccount} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditAccount.sol";
import {IAccountFactory} from "../../../interfaces/IAccountFactory.sol";
import {
    ICreditManagerV3,
    ClosureAction,
    CollateralTokenData,
    ManageDebtAction,
    CreditAccountInfo,
    RevocationPair,
    CollateralDebtData,
    CollateralCalcTask,
    ICreditManagerV3Events,
    WITHDRAWAL_FLAG
} from "../../../interfaces/ICreditManagerV3.sol";
import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPriceOracleV2, IPriceOracleV2Ext} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import {IWETHGateway} from "../../../interfaces/IWETHGateway.sol";
import {ClaimAction, IWithdrawalManager} from "../../../interfaces/IWithdrawalManager.sol";

import {IPoolService} from "@gearbox-protocol/core-v2/contracts/interfaces/IPoolService.sol";
import {ERC20FeeMock} from "../../mocks/token/ERC20FeeMock.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// MOCKS
import {PriceOracleMock} from "../../mocks/oracles/PriceOracleMock.sol";
import {PoolMock} from "../../mocks/pool/PoolMock.sol";
import {PoolQuotaKeeperMock} from "../../mocks/pool/PoolQuotaKeeperMock.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";
import {CreditConfig} from "../../config/CreditConfig.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// TESTS
import "../../lib/constants.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";
import {TestHelper} from "../../lib/helper.sol";
import "forge-std/console.sol";

contract CreditManagerV3UnitTest is TestHelper, ICreditManagerV3Events, BalanceHelper {
    using BitMask for uint256;
    using CreditLogic for CollateralDebtData;
    using CreditLogic for CollateralTokenData;
    using USDTFees for uint256;

    IAddressProviderV3 addressProvider;
    IWETH wethToken;

    AccountFactoryMock accountFactory;
    CreditManagerV3Harness creditManager;
    PoolMock poolMock;
    PoolQuotaKeeperMock poolQuotaKeeperMock;

    IPriceOracleV2 priceOracle;
    IWETHGateway wethGateway;
    IWithdrawalManager withdrawalManager;

    address underlying;
    bool supportsQuotas;

    CreditConfig creditConfig;

    // Fee token settings
    bool isFeeToken;
    uint256 tokenFee = 0;
    uint256 maxTokenFee = 0;

    /// @notice deploy credit manager without quotas support
    modifier withoutSupportQuotas() {
        _deployCreditManager(false);
        _;
    }

    /// @notice deploy credit manager with quotas support
    modifier withSupportQuotas() {
        _deployCreditManager(true);
        _;
    }

    /// @notice dexecute test twice with and without quotas support
    modifier allQuotaCases() {
        uint256 snapShot = vm.snapshot();
        _deployCreditManager(false);
        _;
        vm.revertTo(snapShot);
        _deployCreditManager(true);
        _;
    }

    /// @notice execute test twice with normal and fee token as underlying
    /// Should be before quota- modifiers
    modifier withFeeTokenCase() {
        uint256 snapshot = vm.snapshot();
        _setUnderlying({underlyingIsFeeToken: false});
        _;

        vm.revertTo(snapshot);
        _setUnderlying({underlyingIsFeeToken: true});
        // set fee
        _;
    }

    function setUp() public {
        tokenTestSuite = new TokensTestSuite();

        tokenTestSuite.topUpWETH{value: 100 * WAD}();

        underlying = tokenTestSuite.addressOf(Tokens.DAI);

        addressProvider = new AddressProviderV3ACLMock();

        accountFactory = AccountFactoryMock(addressProvider.getAddressOrRevert(AP_ACCOUNT_FACTORY, NO_VERSION_CONTROL));

        addressProvider.setAddress(AP_WETH_TOKEN, tokenTestSuite.addressOf(Tokens.WETH), false);
    }
    ///
    /// HELPERS
    ///

    function _deployCreditManager(bool _supportsQuotas) internal {
        supportsQuotas = _supportsQuotas;
        poolMock = new PoolMock(address(addressProvider), underlying);
        poolMock.setSupportsQuotas(_supportsQuotas);

        if (_supportsQuotas) {
            poolQuotaKeeperMock = new PoolQuotaKeeperMock(address(poolMock), underlying);
        }

        creditManager = (isFeeToken)
            ? new CreditManagerV3Harness_USDT(address(addressProvider), address(poolMock))
            : new CreditManagerV3Harness(address(addressProvider), address(poolMock));
        creditManager.setCreditFacade(address(this));

        creditManager.setFees(
            DEFAULT_FEE_INTEREST,
            DEFAULT_FEE_LIQUIDATION,
            PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM,
            DEFAULT_FEE_LIQUIDATION_EXPIRED,
            PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM_EXPIRED
        );
    }

    function _setUnderlying(bool underlyingIsFeeToken) internal {
        uint256 oneUSDT = 10 ** _decimals(tokenTestSuite.addressOf(Tokens.USDT));

        isFeeToken = underlyingIsFeeToken;
        underlying = tokenTestSuite.addressOf(underlyingIsFeeToken ? Tokens.USDT : Tokens.DAI);

        uint256 _tokenFee = underlyingIsFeeToken ? 30_00 : 0;
        uint256 _maxTokenFee = underlyingIsFeeToken ? 1000000000000 * oneUSDT : 0;

        _setFee(_tokenFee, _maxTokenFee);
    }

    function _setFee(uint256 _tokenFee, uint256 _maxTokenFee) internal {
        tokenFee = _tokenFee;
        maxTokenFee = _maxTokenFee;
        if (isFeeToken) {
            ERC20FeeMock(underlying).setBasisPointsRate(tokenFee);
            ERC20FeeMock(underlying).setMaximumFee(maxTokenFee);
        }
    }

    function _amountWithFee(uint256 amount) internal view returns (uint256) {
        return isFeeToken ? amount.amountUSDTWithFee(tokenFee, maxTokenFee) : amount;
    }

    function _amountMinusFee(uint256 amount) internal view returns (uint256) {
        return isFeeToken ? amount.amountUSDTMinusFee(tokenFee, maxTokenFee) : amount;
    }

    function _decimals(address token) internal returns (uint8) {
        return IERC20Metadata(token).decimals();
    }

    ///
    ///
    ///  TESTS
    ///
    ///
    /// @dev U:[CM-1]: credit manager reverts if were called non-creditFacade
    function test_U_CM_01_constructor_sets_correct_values() public allQuotaCases {
        string memory caseName = supportsQuotas ? "supportsQuotas = true" : "supportsQuotas = false";

        assertEq(
            address(creditManager.poolService()), address(poolMock), _testCaseErr(caseName, "Incorrect poolService")
        );

        assertEq(address(creditManager.pool()), address(poolMock), _testCaseErr(caseName, "Incorrect pool"));

        assertEq(
            creditManager.underlying(),
            tokenTestSuite.addressOf(Tokens.DAI),
            _testCaseErr(caseName, "Incorrect underlying")
        );

        (address token, uint16 lt) = creditManager.collateralTokensByMask(UNDERLYING_TOKEN_MASK);

        assertEq(token, tokenTestSuite.addressOf(Tokens.DAI), _testCaseErr(caseName, "Incorrect underlying"));

        assertEq(
            creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI)),
            1,
            _testCaseErr(caseName, "Incorrect token mask for underlying token")
        );

        assertEq(lt, 0, _testCaseErr(caseName, "Incorrect LT for underlying"));

        assertEq(creditManager.supportsQuotas(), supportsQuotas, _testCaseErr(caseName, "Incorrect supportsQuotas"));

        assertEq(
            creditManager.weth(),
            addressProvider.getAddressOrRevert(AP_WETH_TOKEN, 0),
            _testCaseErr(caseName, "Incorrect WETH token")
        );

        assertEq(
            address(creditManager.wethGateway()),
            addressProvider.getAddressOrRevert(AP_WETH_GATEWAY, 3_00),
            _testCaseErr(caseName, "Incorrect WETH Gateway")
        );

        assertEq(
            address(creditManager.priceOracle()),
            addressProvider.getAddressOrRevert(AP_PRICE_ORACLE, 2),
            _testCaseErr(caseName, "Incorrect Price oracle")
        );

        assertEq(
            address(creditManager.accountFactory()),
            address(accountFactory),
            _testCaseErr(caseName, "Incorrect account factory")
        );

        assertEq(
            address(creditManager.creditConfigurator()),
            address(this),
            _testCaseErr(caseName, "Incorrect creditConfigurator")
        );
    }

    /// @dev U:[CM-2]:credit account management functions revert if were called non-creditFacade
    function test_U_CM_02_credit_account_management_functions_revert_if_not_called_by_creditFacadeCall()
        public
        withoutSupportQuotas
    {
        vm.startPrank(USER);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.openCreditAccount(200000, address(this));

        CollateralDebtData memory collateralDebtData;

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.closeCreditAccount({
            creditAccount: DUMB_ADDRESS,
            closureAction: ClosureAction.LIQUIDATE_ACCOUNT,
            collateralDebtData: collateralDebtData,
            payer: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokensMask: 0,
            convertToETH: false
        });

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.manageDebt(DUMB_ADDRESS, 100, 0, ManageDebtAction.INCREASE_DEBT);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.addCollateral(DUMB_ADDRESS, DUMB_ADDRESS, DUMB_ADDRESS, 100);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.transferAccountOwnership(DUMB_ADDRESS, DUMB_ADDRESS);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.fullCollateralCheck(DUMB_ADDRESS, 0, new uint256[](0), 1);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.updateQuota(DUMB_ADDRESS, DUMB_ADDRESS, 0);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.scheduleWithdrawal(DUMB_ADDRESS, DUMB_ADDRESS, 0);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.claimWithdrawals(DUMB_ADDRESS, DUMB_ADDRESS, ClaimAction.CLAIM);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.revokeAdapterAllowances(DUMB_ADDRESS, new RevocationPair[](0));

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.setCreditAccountForExternalCall(DUMB_ADDRESS);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.setFlagFor(DUMB_ADDRESS, 1, true);
        vm.stopPrank();
    }

    /// @dev U:[CM-3]:credit account adapter functions revert if were called non-adapters
    function test_U_CM_03_credit_account_adapter_functions_revert_if_not_called_by_adapters()
        public
        withoutSupportQuotas
    {
        vm.startPrank(USER);

        vm.expectRevert(CallerNotAdapterException.selector);
        creditManager.approveCreditAccount(DUMB_ADDRESS, 100);

        vm.expectRevert(CallerNotAdapterException.selector);
        creditManager.executeOrder(bytes("0"));

        vm.stopPrank();
    }

    /// @dev U:[CM-4]: credit account configuration functions revert if were called non-configurator
    function test_U_CM_04_credit_account_configurator_functions_revert_if_not_called_by_creditConfigurator()
        public
        withoutSupportQuotas
    {
        vm.startPrank(USER);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.addToken(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setFees(0, 0, 0, 0, 0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setCollateralTokenData(DUMB_ADDRESS, 0, 0, 0, 0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setQuotedMask(0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setMaxEnabledTokens(255);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setContractAllowance(DUMB_ADDRESS, DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setCreditFacade(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setPriceOracle(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setCreditConfigurator(DUMB_ADDRESS);

        vm.stopPrank();
    }

    /// @dev U:[CM-5]: non-reentrant functions revert if called in reentrancy
    function test_U_CM_05_non_reentrant_functions_revert_if_called_in_reentrancy() public withoutSupportQuotas {
        creditManager.setReentrancy(ENTERED);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.openCreditAccount(200000, address(this));

        CollateralDebtData memory collateralDebtData;

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.closeCreditAccount({
            creditAccount: DUMB_ADDRESS,
            closureAction: ClosureAction.LIQUIDATE_ACCOUNT,
            collateralDebtData: collateralDebtData,
            payer: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokensMask: 0,
            convertToETH: false
        });

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.manageDebt(DUMB_ADDRESS, 100, 0, ManageDebtAction.INCREASE_DEBT);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.addCollateral(DUMB_ADDRESS, DUMB_ADDRESS, DUMB_ADDRESS, 100);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.transferAccountOwnership(DUMB_ADDRESS, DUMB_ADDRESS);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.fullCollateralCheck(DUMB_ADDRESS, 0, new uint256[](0), 1);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.updateQuota(DUMB_ADDRESS, DUMB_ADDRESS, 0);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.scheduleWithdrawal(DUMB_ADDRESS, DUMB_ADDRESS, 0);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.claimWithdrawals(DUMB_ADDRESS, DUMB_ADDRESS, ClaimAction.CLAIM);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.revokeAdapterAllowances(DUMB_ADDRESS, new RevocationPair[](0));

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.setCreditAccountForExternalCall(DUMB_ADDRESS);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.setFlagFor(DUMB_ADDRESS, 1, true);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.approveCreditAccount(DUMB_ADDRESS, 100);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.executeOrder(bytes("0"));
    }

    /// @dev U:[CM-6]: open credit account works as expected
    function test_U_CM_06_non_reentrant_functions_revert_if_called_in_reentrancy() public allQuotaCases {
        string memory caseName = supportsQuotas ? "supportsQuotas = true" : "supportsQuotas = false";

        uint256 cumulativeIndexNow = RAY * 5;
        poolMock.setCumulative_RAY(cumulativeIndexNow);

        tokenTestSuite.mint(Tokens.DAI, address(poolMock), DAI_ACCOUNT_AMOUNT);

        assertEq(
            creditManager.creditAccounts().length, 0, _testCaseErr(caseName, "SETUP: incorrect creditAccounts() length")
        );

        uint256 cumulativeQuotaInterestBefore = 123412321;
        uint256 enabledTokensMaskBefore = 231423;

        creditManager.setCreditAccountInfoMap({
            creditAccount: accountFactory.usedAccount(),
            debt: 12039120,
            cumulativeIndexLastUpdate: 23e3,
            cumulativeQuotaInterest: cumulativeQuotaInterestBefore,
            enabledTokensMask: enabledTokensMaskBefore,
            flags: 34343,
            borrower: address(0)
        });

        //        vm.expectCall(address(accountFactory), abi.encodeCall(IAccountFactory.takeCreditAccount, (0, 0)));
        address creditAccount = creditManager.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER);
        assertEq(
            address(creditAccount),
            accountFactory.usedAccount(),
            _testCaseErr(caseName, "Incorrect credit account returned")
        );

        (
            uint256 debt,
            uint256 cumulativeIndexLastUpdate,
            uint256 cumulativeQuotaInterest,
            uint256 enabledTokensMask,
            uint16 flags,
            address borrower
        ) = creditManager.creditAccountInfo(creditAccount);

        assertEq(debt, DAI_ACCOUNT_AMOUNT, _testCaseErr(caseName, "Incorrect debt"));
        assertEq(
            cumulativeIndexLastUpdate, cumulativeIndexNow, _testCaseErr(caseName, "Incorrect cumulativeIndexLastUpdate")
        );
        assertEq(
            cumulativeQuotaInterest,
            supportsQuotas ? 1 : cumulativeQuotaInterestBefore,
            _testCaseErr(caseName, "Incorrect cumulativeQuotaInterest")
        );
        assertEq(enabledTokensMask, enabledTokensMaskBefore, _testCaseErr(caseName, "Incorrect enabledTokensMask"));
        assertEq(flags, 0, _testCaseErr(caseName, "Incorrect flags"));
        assertEq(borrower, USER, _testCaseErr(caseName, "Incorrect borrower"));

        assertEq(poolMock.lendAmount(), DAI_ACCOUNT_AMOUNT, _testCaseErr(caseName, "Incorrect amount was borrowed"));
        assertEq(poolMock.lendAccount(), creditAccount, _testCaseErr(caseName, "Incorrect amount was borrowed"));

        assertEq(creditManager.creditAccounts().length, 1, _testCaseErr(caseName, "incorrect creditAccounts() length"));
        assertEq(
            creditManager.creditAccounts()[0],
            creditAccount,
            _testCaseErr(caseName, "incorrect creditAccounts()[0] value")
        );

        expectBalance(
            Tokens.DAI, creditAccount, DAI_ACCOUNT_AMOUNT, _testCaseErr(caseName, "incorrect balance on creditAccount")
        );
    }

    /// @dev U:[CM-7]: close credit account reverts if account not exists
    function test_U_CM_07_close_credit_account_reverts_if_account_not_exists() public allQuotaCases {
        CollateralDebtData memory collateralDebtData;

        vm.expectRevert(CreditAccountNotExistsException.selector);
        creditManager.closeCreditAccount({
            creditAccount: USER,
            closureAction: ClosureAction.CLOSE_ACCOUNT,
            collateralDebtData: collateralDebtData,
            payer: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokensMask: 0,
            convertToETH: false
        });
    }

    struct CloseCreditAccountTestCase {
        string name;
        ClosureAction closureAction;
        uint256 debt;
        uint256 accruedInterest;
        uint256 accruedFees;
        uint256 totalValue;
        uint256 enabledTokensMask;
        address[] quotedTokens;
        uint256 underlyingBalance;
        // EXPECTED
        bool expectedSetLimitsToZero;
    }

    /// @dev U:[CM-8]: close credit account works as expected
    function test_U_CM_08_close_credit_correctly_makes_payments() public withFeeTokenCase withSupportQuotas {
        uint256 debt = DAI_ACCOUNT_AMOUNT;

        vm.assume(debt > 1_000);
        vm.assume(debt < 10 ** 10 * (10 ** _decimals(underlying)));

        if (isFeeToken) {
            _setFee(debt % 50_00, debt / (debt % 49 + 1));
        }

        address[] memory hasQuotedTokens = new address[](2);

        hasQuotedTokens[0] = tokenTestSuite.addressOf(Tokens.USDC);
        hasQuotedTokens[1] = tokenTestSuite.addressOf(Tokens.LINK);

        CloseCreditAccountTestCase[7] memory cases = [
            CloseCreditAccountTestCase({
                name: "Closure case for account with no pay from payer",
                closureAction: ClosureAction.CLOSE_ACCOUNT,
                debt: debt,
                accruedInterest: 0,
                accruedFees: 0,
                totalValue: 0,
                enabledTokensMask: UNDERLYING_TOKEN_MASK,
                quotedTokens: hasQuotedTokens,
                underlyingBalance: debt + 1,
                // EXPECTED
                expectedSetLimitsToZero: false
            }),
            CloseCreditAccountTestCase({
                name: "Closure case for account with with charging payer",
                closureAction: ClosureAction.CLOSE_ACCOUNT,
                debt: debt,
                accruedInterest: 0,
                accruedFees: 0,
                totalValue: 0,
                enabledTokensMask: UNDERLYING_TOKEN_MASK,
                quotedTokens: hasQuotedTokens,
                underlyingBalance: debt / 2,
                // EXPECTED
                expectedSetLimitsToZero: false
            }),
            CloseCreditAccountTestCase({
                name: "Liquidate account with profit",
                closureAction: ClosureAction.LIQUIDATE_ACCOUNT,
                debt: debt,
                accruedInterest: 0,
                accruedFees: 0,
                totalValue: debt * 2,
                enabledTokensMask: UNDERLYING_TOKEN_MASK,
                quotedTokens: hasQuotedTokens,
                underlyingBalance: debt * 2,
                // EXPECTED
                expectedSetLimitsToZero: false
            }),
            CloseCreditAccountTestCase({
                name: "Liquidate account with profit, liquidator pays, with quotedTokens",
                closureAction: ClosureAction.LIQUIDATE_ACCOUNT,
                debt: debt,
                accruedInterest: 0,
                accruedFees: 0,
                totalValue: _amountWithFee(debt * 100 / 95),
                enabledTokensMask: UNDERLYING_TOKEN_MASK,
                quotedTokens: hasQuotedTokens,
                underlyingBalance: 0,
                // EXPECTED
                expectedSetLimitsToZero: false
            }),
            CloseCreditAccountTestCase({
                name: "Liquidate account with loss, no quoted tokens",
                closureAction: ClosureAction.LIQUIDATE_ACCOUNT,
                debt: debt,
                accruedInterest: 0,
                accruedFees: 0,
                totalValue: debt / 2,
                enabledTokensMask: UNDERLYING_TOKEN_MASK,
                quotedTokens: new address[](0),
                underlyingBalance: debt / 2,
                // EXPECTED
                expectedSetLimitsToZero: false
            }),
            CloseCreditAccountTestCase({
                name: "Liquidate account with loss, with quotaTokens",
                closureAction: ClosureAction.LIQUIDATE_ACCOUNT,
                debt: debt,
                accruedInterest: 0,
                accruedFees: 0,
                totalValue: debt / 2,
                enabledTokensMask: UNDERLYING_TOKEN_MASK,
                quotedTokens: hasQuotedTokens,
                underlyingBalance: debt / 2,
                // EXPECTED
                expectedSetLimitsToZero: true
            }),
            CloseCreditAccountTestCase({
                name: "Liquidate account with loss, with quotaTokens, Liquidator pays",
                closureAction: ClosureAction.LIQUIDATE_ACCOUNT,
                debt: debt,
                accruedInterest: 0,
                accruedFees: 0,
                totalValue: debt / 2,
                enabledTokensMask: UNDERLYING_TOKEN_MASK,
                quotedTokens: hasQuotedTokens,
                underlyingBalance: 0,
                // EXPECTED
                expectedSetLimitsToZero: true
            })
        ];

        address creditAccount = accountFactory.usedAccount();

        creditManager.setBorrower(creditAccount, USER);

        tokenTestSuite.mint({token: underlying, to: LIQUIDATOR, amount: _amountWithFee(debt * 2)});

        vm.prank(LIQUIDATOR);
        IERC20(underlying).approve({spender: address(creditManager), amount: type(uint256).max});

        assertEq(accountFactory.returnedAccount(), address(0), "SETUP: returnAccount is already set");

        for (uint256 i; i < cases.length; ++i) {
            uint256 snapshot = vm.snapshot();

            CloseCreditAccountTestCase memory _case = cases[i];

            string memory caseName = isFeeToken ? string.concat("Fee token: ", _case.name) : _case.name;

            CollateralDebtData memory collateralDebtData;
            collateralDebtData._poolQuotaKeeper = address(poolQuotaKeeperMock);
            collateralDebtData.debt = _case.debt;
            collateralDebtData.accruedInterest = _case.accruedInterest;
            collateralDebtData.accruedFees = _case.accruedFees;
            collateralDebtData.totalValue = _case.totalValue;
            collateralDebtData.enabledTokensMask = _case.enabledTokensMask;
            collateralDebtData.quotedTokens = _case.quotedTokens;

            /// @notice We do not test math correctness here, it could be found in lib test
            /// We assume here, that lib is tested and provide correct results, the test checks
            /// that te contract sends amout to correct addresses and implement another logic is need
            uint256 amountToPool;
            uint256 profit;
            uint256 expectedRemainingFunds;
            uint256 expectedLoss;

            if (_case.closureAction == ClosureAction.CLOSE_ACCOUNT) {
                (amountToPool, profit) = collateralDebtData.calcClosePayments({amountWithFeeFn: _amountWithFee});
            } else {
                (amountToPool, expectedRemainingFunds, profit, expectedLoss) = collateralDebtData
                    .calcLiquidationPayments({
                    liquidationDiscount: _case.closureAction == ClosureAction.LIQUIDATE_ACCOUNT
                        ? PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM
                        : PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM_EXPIRED,
                    feeLiquidation: _case.closureAction == ClosureAction.LIQUIDATE_ACCOUNT
                        ? DEFAULT_FEE_LIQUIDATION
                        : DEFAULT_FEE_LIQUIDATION_EXPIRED,
                    amountWithFeeFn: _amountWithFee,
                    amountMinusFeeFn: _amountMinusFee
                });
            }

            tokenTestSuite.mint(underlying, creditAccount, _case.underlyingBalance);

            startTokenTrackingSession(caseName);

            expectTokenTransfer({
                reason: "debt transfer to pool",
                token: underlying,
                from: creditAccount,
                to: address(poolMock),
                amount: _amountMinusFee(amountToPool)
            });

            if (_case.underlyingBalance < amountToPool + expectedRemainingFunds + 1) {
                expectTokenTransfer({
                    reason: "payer to creditAccount",
                    token: underlying,
                    from: LIQUIDATOR,
                    to: creditAccount,
                    amount: amountToPool + expectedRemainingFunds - _case.underlyingBalance + 1
                });
            } else {
                uint256 amount = _case.underlyingBalance - amountToPool - expectedRemainingFunds - 1;
                if (amount > 1) {
                    expectTokenTransfer({
                        reason: "transfer to caller",
                        token: underlying,
                        from: creditAccount,
                        to: FRIEND,
                        amount: amount
                    });
                }
            }

            if (expectedRemainingFunds > 1) {
                expectTokenTransfer({
                    reason: "remaning funds to borrower",
                    token: underlying,
                    from: creditAccount,
                    to: USER,
                    amount: _amountMinusFee(expectedRemainingFunds)
                });
            }

            uint256 poolBalanceBefore = IERC20(underlying).balanceOf(address(poolMock));

            ///
            /// CLOSE CREDIT ACC
            ///
            (uint256 remainingFunds, uint256 loss) = creditManager.closeCreditAccount({
                creditAccount: creditAccount,
                closureAction: _case.closureAction,
                collateralDebtData: collateralDebtData,
                payer: LIQUIDATOR,
                to: FRIEND,
                skipTokensMask: 0,
                convertToETH: false
            });

            assertEq(remainingFunds, expectedRemainingFunds, _testCaseErr(caseName, "incorrect remainingFunds"));

            assertEq(loss, expectedLoss, _testCaseErr(caseName, "incorrect loss"));

            console.log("LOSS", loss);

            checkTokenTransfers({debug: false});

            /// @notice Pool balance invariant keeps correct transfer to pool during closure

            expectBalance({
                token: underlying,
                holder: address(poolMock),
                expectedBalance: poolBalanceBefore + collateralDebtData.debt + collateralDebtData.accruedInterest + profit
                    - loss,
                reason: "Pool balance invariant"
            });
            // assertEq(
            //     _case.expectedTransferFromPayer,
            //     payerBalanceBefore - tokenTestSuite.balanceOf({token: underlying, holder: LIQUIDATOR}),
            //     _testCaseErr(caseName, "incorrect expectedTransferFromPayer")
            // );

            (,,,,, address borrower) = creditManager.creditAccountInfo(creditAccount);
            assertEq(borrower, address(0), "Borrowers wasn't cleared");

            assertEq(
                poolQuotaKeeperMock.call_creditAccount(),
                _case.quotedTokens.length == 0 ? address(0) : creditAccount,
                "Incorrect creditAccount call to PQK"
            );

            assertTrue(
                poolQuotaKeeperMock.call_setLimitsToZero() == _case.expectedSetLimitsToZero, "Incorrect setLimitsToZero"
            );

            assertEq(accountFactory.returnedAccount(), creditAccount, "returnAccount wasn't called");

            assertEq(
                creditManager.creditAccounts().length, 0, _testCaseErr(caseName, "incorrect creditAccounts() length")
            );

            vm.revertTo(snapshot);
        }
    }
}
