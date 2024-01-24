// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

/// MOCKS
import "../../../interfaces/IAddressProviderV3.sol";
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {AccountFactoryMock} from "../../mocks/core/AccountFactoryMock.sol";

import {CreditManagerV3Harness} from "./CreditManagerV3Harness.sol";
import "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// LIBS & TRAITS
import {UNDERLYING_TOKEN_MASK, BitMask} from "../../../libraries/BitMask.sol";
import {CreditLogic} from "../../../libraries/CreditLogic.sol";
import {CollateralLogic} from "../../../libraries/CollateralLogic.sol";
import {USDTFees} from "../../../libraries/USDTFees.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/// INTERFACE

import {ENTERED} from "../../../traits/ReentrancyGuardTrait.sol";
import {ICreditAccountBase} from "../../../interfaces/ICreditAccountV3.sol";
import {
    ICreditManagerV3,
    CollateralTokenData,
    ManageDebtAction,
    CreditAccountInfo,
    RevocationPair,
    CollateralDebtData,
    CollateralCalcTask,
    ICreditManagerV3Events
} from "../../../interfaces/ICreditManagerV3.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPoolQuotaKeeperV3} from "../../../interfaces/IPoolQuotaKeeperV3.sol";

// EXCEPTIONS

// MOCKS
import {PriceOracleMock} from "../../mocks/oracles/PriceOracleMock.sol";
import {PoolMock} from "../../mocks/pool/PoolMock.sol";
import {PoolQuotaKeeperMock} from "../../mocks/pool/PoolQuotaKeeperMock.sol";
import {ERC20FeeMock} from "../../mocks/token/ERC20FeeMock.sol";
import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";
import {CreditAccountMock, CreditAccountMockEvents} from "../../mocks/credit/CreditAccountMock.sol";
// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import {MockCreditConfig} from "../../config/MockCreditConfig.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// TESTS
import "../../lib/constants.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";
import {TestHelper, Vars, VarU256} from "../../lib/helper.sol";

import "forge-std/console.sol";

uint16 constant LT_UNDERLYING = uint16(PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM - DEFAULT_FEE_LIQUIDATION);

contract CreditManagerV3UnitTest is TestHelper, ICreditManagerV3Events, BalanceHelper, CreditAccountMockEvents {
    using BitMask for uint256;
    using CreditLogic for CollateralTokenData;
    using CreditLogic for CollateralDebtData;
    using CollateralLogic for CollateralDebtData;
    using USDTFees for uint256;
    using Vars for VarU256;

    string constant name = "Test Credit Manager";

    IAddressProviderV3 addressProvider;

    AccountFactoryMock accountFactory;
    CreditManagerV3Harness creditManager;
    PoolMock poolMock;
    PoolQuotaKeeperMock poolQuotaKeeperMock;

    PriceOracleMock priceOracleMock;

    address underlying;

    MockCreditConfig creditConfig;

    // Fee token settings
    bool isFeeToken;
    uint256 tokenFee = 0;
    uint256 maxTokenFee = 0;

    /// @notice deploys credit manager without quotas support
    modifier creditManagerTest() {
        _deployCreditManager();
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
        _;
    }

    function setUp() public {
        tokenTestSuite = new TokensTestSuite();
        tokenTestSuite.topUpWETH{value: 100 * WAD}();

        underlying = tokenTestSuite.addressOf(Tokens.DAI);

        addressProvider = new AddressProviderV3ACLMock();

        accountFactory = AccountFactoryMock(addressProvider.getAddressOrRevert(AP_ACCOUNT_FACTORY, NO_VERSION_CONTROL));

        priceOracleMock = PriceOracleMock(addressProvider.getAddressOrRevert(AP_PRICE_ORACLE, 3_00));

        /// Inits all state
        isFeeToken = false;
        tokenFee = 0;
        maxTokenFee = 0;
    }

    ///
    /// HELPERS
    ///

    function _deployCreditManager() internal {
        poolMock = new PoolMock(address(addressProvider), underlying);

        poolQuotaKeeperMock = new PoolQuotaKeeperMock(address(poolMock), underlying);
        poolMock.setPoolQuotaKeeper(address(poolQuotaKeeperMock));

        creditManager = new CreditManagerV3Harness(address(addressProvider), address(poolMock), name, isFeeToken);
        creditManager.setCreditFacade(address(this));

        creditManager.setFees(
            DEFAULT_FEE_INTEREST,
            DEFAULT_FEE_LIQUIDATION,
            PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM,
            DEFAULT_FEE_LIQUIDATION_EXPIRED,
            PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM_EXPIRED
        );

        creditManager.setCollateralTokenData({
            token: underlying,
            ltInitial: LT_UNDERLYING,
            ltFinal: LT_UNDERLYING,
            timestampRampStart: type(uint40).max,
            rampDuration: 0
        });

        creditManager.setCreditConfigurator(CONFIGURATOR);
    }

    function _setUnderlying(bool underlyingIsFeeToken) internal {
        uint256 oneUSDT = 10 ** _decimals(tokenTestSuite.addressOf(Tokens.USDT));

        isFeeToken = underlyingIsFeeToken;
        underlying = tokenTestSuite.addressOf(underlyingIsFeeToken ? Tokens.USDT : Tokens.DAI);

        uint256 _tokenFee = underlyingIsFeeToken ? 20 : 0;
        uint256 _maxTokenFee = underlyingIsFeeToken ? 50 * oneUSDT : 0;

        _setFee(_tokenFee, _maxTokenFee);

        caseName = string.concat(caseName, " [fee token = ", underlyingIsFeeToken ? " true ]" : " false ]");
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

    function _decimals(address token) internal view returns (uint8) {
        return IERC20Metadata(token).decimals();
    }

    function _addToken(Tokens token, uint16 lt) internal {
        _addToken(tokenTestSuite.addressOf(token), lt);
    }

    function _addToken(address token, uint16 lt) internal {
        vm.prank(CONFIGURATOR);
        creditManager.addToken({token: token});

        vm.prank(CONFIGURATOR);
        creditManager.setCollateralTokenData({
            token: address(token),
            ltInitial: lt,
            ltFinal: lt,
            timestampRampStart: type(uint40).max,
            rampDuration: 0
        });
    }

    function _addQuotedToken(address token, uint16 lt, uint96 quoted, uint128 outstandingInterest) internal {
        _addToken({token: token, lt: lt});
        poolQuotaKeeperMock.setQuotaAndOutstandingInterest({
            token: token,
            quoted: quoted,
            outstandingInterest: outstandingInterest
        });
    }

    function _addQuotedToken(Tokens token, uint16 lt, uint96 quoted, uint128 outstandingInterest) internal {
        _addQuotedToken({
            token: tokenTestSuite.addressOf(token),
            lt: lt,
            quoted: quoted,
            outstandingInterest: outstandingInterest
        });
    }

    function _addTokensBatch(address creditAccount, uint8 numberOfTokens, uint256 balance) internal {
        for (uint8 i = 0; i < numberOfTokens; ++i) {
            ERC20Mock t = new ERC20Mock(
                string.concat("new token ", Strings.toString(i + 1)), string.concat("NT-", Strings.toString(i + 1)), 18
            );

            _addToken({token: address(t), lt: 80_00});

            t.mint(creditAccount, balance * ((i + 2) % 5));

            /// sets price between $0.01 and $60K
            uint256 randomPrice =
                (uint256(keccak256(abi.encode(numberOfTokens, i, balance))) % (6000000 - 1) + 1) * 10 ** 6;
            priceOracleMock.setPrice(address(t), randomPrice);
        }
    }

    function _getTokenMaskOrRevert(Tokens token) internal view returns (uint256) {
        return creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(token));
    }

    function _taskName(CollateralCalcTask task) internal pure returns (string memory) {
        if (task == CollateralCalcTask.GENERIC_PARAMS) return "GENERIC_PARAMS";

        if (task == CollateralCalcTask.DEBT_ONLY) return "DEBT_ONLY";

        if (task == CollateralCalcTask.DEBT_COLLATERAL) {
            return "DEBT_COLLATERAL";
        }

        if (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY) return "FULL_COLLATERAL_CHECK_LAZY";

        revert("UNKNOWN TASK");
    }

    function _creditAccountInfo(address creditAccount) internal view returns (CreditAccountInfo memory) {
        (
            uint256 debt,
            uint256 cumulativeIndexLastUpdate,
            uint128 cumulativeQuotaInterest,
            uint128 quotaFees,
            uint256 enabledTokensMask,
            uint16 flags,
            uint64 lastDebtUpdate,
            address borrower
        ) = creditManager.creditAccountInfo(creditAccount);
        return CreditAccountInfo(
            debt,
            cumulativeIndexLastUpdate,
            cumulativeQuotaInterest,
            quotaFees,
            enabledTokensMask,
            flags,
            lastDebtUpdate,
            borrower
        );
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev U:[CM-1]: credit manager reverts if were called non-creditFacade
    function test_U_CM_01_constructor_sets_correct_values() public creditManagerTest {
        assertEq(address(creditManager.pool()), address(poolMock), _testCaseErr("Incorrect pool"));

        assertEq(creditManager.underlying(), tokenTestSuite.addressOf(Tokens.DAI), _testCaseErr("Incorrect underlying"));

        (address token,) = creditManager.collateralTokenByMask(UNDERLYING_TOKEN_MASK);

        assertEq(token, tokenTestSuite.addressOf(Tokens.DAI), _testCaseErr("Incorrect underlying"));

        assertEq(
            creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI)),
            1,
            _testCaseErr("Incorrect token mask for underlying token")
        );

        // assertEq(lt, 0, _testCaseErr("Incorrect LT for underlying"));

        assertEq(
            address(creditManager.priceOracle()),
            addressProvider.getAddressOrRevert(AP_PRICE_ORACLE, 3_00),
            _testCaseErr("Incorrect Price oracle")
        );

        assertEq(
            address(creditManager.accountFactory()), address(accountFactory), _testCaseErr("Incorrect account factory")
        );

        assertEq(
            address(creditManager.creditConfigurator()),
            address(CONFIGURATOR),
            _testCaseErr("Incorrect creditConfigurator")
        );

        assertEq(creditManager.name(), name, _testCaseErr("Incorrect name"));
    }

    //
    //
    // MODIFIERS
    //
    //

    /// @dev U:[CM-2]:credit account management functions revert if were called non-creditFacade
    function test_U_CM_02_credit_account_management_functions_revert_if_not_called_by_creditFacadeCall()
        public
        creditManagerTest
    {
        vm.startPrank(USER);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.openCreditAccount(address(this));

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.closeCreditAccount({creditAccount: DUMB_ADDRESS});

        CollateralDebtData memory collateralDebtData;
        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.liquidateCreditAccount({
            creditAccount: DUMB_ADDRESS,
            collateralDebtData: collateralDebtData,
            to: DUMB_ADDRESS,
            isExpired: false
        });

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.manageDebt(DUMB_ADDRESS, 100, 0, ManageDebtAction.INCREASE_DEBT);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.addCollateral(DUMB_ADDRESS, DUMB_ADDRESS, DUMB_ADDRESS, 100);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.fullCollateralCheck(DUMB_ADDRESS, 0, new uint256[](0), 1, false);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.updateQuota(DUMB_ADDRESS, DUMB_ADDRESS, 0, 0, 0);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.withdrawCollateral(DUMB_ADDRESS, DUMB_ADDRESS, 0, USER);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.revokeAdapterAllowances(DUMB_ADDRESS, new RevocationPair[](0));

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.setActiveCreditAccount(DUMB_ADDRESS);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.setFlagFor(DUMB_ADDRESS, 1, true);
        vm.stopPrank();
    }

    /// @dev U:[CM-3]:credit account adapter functions revert if were called non-adapters
    function test_U_CM_03_credit_account_adapter_functions_revert_if_not_called_by_adapters()
        public
        creditManagerTest
    {
        vm.startPrank(USER);

        vm.expectRevert(CallerNotAdapterException.selector);
        creditManager.approveCreditAccount(DUMB_ADDRESS, 100);

        vm.expectRevert(CallerNotAdapterException.selector);
        creditManager.execute(bytes("0"));

        vm.stopPrank();
    }

    /// @dev U:[CM-4]: credit account configuration functions revert if were called non-configurator
    function test_U_CM_04_credit_account_configurator_functions_revert_if_not_called_by_creditConfigurator()
        public
        creditManagerTest
    {
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
    }

    /// @dev U:[CM-5]: non-reentrant functions revert if called in reentrancy
    function test_U_CM_05_non_reentrant_functions_revert_if_called_in_reentrancy() public creditManagerTest {
        creditManager.setReentrancy(ENTERED);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.openCreditAccount(address(this));

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.closeCreditAccount({creditAccount: DUMB_ADDRESS});

        CollateralDebtData memory collateralDebtData;
        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.liquidateCreditAccount({
            creditAccount: DUMB_ADDRESS,
            collateralDebtData: collateralDebtData,
            to: DUMB_ADDRESS,
            isExpired: false
        });

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.manageDebt(DUMB_ADDRESS, 100, 0, ManageDebtAction.INCREASE_DEBT);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.addCollateral(DUMB_ADDRESS, DUMB_ADDRESS, DUMB_ADDRESS, 100);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.fullCollateralCheck(DUMB_ADDRESS, 0, new uint256[](0), 1, false);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.updateQuota(DUMB_ADDRESS, DUMB_ADDRESS, 0, 0, 0);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.withdrawCollateral(DUMB_ADDRESS, DUMB_ADDRESS, 0, USER);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.revokeAdapterAllowances(DUMB_ADDRESS, new RevocationPair[](0));

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.setActiveCreditAccount(DUMB_ADDRESS);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.setFlagFor(DUMB_ADDRESS, 1, true);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.approveCreditAccount(DUMB_ADDRESS, 100);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditManager.execute(bytes("0"));
    }

    //
    //
    // OPEN CREDIT ACCOUNT
    //
    //

    /// @dev U:[CM-6]: open credit account works as expected
    function test_U_CM_06_open_credit_account_works_as_expected() public creditManagerTest {
        assertEq(creditManager.creditAccounts().length, 0, _testCaseErr("SETUP: incorrect creditAccounts() length"));

        address expectedAccount = accountFactory.usedAccount();

        creditManager.setCreditAccountInfoMap({
            creditAccount: expectedAccount,
            debt: 0,
            cumulativeIndexLastUpdate: 0,
            cumulativeQuotaInterest: 12121,
            quotaFees: 23232,
            enabledTokensMask: 0,
            flags: 34343,
            borrower: address(0)
        });
        creditManager.setLastDebtUpdate(expectedAccount, 123);

        vm.expectCall(address(accountFactory), abi.encodeCall(accountFactory.takeCreditAccount, (0, 0)));
        address creditAccount = creditManager.openCreditAccount(USER);

        assertEq(creditAccount, expectedAccount, _testCaseErr("Incorrect credit account returned"));

        (,, uint128 cumulativeQuotaInterest, uint128 quotaFees,, uint16 flags, uint64 lastDebtUpdate, address borrower)
        = creditManager.creditAccountInfo(creditAccount);

        assertEq(cumulativeQuotaInterest, 1, _testCaseErr("Incorrect cumulativeQuotaInterest"));
        assertEq(quotaFees, 0, _testCaseErr("Incorrect quotaFees"));
        assertEq(lastDebtUpdate, 0, _testCaseErr("Incorrect lastDebtUpdate"));
        assertEq(flags, 0, _testCaseErr("Incorrect flags"));
        assertEq(borrower, USER, _testCaseErr("Incorrect borrower"));

        assertEq(creditManager.creditAccountsLen(), 1, _testCaseErr("Incorerct creditAccounts length"));
        assertEq(creditManager.creditAccounts()[0], creditAccount, _testCaseErr("Incorrect creditAccounts[0] value"));
    }

    //
    //
    // CLOSE CREDIT ACCOUNT
    //
    //

    /// @dev U:[CM-7]: close credit account works as expected
    function test_U_CM_07_close_credit_account_works_as_expected() public creditManagerTest {
        address creditAccount = DUMB_ADDRESS;

        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: 123,
            cumulativeIndexLastUpdate: 0,
            cumulativeQuotaInterest: 0,
            quotaFees: 0,
            enabledTokensMask: 0,
            flags: 0,
            borrower: address(0)
        });

        vm.expectRevert(CloseAccountWithNonZeroDebtException.selector);
        creditManager.closeCreditAccount(creditAccount);

        creditManager.addToCAList(creditAccount);
        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: 0,
            cumulativeIndexLastUpdate: 0,
            cumulativeQuotaInterest: 0,
            quotaFees: 0,
            enabledTokensMask: 0,
            flags: 123,
            borrower: address(0)
        });

        vm.expectCall(address(accountFactory), abi.encodeCall(accountFactory.returnCreditAccount, (creditAccount)));
        creditManager.closeCreditAccount(creditAccount);

        (,,,, uint256 enabledTokensMask, uint16 flags, uint64 lastDebtUpdate, address borrower) =
            creditManager.creditAccountInfo(creditAccount);
        assertEq(enabledTokensMask, 0, "enabledTokensMask not cleared");
        assertEq(borrower, address(0), "borrower not cleared");
        assertEq(lastDebtUpdate, 0, "lastDebtUpadte not cleared");
        assertEq(flags, 0, "flags not cleared");

        assertEq(creditManager.creditAccountsLen(), 0, _testCaseErr("incorrect creditAccounts length"));
    }

    //
    //
    // LIQUIDATE CREDIT ACCOUNT
    //
    //
    struct LiquidateAccountTestCase {
        string name;
        uint256 debt;
        uint256 accruedInterest;
        uint256 accruedFees;
        uint256 totalValue;
        uint256 enabledTokensMask;
        address[] quotedTokens;
        uint256 underlyingBalance;
        uint256 usdcBalance;
        uint256 linkBalance;
        bool isExpired;
        // EXPECTED
        bool expectedRevert;
        uint256 amountToLiquidator;
        uint256 enabledTokensMaskAfter;
        bool expectedSetLimitsToZero;
    }

    uint256 constant USDC_MULTIPLIER = 2;

    uint256 constant LINK_MULTIPLIER = 4;

    /// @dev U:[CM-8]: liquidate credit account works as expected
    function test_U_CM_08_liquidateCreditAccount_correctly_makes_payments(uint256 debt)
        public
        withFeeTokenCase
        creditManagerTest
    {
        debt = bound(debt, 10 ** 8, 1e10 * 10 ** _decimals(underlying));

        address[] memory hasQuotedTokens = new address[](2);

        hasQuotedTokens[0] = tokenTestSuite.addressOf(Tokens.USDC);
        hasQuotedTokens[1] = tokenTestSuite.addressOf(Tokens.LINK);

        priceOracleMock.setPrice(underlying, 10 ** 8);

        /// @notice sets price 2 USD for underlying
        priceOracleMock.setPrice(tokenTestSuite.addressOf(Tokens.USDC), USDC_MULTIPLIER * 10 ** 8);

        /// @notice sets price 4 USD for underlying
        priceOracleMock.setPrice(tokenTestSuite.addressOf(Tokens.LINK), LINK_MULTIPLIER * 10 ** 8);

        vm.startPrank(CONFIGURATOR);
        creditManager.addToken(tokenTestSuite.addressOf(Tokens.USDC));
        creditManager.addToken(tokenTestSuite.addressOf(Tokens.LINK));
        vm.stopPrank();

        uint256 LINK_TOKEN_MASK = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));

        LiquidateAccountTestCase[7] memory cases = [
            LiquidateAccountTestCase({
                name: "Liquidate account with profit, underlying only",
                debt: debt,
                accruedInterest: 0,
                accruedFees: 0,
                totalValue: debt * 2,
                enabledTokensMask: UNDERLYING_TOKEN_MASK,
                quotedTokens: hasQuotedTokens,
                underlyingBalance: debt * 2,
                usdcBalance: 0,
                linkBalance: 0,
                isExpired: false,
                // EXPECTED
                expectedRevert: false,
                amountToLiquidator: debt * 2 - debt * 2 * (PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM) / PERCENTAGE_FACTOR,
                enabledTokensMaskAfter: UNDERLYING_TOKEN_MASK,
                expectedSetLimitsToZero: false
            }),
            LiquidateAccountTestCase({
                name: "Liquidate account with profit, underlying only, revert not enough remaing funds",
                debt: debt,
                accruedInterest: 0,
                accruedFees: 0,
                totalValue: debt * 2,
                enabledTokensMask: UNDERLYING_TOKEN_MASK,
                quotedTokens: hasQuotedTokens,
                underlyingBalance: _amountWithFee(debt + debt * 2 * DEFAULT_FEE_LIQUIDATION / PERCENTAGE_FACTOR),
                usdcBalance: 0,
                linkBalance: 0,
                isExpired: false,
                // EXPECTED
                expectedRevert: true,
                amountToLiquidator: 0,
                enabledTokensMaskAfter: UNDERLYING_TOKEN_MASK,
                expectedSetLimitsToZero: false
            }),
            LiquidateAccountTestCase({
                name: "Liquidate account with profit, without quotas, with link, underlyingBalance is sent",
                debt: debt,
                accruedInterest: 0,
                accruedFees: 0,
                totalValue: debt * 2,
                enabledTokensMask: UNDERLYING_TOKEN_MASK | LINK_TOKEN_MASK,
                quotedTokens: new address[](0),
                underlyingBalance: _amountWithFee(debt + debt * 2 * DEFAULT_FEE_LIQUIDATION / PERCENTAGE_FACTOR) + 1_000,
                usdcBalance: 0,
                linkBalance: debt,
                isExpired: false,
                // EXPECTED
                expectedRevert: false,
                amountToLiquidator: 1_000,
                enabledTokensMaskAfter: UNDERLYING_TOKEN_MASK | LINK_TOKEN_MASK,
                expectedSetLimitsToZero: false
            }),
            LiquidateAccountTestCase({
                name: "Liquidate account with profit, without quotas, with link, underlyingBalance is sent, EXPIRED",
                debt: debt,
                accruedInterest: 0,
                accruedFees: 0,
                totalValue: debt * 2,
                enabledTokensMask: UNDERLYING_TOKEN_MASK | LINK_TOKEN_MASK,
                quotedTokens: new address[](0),
                underlyingBalance: _amountWithFee(debt + debt * 2 * DEFAULT_FEE_LIQUIDATION_EXPIRED / PERCENTAGE_FACTOR) + 1_000,
                usdcBalance: 0,
                linkBalance: debt,
                isExpired: true,
                // EXPECTED
                expectedRevert: false,
                amountToLiquidator: 1_000,
                enabledTokensMaskAfter: UNDERLYING_TOKEN_MASK | LINK_TOKEN_MASK,
                expectedSetLimitsToZero: false
            }),
            LiquidateAccountTestCase({
                name: "Liquidate account with profit, with quotas, with link, underlyingBalance is sent",
                debt: debt,
                accruedInterest: 0,
                accruedFees: 0,
                totalValue: debt * 2,
                enabledTokensMask: UNDERLYING_TOKEN_MASK | LINK_TOKEN_MASK,
                quotedTokens: hasQuotedTokens,
                underlyingBalance: _amountWithFee(debt + debt * 2 * DEFAULT_FEE_LIQUIDATION / PERCENTAGE_FACTOR) + 1_000,
                usdcBalance: 0,
                linkBalance: debt,
                isExpired: false,
                // EXPECTED
                expectedRevert: false,
                amountToLiquidator: 1_000,
                enabledTokensMaskAfter: UNDERLYING_TOKEN_MASK,
                expectedSetLimitsToZero: false
            }),
            LiquidateAccountTestCase({
                name: "Liquidate account with loss, without quotaTokens, underlying only",
                debt: debt,
                accruedInterest: 0,
                accruedFees: 0,
                totalValue: debt / 2,
                enabledTokensMask: UNDERLYING_TOKEN_MASK,
                quotedTokens: new address[](0),
                underlyingBalance: debt / 2,
                usdcBalance: 0,
                linkBalance: 0,
                isExpired: false,
                // EXPECTED
                expectedRevert: false,
                amountToLiquidator: debt / 2 * DEFAULT_LIQUIDATION_PREMIUM / PERCENTAGE_FACTOR,
                enabledTokensMaskAfter: UNDERLYING_TOKEN_MASK,
                expectedSetLimitsToZero: false
            }),
            LiquidateAccountTestCase({
                name: "Liquidate account with loss, with quotaTokens, underlying only",
                debt: debt,
                accruedInterest: 0,
                accruedFees: 0,
                totalValue: debt / 2,
                enabledTokensMask: UNDERLYING_TOKEN_MASK,
                quotedTokens: hasQuotedTokens,
                underlyingBalance: debt / 2,
                usdcBalance: 0,
                linkBalance: 0,
                isExpired: false,
                // EXPECTED
                expectedRevert: false,
                amountToLiquidator: debt / 2 * DEFAULT_LIQUIDATION_PREMIUM / PERCENTAGE_FACTOR,
                enabledTokensMaskAfter: UNDERLYING_TOKEN_MASK,
                expectedSetLimitsToZero: true
            })
        ];

        address creditAccount = accountFactory.usedAccount();

        creditManager.setBorrower(creditAccount, USER);

        for (uint256 i; i < cases.length; ++i) {
            uint256 snapshot = vm.snapshot();

            LiquidateAccountTestCase memory _case = cases[i];

            caseName = string.concat(caseName, _case.name);

            CollateralDebtData memory collateralDebtData;
            collateralDebtData._poolQuotaKeeper = address(poolQuotaKeeperMock);
            collateralDebtData.debt = _case.debt;
            collateralDebtData.accruedInterest = _case.accruedInterest;
            collateralDebtData.accruedFees = _case.accruedFees;
            collateralDebtData.totalValue = _case.totalValue;
            collateralDebtData.enabledTokensMask = _case.enabledTokensMask;
            collateralDebtData.quotedTokens = _case.quotedTokens;
            {
                /// @notice We do not test math correctness here, it could be found in lib test
                /// We assume here, that lib is tested and provide correct results, the test checks
                /// that te contract sends amout to correct addresses and implement another logic is need
                uint256 amountToPool;
                uint256 profit;
                uint256 minRemainingFunds;
                uint256 expectedLoss;

                (amountToPool, minRemainingFunds, profit, expectedLoss) = collateralDebtData.calcLiquidationPayments({
                    liquidationDiscount: _case.isExpired
                        ? PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM_EXPIRED
                        : PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM,
                    feeLiquidation: _case.isExpired ? DEFAULT_FEE_LIQUIDATION_EXPIRED : DEFAULT_FEE_LIQUIDATION,
                    amountWithFeeFn: _amountWithFee,
                    amountMinusFeeFn: _amountMinusFee
                });

                tokenTestSuite.mint(underlying, creditAccount, _case.underlyingBalance);
                tokenTestSuite.mint(tokenTestSuite.addressOf(Tokens.USDC), creditAccount, _case.usdcBalance);
                tokenTestSuite.mint(tokenTestSuite.addressOf(Tokens.LINK), creditAccount, _case.linkBalance);

                vm.startPrank(CONFIGURATOR);
                for (uint256 j; j < _case.quotedTokens.length; ++j) {
                    creditManager.setQuotedMask(
                        creditManager.quotedTokensMask() | creditManager.getTokenMaskOrRevert(_case.quotedTokens[j])
                    );
                }

                vm.stopPrank();

                collateralDebtData.quotedTokensMask = creditManager.quotedTokensMask();

                startTokenTrackingSession(caseName);

                expectTokenTransfer({
                    reason: "debt transfer to pool",
                    token: underlying,
                    from: creditAccount,
                    to: address(poolMock),
                    amount: _amountMinusFee(amountToPool)
                });

                if (_case.amountToLiquidator != 0) {
                    expectTokenTransfer({
                        reason: "transfer to caller",
                        token: underlying,
                        from: creditAccount,
                        to: FRIEND,
                        amount: _amountMinusFee(_case.amountToLiquidator)
                    });
                }

                uint256 poolBalanceBefore = IERC20(underlying).balanceOf(address(poolMock));

                ///
                /// CLOSE CREDIT ACC
                ///

                if (_case.expectedRevert) {
                    vm.expectRevert(InsufficientRemainingFundsException.selector);
                } else {
                    vm.expectCall(
                        address(poolMock),
                        abi.encodeCall(poolMock.repayCreditAccount, (_case.debt, profit, expectedLoss))
                    );
                }

                (uint256 remainingFunds, uint256 loss) = creditManager.liquidateCreditAccount({
                    creditAccount: creditAccount,
                    collateralDebtData: collateralDebtData,
                    to: FRIEND,
                    isExpired: _case.isExpired
                });

                if (_case.expectedRevert) return;

                assertEq(poolMock.repayAmount(), collateralDebtData.debt, _testCaseErr("Incorrect repay amount"));
                assertEq(poolMock.repayProfit(), profit, _testCaseErr("Incorrect profit"));
                assertEq(poolMock.repayLoss(), loss, _testCaseErr("Incorrect loss"));
                {
                    uint256 expectedRemainingFunds = _case.underlyingBalance - amountToPool - _case.amountToLiquidator
                        + _case.usdcBalance * USDC_MULTIPLIER + _case.linkBalance * LINK_MULTIPLIER;
                    assertEq(remainingFunds, expectedRemainingFunds, _testCaseErr("incorrect remainingFunds"));
                }

                assertEq(loss, expectedLoss, _testCaseErr("incorrect loss"));

                checkTokenTransfers({debug: false});

                /// @notice Pool balance invariant keeps correct transfer to pool during closure

                expectBalance({
                    token: underlying,
                    holder: address(poolMock),
                    expectedBalance: poolBalanceBefore + _amountMinusFee(amountToPool),
                    reason: "Pool balance invariant"
                });

                expectBalance({
                    token: underlying,
                    holder: creditAccount,
                    expectedBalance: _case.underlyingBalance - amountToPool - _case.amountToLiquidator,
                    reason: "Credit account balance invariant"
                });

                assertEq(
                    poolQuotaKeeperMock.call_creditAccount(),
                    _case.quotedTokens.length == 0 ? address(0) : creditAccount,
                    _testCaseErr("Incorrect creditAccount call to PQK")
                );

                assertTrue(
                    poolQuotaKeeperMock.call_setLimitsToZero() == _case.expectedSetLimitsToZero,
                    _testCaseErr("Incorrect setLimitsToZero")
                );
            }

            {
                (uint256 accountDebt,, uint128 cumulativeQuotaInterest, uint128 quotaFees,,,,) =
                    creditManager.creditAccountInfo(creditAccount);

                assertEq(accountDebt, 0, _testCaseErr("Debt is not zero"));
                assertEq(cumulativeQuotaInterest, 1, _testCaseErr("cumulativeQuotaInterest is not 1"));
                assertEq(quotaFees, 0, _testCaseErr("quotaFees is not zero"));
            }

            {
                (,,,, uint256 enabledTokensMask,, uint64 lastDebtUpdate, address borrower) =
                    creditManager.creditAccountInfo(creditAccount);

                assertEq(enabledTokensMask, _case.enabledTokensMaskAfter, _testCaseErr("Incorrect enabled tokensMask"));
                assertEq(lastDebtUpdate, block.number, _testCaseErr("Incorrect lastDebtUpdate"));
                assertEq(borrower, USER, _testCaseErr("Incorrect borrower after"));
            }

            vm.revertTo(snapshot);
        }
    }

    /// @dev U:[CM-9]: liquidate credit account reverts if called twice a block
    function test_U_CM_09_liquidateCreditAccount_reverts_if_called_twice_a_block() public creditManagerTest {
        CollateralDebtData memory collateralDebtData;
        collateralDebtData._poolQuotaKeeper = address(poolQuotaKeeperMock);
        collateralDebtData.debt = DAI_ACCOUNT_AMOUNT;
        collateralDebtData.accruedInterest = 0;
        collateralDebtData.accruedFees = 0;
        collateralDebtData.totalValue = DAI_ACCOUNT_AMOUNT * 2;
        collateralDebtData.enabledTokensMask = UNDERLYING_TOKEN_MASK;

        address creditAccount = accountFactory.usedAccount();

        tokenTestSuite.mint(underlying, creditAccount, DAI_ACCOUNT_AMOUNT * 2);

        creditManager.setLastDebtUpdate({creditAccount: creditAccount, lastDebtUpdate: uint64(block.number)});

        vm.expectRevert(DebtUpdatedTwiceInOneBlockException.selector);
        creditManager.liquidateCreditAccount({
            creditAccount: creditAccount,
            collateralDebtData: collateralDebtData,
            to: FRIEND,
            isExpired: false
        });
    }

    // ----------- //
    // MANAGE DEBT //
    // ----------- //

    /// @dev U:[CM-10]: manageDebt increases debt correctly
    function test_U_CM_10_manageDebt_increases_debt_correctly(uint256 amount)
        public
        withFeeTokenCase
        creditManagerTest
    {
        amount = bound(amount, 1, 1e10 * 10 ** _decimals(underlying));

        poolMock.setCumulativeIndexNow(6 * RAY / 5);
        tokenTestSuite.mint(underlying, address(poolMock), amount);

        address creditAccount = accountFactory.usedAccount();
        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: DAI_ACCOUNT_AMOUNT,
            cumulativeIndexLastUpdate: RAY,
            cumulativeQuotaInterest: 1,
            quotaFees: 0,
            enabledTokensMask: 0,
            flags: 0,
            borrower: USER
        });

        CollateralDebtData memory params =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.GENERIC_PARAMS);

        (uint256 expectedNewDebt, uint256 expectedNewIndex) = CreditLogic.calcIncrease({
            amount: amount,
            debt: params.debt,
            cumulativeIndexNow: params.cumulativeIndexNow,
            cumulativeIndexLastUpdate: params.cumulativeIndexLastUpdate
        });

        startTokenTrackingSession(caseName);
        expectTokenTransfer({
            reason: "transfer from pool to credit account ",
            token: underlying,
            from: address(poolMock),
            to: creditAccount,
            amount: _amountMinusFee(amount)
        });

        vm.expectCall(address(poolMock), abi.encodeCall(poolMock.lendCreditAccount, (amount, creditAccount)));

        (uint256 newDebt,,) = creditManager.manageDebt({
            creditAccount: creditAccount,
            amount: amount,
            enabledTokensMask: 0,
            action: ManageDebtAction.INCREASE_DEBT
        });

        checkTokenTransfers({debug: false});

        assertEq(newDebt, expectedNewDebt, _testCaseErr("Incorrect newDebt"));

        CreditAccountInfo memory info = _creditAccountInfo(creditAccount);
        assertEq(info.debt, expectedNewDebt, _testCaseErr("Incorrect creditAccountInfo.debt"));
        assertEq(
            info.cumulativeIndexLastUpdate,
            expectedNewIndex,
            _testCaseErr("Incorrect creditAccountInfo.cumulativeIndexLastUpdate")
        );
        assertEq(info.lastDebtUpdate, block.number, _testCaseErr("Incorrect info.lastDebtUpdate"));
    }

    /// @dev U:[CM-11]: manageDebt decreases debt correctly
    function test_U_CM_11_manageDebt_decreases_debt_correctly(uint256 amount, uint128 quotaInterest, uint128 quotaFees)
        public
        withFeeTokenCase
        creditManagerTest
    {
        amount = bound(amount, 1, 1e10 * 10 ** _decimals(underlying));
        quotaInterest = uint128(bound(quotaInterest, 0, 1e10 * 10 ** _decimals(underlying)));
        quotaFees = uint128(bound(quotaFees, 0, 1e10 * 10 ** _decimals(underlying)));

        poolMock.setCumulativeIndexNow(6 * RAY / 5);

        address creditAccount = accountFactory.usedAccount();
        tokenTestSuite.mint(underlying, creditAccount, amount);
        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: DAI_ACCOUNT_AMOUNT,
            cumulativeIndexLastUpdate: RAY,
            cumulativeQuotaInterest: quotaInterest + 1,
            quotaFees: quotaFees,
            enabledTokensMask: 0,
            flags: 0,
            borrower: USER
        });

        CollateralDebtData memory params =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);
        uint256 maxAmount = _amountWithFee(params.calcTotalDebt());

        uint256 expectedNewDebt;
        uint256 expectedNewIndex;
        uint256 expectedProfit;
        uint256 expectedNewQuotaInterest;
        uint256 expectedQuotaFees;
        if (amount >= maxAmount) {
            expectedNewDebt = 0;
            expectedNewIndex = params.cumulativeIndexNow;
            expectedProfit = params.accruedFees;
            expectedNewQuotaInterest = 0;
            expectedQuotaFees = 0;
        } else {
            (expectedNewDebt, expectedNewIndex, expectedProfit, expectedNewQuotaInterest, expectedQuotaFees) =
            CreditLogic.calcDecrease({
                amount: _amountMinusFee(amount),
                debt: params.debt,
                cumulativeIndexNow: params.cumulativeIndexNow,
                cumulativeIndexLastUpdate: params.cumulativeIndexLastUpdate,
                cumulativeQuotaInterest: quotaInterest,
                quotaFees: quotaFees,
                feeInterest: DEFAULT_FEE_INTEREST
            });
        }

        startTokenTrackingSession(caseName);

        {
            uint256 transferredAmount = _amountMinusFee(Math.min(amount, maxAmount));
            expectTokenTransfer({
                reason: "transfer from credit account to pool",
                token: underlying,
                from: creditAccount,
                to: address(poolMock),
                amount: transferredAmount
            });
        }

        vm.expectCall(
            address(poolMock),
            abi.encodeCall(poolMock.repayCreditAccount, (params.debt - expectedNewDebt, expectedProfit, 0))
        );

        (uint256 newDebt,,) = creditManager.manageDebt({
            creditAccount: creditAccount,
            amount: amount,
            enabledTokensMask: 0,
            action: ManageDebtAction.DECREASE_DEBT
        });

        checkTokenTransfers({debug: false});

        assertEq(newDebt, expectedNewDebt, _testCaseErr("Incorrect newDebt"));

        CreditAccountInfo memory info = _creditAccountInfo(creditAccount);
        assertEq(info.debt, expectedNewDebt, _testCaseErr("Incorrect creditAccountInfo.debt"));
        assertEq(
            info.cumulativeIndexLastUpdate,
            expectedNewIndex,
            _testCaseErr("Incorrect creditAccountInfo.cumulativeIndexLastUpdate")
        );
        assertEq(
            info.cumulativeQuotaInterest - 1,
            expectedNewQuotaInterest,
            _testCaseErr("Incorrect creditAccountInfo.cumulativeQuotaInterest")
        );
        assertEq(info.quotaFees, expectedQuotaFees, _testCaseErr("Incorrect creditAccountInfo.quotaFees"));
        assertEq(info.lastDebtUpdate, block.number, _testCaseErr("Incorrect creditAccountInfo.lastDebtUpdate"));
    }

    /// @dev U:[CM-11A]: manageDebt handles quotas correctly on decrease
    function test_U_CM_11A_manageDebt_handles_quotas_correctly_on_decrease()
        public
        withFeeTokenCase
        creditManagerTest
    {
        address creditAccount = accountFactory.usedAccount();
        tokenTestSuite.mint(underlying, creditAccount, _amountWithFee(DAI_ACCOUNT_AMOUNT));

        address[] memory quotedTokens = new address[](2);
        quotedTokens[0] = tokenTestSuite.addressOf(Tokens.LINK);
        quotedTokens[1] = tokenTestSuite.addressOf(Tokens.USDC);

        _addQuotedToken({token: Tokens.LINK, lt: 80_00, quoted: 10000, outstandingInterest: 0});
        _addQuotedToken({token: Tokens.USDC, lt: 80_00, quoted: 10000, outstandingInterest: 0});

        uint256 quotedTokensMask = _getTokenMaskOrRevert(Tokens.LINK) | _getTokenMaskOrRevert(Tokens.USDC);
        vm.prank(CONFIGURATOR);
        creditManager.setQuotedMask(quotedTokensMask);

        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: DAI_ACCOUNT_AMOUNT,
            cumulativeIndexLastUpdate: RAY,
            cumulativeQuotaInterest: 1,
            quotaFees: 0,
            enabledTokensMask: 0,
            flags: 0,
            borrower: USER
        });

        vm.expectRevert(DebtToZeroWithActiveQuotasException.selector);
        creditManager.manageDebt({
            creditAccount: creditAccount,
            amount: _amountWithFee(DAI_ACCOUNT_AMOUNT),
            enabledTokensMask: quotedTokensMask,
            action: ManageDebtAction.DECREASE_DEBT
        });

        vm.expectCall(
            address(poolQuotaKeeperMock),
            abi.encodeCall(poolQuotaKeeperMock.accrueQuotaInterest, (creditAccount, quotedTokens))
        );
        creditManager.manageDebt({
            creditAccount: creditAccount,
            amount: _amountWithFee(DAI_ACCOUNT_AMOUNT) / 2,
            enabledTokensMask: quotedTokensMask,
            action: ManageDebtAction.DECREASE_DEBT
        });
    }

    /// @dev U:[CM-12A]: manageDebt reverts if debt already updated in the same block
    function test_U_CM_12A_manageDebt_reverts_if_debt_already_updated_in_the_same_block() public creditManagerTest {
        address creditAccount = accountFactory.usedAccount();

        creditManager.setLastDebtUpdate(creditAccount, uint64(block.number));

        vm.expectRevert(DebtUpdatedTwiceInOneBlockException.selector);
        creditManager.manageDebt(creditAccount, 1, 0, ManageDebtAction.INCREASE_DEBT);

        vm.expectRevert(DebtUpdatedTwiceInOneBlockException.selector);
        creditManager.manageDebt(creditAccount, 1, 0, ManageDebtAction.DECREASE_DEBT);
    }

    /// @dev U:[CM-12B]: manageDebt returns early if amount is zero
    function test_U_CM_12B_manageDebt_returns_early_if_amount_is_zero() public creditManagerTest {
        address creditAccount = accountFactory.usedAccount();

        // if function does not return early, it will try to fetch index at some point
        vm.mockCallRevert(address(poolMock), abi.encodeCall(poolMock.baseInterestIndex, ()), "should not be called");

        creditManager.manageDebt(creditAccount, 0, 0, ManageDebtAction.INCREASE_DEBT);
        creditManager.manageDebt(creditAccount, 0, 0, ManageDebtAction.DECREASE_DEBT);
    }

    /// @dev U:[CM-12C]: manageDebt returns correct masks of tokens to enable and disable
    function test_U_CM_12C_manageDebt_returns_correct_masks_of_tokens_to_enable_and_disable()
        public
        withFeeTokenCase
        creditManagerTest
    {
        address creditAccount = accountFactory.usedAccount();
        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: 0,
            cumulativeIndexLastUpdate: RAY,
            cumulativeQuotaInterest: 1,
            quotaFees: 0,
            enabledTokensMask: 0,
            flags: 0,
            borrower: USER
        });

        tokenTestSuite.mint(underlying, address(poolMock), DAI_ACCOUNT_AMOUNT);

        (, uint256 tokensToEnable, uint256 tokensToDisable) =
            creditManager.manageDebt(creditAccount, DAI_ACCOUNT_AMOUNT, 0, ManageDebtAction.INCREASE_DEBT);
        assertEq(tokensToEnable, UNDERLYING_TOKEN_MASK, _testCaseErr("Incorrect tokensToEnable on increase"));
        assertEq(tokensToDisable, 0, _testCaseErr("Incorrect tokensToDisable on increase"));

        vm.roll(block.number + 1);

        (, tokensToEnable, tokensToDisable) =
            creditManager.manageDebt(creditAccount, 123, 0, ManageDebtAction.DECREASE_DEBT);
        assertEq(tokensToEnable, 0, _testCaseErr("Incorrect tokensToEnable on decrease"));
        assertEq(tokensToDisable, 0, _testCaseErr("Incorrect tokensToDisable on decrease"));

        vm.roll(block.number + 1);

        (, tokensToEnable, tokensToDisable) = creditManager.manageDebt(
            creditAccount, _amountMinusFee(DAI_ACCOUNT_AMOUNT) - 123, 0, ManageDebtAction.DECREASE_DEBT
        );
        assertEq(tokensToEnable, 0, _testCaseErr("Incorrect tokensToEnable on full balance decrease"));
        assertEq(
            tokensToDisable, UNDERLYING_TOKEN_MASK, _testCaseErr("Incorrect tokensToDisable on full balance decrease")
        );
    }

    //
    //  ADD COLLATERAL
    //
    /// @dev U:[CM-13]: addCollateral works as expected
    function test_U_CM_13_addCollateral_works_as_expected() public creditManagerTest {
        address creditAccount = DUMB_ADDRESS;
        address linkToken = tokenTestSuite.addressOf(Tokens.LINK);

        uint256 amount = DAI_ACCOUNT_AMOUNT;

        tokenTestSuite.mint({token: underlying, to: USER, amount: amount});

        vm.prank(USER);
        IERC20(underlying).approve({spender: address(creditManager), amount: type(uint256).max});

        vm.expectRevert(TokenNotAllowedException.selector);
        creditManager.addCollateral({payer: USER, creditAccount: creditAccount, token: linkToken, amount: amount});

        startTokenTrackingSession("add collateral");

        expectTokenTransfer({
            reason: "transfer from user to pool",
            token: underlying,
            from: USER,
            to: creditAccount,
            amount: amount
        });

        uint256 tokenToEnable =
            creditManager.addCollateral({payer: USER, creditAccount: creditAccount, token: underlying, amount: amount});

        checkTokenTransfers({debug: false});

        assertEq(tokenToEnable, UNDERLYING_TOKEN_MASK, "Incorrect tokenToEnable");
    }

    //
    //  APPROVE CREDIT ACCOUNT
    //

    /// @dev U:[CM-14]: approveCreditAccount works as expected
    function test_U_CM_14_approveCreditAccount_works_as_expected() public creditManagerTest {
        address creditAccount = address(new CreditAccountMock());
        address linkToken = tokenTestSuite.addressOf(Tokens.LINK);

        creditManager.setActiveCreditAccount(address(creditAccount));

        vm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        /// @notice check that it reverts on unknown token
        vm.prank(ADAPTER);
        vm.expectRevert(TokenNotAllowedException.selector);
        creditManager.approveCreditAccount({token: linkToken, amount: 20000});

        /// @notice logic which works with different token approvals are incapsulated
        /// in CreditAccountHelper librarby and tested also there

        vm.expectCall(
            creditAccount,
            abi.encodeCall(
                ICreditAccountBase.execute, (underlying, abi.encodeCall(IERC20.approve, (DUMB_ADDRESS, 20000)))
            )
        );

        vm.expectEmit(true, true, true, true);
        emit ExecuteCall(underlying, abi.encodeCall(IERC20.approve, (DUMB_ADDRESS, 20000)));

        vm.prank(ADAPTER);
        creditManager.approveCreditAccount({token: underlying, amount: 20000});
    }

    /// @dev U:[CM-15]: revokeAdapterAllowances works as expected
    function test_U_CM_15_revokeAdapterAllowances_works_as_expected() public creditManagerTest {
        address creditAccount = DUMB_ADDRESS;

        RevocationPair[] memory revCase = new RevocationPair[](1);

        address mockToken = makeAddr("MOCK_TOKEN");

        /// @notice case when token == address
        revCase[0] = RevocationPair({token: address(0), spender: DUMB_ADDRESS});

        vm.expectRevert(ZeroAddressException.selector);
        creditManager.revokeAdapterAllowances(creditAccount, revCase);

        /// @notice case when spender == address
        revCase[0] = RevocationPair({token: DUMB_ADDRESS, spender: address(0)});

        vm.expectRevert(ZeroAddressException.selector);
        creditManager.revokeAdapterAllowances(creditAccount, revCase);

        address spender = makeAddr("SPENDER");

        /// @notice Reverts for unknown token
        revCase[0] = RevocationPair({token: mockToken, spender: spender});
        vm.mockCall(mockToken, abi.encodeCall(IERC20.allowance, (creditAccount, spender)), abi.encode(2));

        vm.expectRevert(TokenNotAllowedException.selector);
        creditManager.revokeAdapterAllowances(creditAccount, revCase);

        /// @notice Set allowance to zero, if it was >2

        creditAccount = address(new CreditAccountMock());
        _addToken(mockToken, 80_00);

        revCase[0] = RevocationPair({token: mockToken, spender: spender});
        vm.mockCall(mockToken, abi.encodeCall(IERC20.allowance, (creditAccount, spender)), abi.encode(2));

        bytes memory approveCallData = abi.encodeCall(IERC20.approve, (spender, 0));
        bytes memory executeCallData = abi.encodeCall(ICreditAccountBase.execute, (mockToken, approveCallData));

        vm.expectCall(creditAccount, executeCallData);
        creditManager.revokeAdapterAllowances(creditAccount, revCase);
    }

    //
    //  EXECUTE
    //

    /// @dev U:[CM-16]: execute works as expected
    function test_U_CM_16_execute_works_as_expected() public creditManagerTest {
        address creditAccount = address(new CreditAccountMock());

        creditManager.setActiveCreditAccount(address(creditAccount));

        vm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        bytes memory dumbCallData = bytes("Hello, world");
        bytes memory expectedReturnValue = bytes("Yes,sir!");

        CreditAccountMock(creditAccount).setReturnExecuteResult(expectedReturnValue);

        vm.expectCall(creditAccount, abi.encodeCall(ICreditAccountBase.execute, (DUMB_ADDRESS, dumbCallData)));

        vm.expectEmit(true, true, true, true);
        emit ExecuteCall(DUMB_ADDRESS, dumbCallData);

        vm.prank(ADAPTER);
        bytes memory returnValue = creditManager.execute(dumbCallData);

        assertEq(returnValue, expectedReturnValue, "Incorrect return value");
    }

    /// @dev U:[CM-17]: `calcDebtAndCollateral` reverts if account does not exist
    function test_U_CM_17_calcDebtAndCollateral_reverts_if_account_does_not_exist() public creditManagerTest {
        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditManager.calcDebtAndCollateral(DUMB_ADDRESS, CollateralCalcTask.GENERIC_PARAMS);

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditManager.calcDebtAndCollateral(DUMB_ADDRESS, CollateralCalcTask.DEBT_ONLY);

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditManager.calcDebtAndCollateral(DUMB_ADDRESS, CollateralCalcTask.DEBT_COLLATERAL);

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditManager.calcDebtAndCollateral(DUMB_ADDRESS, CollateralCalcTask.DEBT_COLLATERAL_SAFE_PRICES);

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditManager.isLiquidatable(DUMB_ADDRESS, PERCENTAGE_FACTOR);
    }

    // ---------------- //
    // COLLATERAL CHECK //
    // ---------------- //

    /// @dev U:[CM-18]: fullCollateralCheck works as expected
    function test_U_CM_18_fullCollateralCheck_works_as_expected(
        uint256 amount,
        uint256 enabledTokensMask,
        uint8 numberOfTokens
    ) public withFeeTokenCase creditManagerTest {
        amount = bound(amount, 1e4, 1e10 * 10 ** _decimals(underlying));
        numberOfTokens = uint8(bound(numberOfTokens, 1, 20));
        enabledTokensMask = bound(enabledTokensMask, 1, 2 ** numberOfTokens - 1);

        // sets underlying price to 1 USD
        priceOracleMock.setPrice(underlying, 10 ** 8);

        vm.prank(CONFIGURATOR);
        creditManager.setMaxEnabledTokens(20);

        // sets up a credit account
        address creditAccount = DUMB_ADDRESS;
        tokenTestSuite.mint({token: underlying, to: creditAccount, amount: amount});
        _addTokensBatch({creditAccount: creditAccount, numberOfTokens: numberOfTokens - 1, balance: amount});
        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: 0,
            cumulativeIndexLastUpdate: RAY,
            cumulativeQuotaInterest: 1,
            quotaFees: 0,
            enabledTokensMask: enabledTokensMask,
            flags: 0,
            borrower: USER
        });

        CollateralDebtData memory cdd =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);
        vm.assume(cdd.twvUSD != 0);

        // makes account liquidatable
        creditManager.setDebt(creditAccount, _amountMinusFee(cdd.twvUSD + 1));

        assertTrue(
            creditManager.isLiquidatable(creditAccount, PERCENTAGE_FACTOR),
            "isLiquidatable is false for liquidatable account"
        );
        vm.expectRevert(NotEnoughCollateralException.selector);
        creditManager.fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMask,
            collateralHints: new uint256[](0),
            minHealthFactor: PERCENTAGE_FACTOR,
            useSafePrices: false
        });

        // makes account non-liquidatable
        creditManager.setDebt(creditAccount, _amountMinusFee(cdd.twvUSD - 1));

        assertFalse(
            creditManager.isLiquidatable(creditAccount, PERCENTAGE_FACTOR),
            "isLiquidatable is true for non-liquidatable account"
        );
        uint256 enabledTokensMaskAfter = creditManager.fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMask,
            collateralHints: new uint256[](0),
            minHealthFactor: PERCENTAGE_FACTOR,
            useSafePrices: false
        });

        assertEq(
            creditManager.enabledTokensMaskOf(creditAccount), enabledTokensMaskAfter, "enabledTokensMask not updated"
        );
    }

    /// @dev U:[CM-18A]: fullCollateralCheck succeeds for zero debt
    function test_U_CM_18A_fullCollateralCheck_succeeds_for_zero_debt(uint256 amount, uint16 minHealthFactor)
        public
        withFeeTokenCase
        creditManagerTest
    {
        amount = bound(amount, 1e4, 1e10 * 10 ** _decimals(underlying));

        // sets underlying price to 1 USD
        priceOracleMock.setPrice(underlying, 10 ** 8);

        // sets up an account with given collateral amount and zero debt
        address creditAccount = DUMB_ADDRESS;
        tokenTestSuite.mint({token: underlying, to: creditAccount, amount: amount});
        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: 0,
            cumulativeIndexLastUpdate: RAY,
            cumulativeQuotaInterest: 1,
            quotaFees: 0,
            enabledTokensMask: UNDERLYING_TOKEN_MASK,
            flags: 0,
            borrower: USER
        });

        assertFalse(
            creditManager.isLiquidatable(creditAccount, minHealthFactor),
            "isLiquidatable is true for account with no debt"
        );

        creditManager.fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMask: UNDERLYING_TOKEN_MASK,
            collateralHints: new uint256[](0),
            minHealthFactor: minHealthFactor,
            useSafePrices: false
        });
    }

    /// @dev U:[CM-18B]: fullCollateralCheck handles minHealthFactor correctly
    function test_U_CM_18B_fullCollateralCheck_handles_minHealthFactor_correctly(
        uint256 amount,
        uint256 healthFactor,
        uint16 minHealthFactor
    ) public withFeeTokenCase creditManagerTest {
        amount = bound(amount, 1e4, 1e10 * 10 ** _decimals(underlying));
        healthFactor = bound(healthFactor, 0.2 ether, 5 ether);

        // sets underlying price to 1 USD
        priceOracleMock.setPrice(underlying, 10 ** 8);

        // sets up an account with given collateral amount and health factor
        address creditAccount = DUMB_ADDRESS;
        tokenTestSuite.mint({token: underlying, to: creditAccount, amount: amount});
        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: 0,
            cumulativeIndexLastUpdate: RAY,
            cumulativeQuotaInterest: 1,
            quotaFees: 0,
            enabledTokensMask: UNDERLYING_TOKEN_MASK,
            flags: 0,
            borrower: USER
        });
        CollateralDebtData memory cdd =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);
        creditManager.setDebt(creditAccount, _amountMinusFee(cdd.twvUSD * 1 ether / healthFactor));

        bool liquidatable = healthFactor / 1e14 < minHealthFactor;
        assertEq(creditManager.isLiquidatable(creditAccount, minHealthFactor), liquidatable, "Incorrect isLiquidatable");

        if (liquidatable) vm.expectRevert(NotEnoughCollateralException.selector);
        creditManager.fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMask: UNDERLYING_TOKEN_MASK,
            collateralHints: new uint256[](0),
            minHealthFactor: minHealthFactor,
            useSafePrices: false
        });
    }

    //
    //
    // CALC DEBT AND COLLATERAL
    //
    //

    /// @dev U:[CM-19]: calcDebtAndCollateral reverts for FULL_COLLATERAL_CHECK_LAZY
    function test_U_CM_19_calcDebtAndCollateral_reverts_for_FULL_COLLATERAL_CHECK_LAZY() public creditManagerTest {
        vm.expectRevert(IncorrectParameterException.selector);
        creditManager.calcDebtAndCollateral({
            creditAccount: DUMB_ADDRESS,
            task: CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY
        });
    }

    /// @dev U:[CM-20]: calcDebtAndCollateral works correctly for GENERIC_PARAMS task
    function test_U_CM_20_calcDebtAndCollateral_works_correctly_for_GENERIC_PARAMS_task() public creditManagerTest {
        uint256 debt = DAI_ACCOUNT_AMOUNT;
        uint256 cumulativeIndexNow = RAY * 12 / 10;
        uint256 cumulativeIndexLastUpdate = RAY * 11 / 10;

        address creditAccount = DUMB_ADDRESS;

        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: debt,
            cumulativeIndexLastUpdate: cumulativeIndexLastUpdate,
            cumulativeQuotaInterest: 1,
            quotaFees: 0,
            enabledTokensMask: UNDERLYING_TOKEN_MASK,
            flags: 0,
            borrower: USER
        });

        poolMock.setCumulativeIndexNow(cumulativeIndexNow);

        CollateralDebtData memory collateralDebtData =
            creditManager.calcDebtAndCollateral({creditAccount: creditAccount, task: CollateralCalcTask.GENERIC_PARAMS});

        assertEq(collateralDebtData.debt, debt, "Incorrect debt");
        assertEq(
            collateralDebtData.cumulativeIndexLastUpdate,
            cumulativeIndexLastUpdate,
            "Incorrect cumulativeIndexLastUpdate"
        );
        assertEq(collateralDebtData.cumulativeIndexNow, cumulativeIndexNow, "Incorrect cumulativeIndexLastUpdate");
    }

    /// @dev U:[CM-21]: calcDebtAndCollateral works correctly for DEBT_ONLY task
    function test_U_CM_21_calcDebtAndCollateral_works_correctly_for_DEBT_ONLY_task() public creditManagerTest {
        uint256 debt = DAI_ACCOUNT_AMOUNT;

        address creditAccount = DUMB_ADDRESS;

        uint96 LINK_QUOTA = uint96(debt / 2);
        uint96 STETH_QUOTA = uint96(debt / 8);

        uint128 LINK_INTEREST = uint128(debt / 8);
        uint128 STETH_INTEREST = uint128(debt / 100);
        uint128 INITIAL_INTEREST = 500;

        _addQuotedToken({token: Tokens.LINK, lt: 80_00, quoted: LINK_QUOTA, outstandingInterest: LINK_INTEREST});
        _addQuotedToken({token: Tokens.STETH, lt: 30_00, quoted: STETH_QUOTA, outstandingInterest: STETH_INTEREST});

        uint256 LINK_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.LINK});
        uint256 STETH_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.STETH});

        vars.set("cumulativeIndexNow", RAY * 22 / 10);
        vars.set("cumulativeIndexLastUpdate", RAY * 21 / 10);

        poolMock.setCumulativeIndexNow(vars.get("cumulativeIndexNow"));

        vm.prank(CONFIGURATOR);
        creditManager.setQuotedMask(LINK_TOKEN_MASK | STETH_TOKEN_MASK);

        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: debt,
            cumulativeIndexLastUpdate: vars.get("cumulativeIndexLastUpdate"),
            cumulativeQuotaInterest: INITIAL_INTEREST,
            quotaFees: 0,
            enabledTokensMask: UNDERLYING_TOKEN_MASK | LINK_TOKEN_MASK | STETH_TOKEN_MASK,
            flags: 0,
            borrower: USER
        });

        poolMock.setCumulativeIndexNow(vars.get("cumulativeIndexNow"));

        vm.prank(CONFIGURATOR);
        creditManager.setMaxEnabledTokens(3);

        CollateralDebtData memory collateralDebtData =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

        assertEq(
            collateralDebtData.enabledTokensMask,
            UNDERLYING_TOKEN_MASK | LINK_TOKEN_MASK | STETH_TOKEN_MASK,
            "Incorrect enabledTokensMask"
        );

        assertEq(collateralDebtData._poolQuotaKeeper, address(poolQuotaKeeperMock), "Incorrect _poolQuotaKeeper");

        assertEq(
            collateralDebtData.quotedTokens, tokenTestSuite.listOf(Tokens.LINK, Tokens.STETH), "Incorrect quotedTokens"
        );

        assertEq(
            collateralDebtData.cumulativeQuotaInterest,
            LINK_INTEREST + STETH_INTEREST + (INITIAL_INTEREST - 1),
            "Incorrect cumulativeQuotaInterest"
        );

        // assertEq(
        //     collateralDebtData.quotas,
        //     supportsQuotas ? arrayOf(LINK_QUOTA, STETH_QUOTA, 0) : new uint256[](0),
        //     "Incorrect quotas"
        // );

        // assertEq(
        //     collateralDebtData.quotedLts,
        //     supportsQuotas ? arrayOfU16(80_00, 30_00, 0) : new uint16[](0),
        //     "Incorrect quotedLts"
        // );

        assertEq(collateralDebtData.quotedTokensMask, LINK_TOKEN_MASK | STETH_TOKEN_MASK, "Incorrect quotedLts");

        assertEq(
            collateralDebtData.accruedInterest,
            CreditLogic.calcAccruedInterest({
                amount: debt,
                cumulativeIndexLastUpdate: vars.get("cumulativeIndexLastUpdate"),
                cumulativeIndexNow: vars.get("cumulativeIndexNow")
            }) + (LINK_INTEREST + STETH_INTEREST + (INITIAL_INTEREST - 1)),
            "Incorrect accruedInterest"
        );

        assertEq(
            collateralDebtData.accruedFees,
            collateralDebtData.accruedInterest * DEFAULT_FEE_INTEREST / PERCENTAGE_FACTOR,
            "Incorrect accruedFees"
        );
    }

    struct CollateralCalcTestCase {
        string name;
        uint256 enabledTokensMask;
        uint256 underlyingBalance;
        uint256 linkBalance;
        uint256 stEthBalance;
        uint256 usdcBalance;
        uint256 expectedTotalValueUSD;
        uint256 expectedTwvUSD;
        uint256 expectedEnabledTokensMask;
    }

    function _collateralTestSetup(uint256 debt) internal {
        vars.set("LINK_QUOTA", 10_000);
        vars.set("LINK_INTEREST", debt / 8);

        vars.set("INITIAL_INTEREST", 500);

        vars.set("LINK_LT", 80_00);
        _addQuotedToken({
            token: Tokens.LINK,
            lt: uint16(vars.get("LINK_LT")),
            quoted: uint96(vars.get("LINK_QUOTA")),
            outstandingInterest: uint128(vars.get("LINK_INTEREST"))
        });

        vars.set("STETH_LT", 30_00);
        _addToken({token: Tokens.STETH, lt: uint16(vars.get("STETH_LT"))});
        _addToken({token: Tokens.USDC, lt: 60_00});

        vars.set("cumulativeIndexNow", RAY * 22 / 10);
        vars.set("cumulativeIndexLastUpdate", RAY * 21 / 10);

        poolMock.setCumulativeIndexNow(vars.get("cumulativeIndexNow"));

        ///
        vars.set("UNDERLYING_PRICE", 2);
        priceOracleMock.setPrice({token: underlying, price: vars.get("UNDERLYING_PRICE") * (10 ** 8)});

        vars.set("LINK_PRICE", 4);
        priceOracleMock.setPrice({
            token: tokenTestSuite.addressOf(Tokens.LINK),
            price: vars.get("LINK_PRICE") * (10 ** 8)
        });

        vars.set("STETH_PRICE", 3);
        priceOracleMock.setPrice({
            token: tokenTestSuite.addressOf(Tokens.STETH),
            price: vars.get("STETH_PRICE") * (10 ** 8)
        });

        vars.set("USDC_PRICE", 5);
        priceOracleMock.setPrice({
            token: tokenTestSuite.addressOf(Tokens.USDC),
            price: vars.get("USDC_PRICE") * (10 ** 8)
        });

        /// @notice Quotas are nominated in underlying token, so we use underlying price instead link one
        vars.set("LINK_QUOTA_IN_USD", vars.get("LINK_QUOTA") * vars.get("UNDERLYING_PRICE"));
    }

    /// @dev U:[CM-22]: calcDebtAndCollateral works correctly for DEBT_COLLATERAL* task
    function test_U_CM_22_calcDebtAndCollateral_works_correctly_for_DEBT_COLLATERAL_task() public creditManagerTest {
        uint256 debt = DAI_ACCOUNT_AMOUNT;

        _collateralTestSetup(debt);

        uint256 LINK_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.LINK});
        uint256 STETH_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.STETH});
        uint256 USDC_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.USDC});

        vm.prank(CONFIGURATOR);
        creditManager.setQuotedMask(LINK_TOKEN_MASK);

        CollateralCalcTestCase[4] memory cases = [
            CollateralCalcTestCase({
                name: "Underlying token on acccount only",
                enabledTokensMask: UNDERLYING_TOKEN_MASK | STETH_TOKEN_MASK | USDC_TOKEN_MASK,
                underlyingBalance: debt,
                linkBalance: 0,
                stEthBalance: 0,
                usdcBalance: 0,
                expectedTotalValueUSD: vars.get("UNDERLYING_PRICE") * (debt - 1),
                expectedTwvUSD: vars.get("UNDERLYING_PRICE") * (debt - 1) * LT_UNDERLYING / PERCENTAGE_FACTOR,
                expectedEnabledTokensMask: UNDERLYING_TOKEN_MASK
            }),
            CollateralCalcTestCase({
                name: "One quoted token with balance < quota",
                enabledTokensMask: LINK_TOKEN_MASK,
                underlyingBalance: 0,
                linkBalance: vars.get("LINK_QUOTA") / 2 / vars.get("LINK_PRICE") + 1,
                stEthBalance: 0,
                usdcBalance: 0,
                expectedTotalValueUSD: vars.get("LINK_QUOTA") / 2,
                expectedTwvUSD: vars.get("LINK_QUOTA") / 2 * vars.get("LINK_LT") / PERCENTAGE_FACTOR,
                expectedEnabledTokensMask: LINK_TOKEN_MASK
            }),
            CollateralCalcTestCase({
                name: "One quoted token with balance > quota",
                enabledTokensMask: LINK_TOKEN_MASK,
                underlyingBalance: 0,
                linkBalance: 2 * vars.get("LINK_QUOTA") * vars.get("UNDERLYING_PRICE") / vars.get("LINK_PRICE") + 1,
                stEthBalance: 0,
                usdcBalance: 0,
                expectedTotalValueUSD: 2 * vars.get("LINK_QUOTA_IN_USD"),
                expectedTwvUSD: vars.get("LINK_QUOTA_IN_USD"),
                expectedEnabledTokensMask: LINK_TOKEN_MASK
            }),
            CollateralCalcTestCase({
                name: "It disables non-quoted zero balance tokens",
                enabledTokensMask: UNDERLYING_TOKEN_MASK | LINK_TOKEN_MASK | STETH_TOKEN_MASK | USDC_TOKEN_MASK,
                underlyingBalance: 20_000,
                linkBalance: 0,
                stEthBalance: 20_000,
                usdcBalance: 0,
                expectedTotalValueUSD: (20_000 - 1) * vars.get("UNDERLYING_PRICE") + (20_000 - 1) * vars.get("STETH_PRICE"),
                expectedTwvUSD: (20_000 - 1) * vars.get("UNDERLYING_PRICE") * LT_UNDERLYING / PERCENTAGE_FACTOR
                    + (20_000 - 1) * vars.get("STETH_PRICE") * vars.get("STETH_LT") / PERCENTAGE_FACTOR,
                expectedEnabledTokensMask: UNDERLYING_TOKEN_MASK | STETH_TOKEN_MASK | LINK_TOKEN_MASK
            })
        ];

        address creditAccount = DUMB_ADDRESS;

        CollateralCalcTask[1] memory tasks = [CollateralCalcTask.DEBT_COLLATERAL];

        for (uint256 taskIndex = 0; taskIndex < 1; ++taskIndex) {
            caseName = string.concat(caseName, _taskName(tasks[taskIndex]));
            for (uint256 i; i < cases.length; ++i) {
                uint256 snapshot = vm.snapshot();

                CollateralCalcTestCase memory _case = cases[i];
                caseName = string.concat(caseName, _case.name);

                creditManager.setCreditAccountInfoMap({
                    creditAccount: creditAccount,
                    debt: debt,
                    cumulativeIndexLastUpdate: vars.get("cumulativeIndexLastUpdate"),
                    cumulativeQuotaInterest: uint128(vars.get("INITIAL_INTEREST") + 1),
                    quotaFees: 0,
                    enabledTokensMask: _case.enabledTokensMask,
                    flags: 0,
                    borrower: USER
                });

                tokenTestSuite.mint({token: underlying, to: creditAccount, amount: _case.underlyingBalance});
                tokenTestSuite.mint({t: Tokens.LINK, to: creditAccount, amount: _case.linkBalance});
                tokenTestSuite.mint({t: Tokens.STETH, to: creditAccount, amount: _case.stEthBalance});
                tokenTestSuite.mint({t: Tokens.USDC, to: creditAccount, amount: _case.usdcBalance});

                CollateralDebtData memory collateralDebtData =
                    creditManager.calcDebtAndCollateralFC({creditAccount: creditAccount, task: tasks[taskIndex]});

                /// @notice It checks that USD value is computed correctly
                assertEq(
                    collateralDebtData.totalDebtUSD,
                    vars.get("UNDERLYING_PRICE")
                        * (debt + collateralDebtData.accruedInterest + collateralDebtData.accruedFees),
                    _testCaseErr("Incorrect totalDebtUSD")
                );

                assertEq(
                    collateralDebtData.totalValueUSD,
                    _case.expectedTotalValueUSD,
                    _testCaseErr("Incorrect totalValueUSD")
                );

                assertEq(collateralDebtData.twvUSD, _case.expectedTwvUSD, _testCaseErr("Incorrect twvUSD"));

                assertEq(
                    collateralDebtData.enabledTokensMask,
                    _case.expectedEnabledTokensMask,
                    _testCaseErr("Incorrect enabledTokensMask")
                );

                assertEq(
                    collateralDebtData.totalValue,
                    _case.expectedTotalValueUSD / vars.get("UNDERLYING_PRICE"),
                    _testCaseErr("Incorrect totalValueUSD")
                );
                vm.revertTo(snapshot);
            }
        }
    }

    ///
    /// GET QUOTED TOKENS DATA
    ///

    struct GetQuotedTokenDataTestCase {
        string name;
        //
        uint256 enabledTokensMask;
        address[] expectedQuotaTokens;
        uint256 expertedOutstandingQuotaInterest;
        uint256[] expectedQuotas;
        uint16[] expectedLts;
    }

    /// @dev U:[CM-24]: _getQuotedTokensData works correctly
    function test_U_CM_24_getQuotedTokensData_works_correctly() public creditManagerTest {
        assertEq(creditManager.collateralTokensCount(), 1, "SETUP: incorrect tokens count");

        //// LINK: [QUOTED]
        _addQuotedToken({token: Tokens.LINK, lt: 80_00, quoted: 10_000, outstandingInterest: 40_000});
        uint256 LINK_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.LINK});

        //// WETH: [NOT_QUOTED]
        _addToken({token: Tokens.WETH, lt: 50_00});
        uint256 WETH_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.WETH});

        //// USDT: [QUOTED]
        _addQuotedToken({token: Tokens.USDT, lt: 40_00, quoted: 0, outstandingInterest: 90_000});
        uint256 USDT_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.USDT});

        //// STETH: [QUOTED]
        _addQuotedToken({token: Tokens.STETH, lt: 30_00, quoted: 20_000, outstandingInterest: 10_000});
        uint256 STETH_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.STETH});

        //// USDC: [NOT_QUOTED]
        _addToken({token: Tokens.USDC, lt: 80_00});
        uint256 USDC_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.USDC});

        //// CVX: [QUOTED]
        _addQuotedToken({token: Tokens.CVX, lt: 20_00, quoted: 100_000, outstandingInterest: 30_000});
        uint256 CVX_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.CVX});

        uint256 quotedTokensMask = LINK_TOKEN_MASK | USDT_TOKEN_MASK | STETH_TOKEN_MASK | CVX_TOKEN_MASK;

        vm.startPrank(CONFIGURATOR);
        creditManager.setQuotedMask(quotedTokensMask);
        creditManager.setMaxEnabledTokens(3);
        vm.stopPrank();

        //
        // CASES
        //
        GetQuotedTokenDataTestCase[4] memory cases = [
            GetQuotedTokenDataTestCase({
                name: "No quoted tokens",
                enabledTokensMask: UNDERLYING_TOKEN_MASK | WETH_TOKEN_MASK | USDC_TOKEN_MASK,
                expectedQuotaTokens: new address[](0),
                expertedOutstandingQuotaInterest: 0,
                expectedQuotas: new uint256[](0),
                expectedLts: new uint16[](0)
            }),
            GetQuotedTokenDataTestCase({
                name: "1 quotes token",
                enabledTokensMask: STETH_TOKEN_MASK | WETH_TOKEN_MASK | USDC_TOKEN_MASK,
                expectedQuotaTokens: tokenTestSuite.listOf(Tokens.STETH),
                expertedOutstandingQuotaInterest: 10_000,
                expectedQuotas: arrayOf(20_000, 0, 0),
                expectedLts: arrayOfU16(30_00, 0, 0)
            }),
            GetQuotedTokenDataTestCase({
                name: "2 quotes token",
                enabledTokensMask: STETH_TOKEN_MASK | LINK_TOKEN_MASK | WETH_TOKEN_MASK | USDC_TOKEN_MASK,
                expectedQuotaTokens: tokenTestSuite.listOf(Tokens.LINK, Tokens.STETH),
                expertedOutstandingQuotaInterest: 40_000 + 10_000,
                expectedQuotas: arrayOf(10_000, 20_000, 0),
                expectedLts: arrayOfU16(80_00, 30_00, 0)
            }),
            GetQuotedTokenDataTestCase({
                name: "3 quotes token",
                enabledTokensMask: STETH_TOKEN_MASK | LINK_TOKEN_MASK | CVX_TOKEN_MASK | WETH_TOKEN_MASK | USDC_TOKEN_MASK,
                expectedQuotaTokens: tokenTestSuite.listOf(Tokens.LINK, Tokens.STETH, Tokens.CVX),
                expertedOutstandingQuotaInterest: 40_000 + 10_000 + 30_000,
                expectedQuotas: arrayOf(10_000, 20_000, 100_000),
                expectedLts: arrayOfU16(80_00, 30_00, 20_00)
            })
        ];

        for (uint256 i; i < cases.length; ++i) {
            uint256 snapshot = vm.snapshot();

            GetQuotedTokenDataTestCase memory _case = cases[i];

            caseName = string.concat(caseName, _case.name);

            /// @notice DUMB_ADDRESS is used because poolQuotaMock has predefined returns
            ///  depended on token only

            (address[] memory quotaTokens, uint256 outstandingQuotaInterest,, uint256 returnedQuotedTokensMask) =
            creditManager.getQuotedTokensData({
                creditAccount: DUMB_ADDRESS,
                enabledTokensMask: _case.enabledTokensMask,
                collateralHints: new uint256[](0),
                _poolQuotaKeeper: address(poolQuotaKeeperMock)
            });

            assertEq(quotaTokens, _case.expectedQuotaTokens, _testCaseErr("Incorrect quotedTokens"));
            assertEq(
                outstandingQuotaInterest,
                _case.expertedOutstandingQuotaInterest,
                _testCaseErr("Incorrect expertedOutstandingQuotaInterest")
            );
            // assertEq(quotas, _case.expectedQuotas, _testCaseErr("Incorrect expectedQuotas"));
            // assertEq(lts, _case.expectedLts, _testCaseErr("Incorrect expectedLts"));
            assertEq(returnedQuotedTokensMask, quotedTokensMask, _testCaseErr("Incorrect expectedQuotedMask"));

            vm.revertTo(snapshot);
        }
    }

    ///
    /// UPDATE QUOTAS
    ///

    /// @dev U:[CM-25]: updateQuota works correctly
    function test_U_CM_25_updateQuota_works_correctly() public creditManagerTest {
        _addToken(Tokens.LINK, 80_00);
        uint256 LINK_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.LINK});

        uint128 INITIAL_INTEREST = 123123;
        uint128 caInterestChange = 10323212323;
        address creditAccount = DUMB_ADDRESS;

        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: 100,
            cumulativeIndexLastUpdate: 0,
            cumulativeQuotaInterest: INITIAL_INTEREST,
            quotaFees: 0,
            enabledTokensMask: 0,
            flags: 0,
            borrower: USER
        });

        for (uint256 i = 0; i < 3; ++i) {
            uint256 snapshot = vm.snapshot();
            bool enable = i == 1;
            bool disable = i == 2;
            uint256 expectedTokensToEnable;
            uint256 expectedTokensToDisable;

            if (enable) {
                caseName = string.concat(caseName, "enable case");
                expectedTokensToEnable = LINK_TOKEN_MASK;
            }
            if (disable) {
                caseName = string.concat(caseName, "disable case");
                expectedTokensToDisable = LINK_TOKEN_MASK;
            }
            poolQuotaKeeperMock.setUpdateQuotaReturns(caInterestChange, enable, disable);

            /// @notice mock returns predefined values which do not depend on params

            (uint256 tokensToEnable, uint256 tokensToDisable) = creditManager.updateQuota({
                creditAccount: creditAccount,
                token: tokenTestSuite.addressOf(Tokens.LINK),
                quotaChange: 122,
                minQuota: 122,
                maxQuota: type(uint96).max
            });

            (,, uint128 cumulativeQuotaInterest,,,,,) = creditManager.creditAccountInfo(creditAccount);

            assertEq(tokensToEnable, expectedTokensToEnable, _testCaseErr("Incorrect tokensToEnable"));
            assertEq(tokensToDisable, expectedTokensToDisable, _testCaseErr("Incorrect tokensToDisable"));
            assertEq(
                cumulativeQuotaInterest,
                INITIAL_INTEREST + caInterestChange,
                _testCaseErr("Incorrect cumulativeQuotaInterest")
            );

            vm.revertTo(snapshot);
        }
    }

    //
    //
    // WITHDRAWALS
    //
    //

    //
    // SCHEDULE WITHDRAWAL
    //

    /// @dev U:[CM-26]: withdrawCollateral reverts for unknown token
    function test_U_CM_26_withdrawCollateral_reverts_for_unknown_token() public creditManagerTest {
        address creditAccount = DUMB_ADDRESS;
        address linkToken = tokenTestSuite.addressOf(Tokens.LINK);
        /// @notice check that it reverts on unknown token
        vm.expectRevert(TokenNotAllowedException.selector);
        creditManager.withdrawCollateral({creditAccount: creditAccount, token: linkToken, amount: 20000, to: USER});
    }

    /// @dev U:[CM-27]: withdrawCollateral transfers token
    function test_U_CM_27_withdrawCollateral_transfers_token() public withFeeTokenCase creditManagerTest {
        address creditAccount = address(new CreditAccountMock());

        tokenTestSuite.mint(underlying, creditAccount, DAI_ACCOUNT_AMOUNT);

        creditManager.setBorrower({creditAccount: creditAccount, borrower: USER});

        string memory caseNameBak = string.concat(caseName, "a part of funds");
        startTokenTrackingSession(caseName);

        expectTokenTransfer({
            reason: "direct transfer to borrower",
            token: underlying,
            from: creditAccount,
            to: USER,
            amount: _amountMinusFee(20_000)
        });

        (uint256 tokensToDisable) = creditManager.withdrawCollateral({
            creditAccount: creditAccount,
            token: underlying,
            amount: 20_000,
            to: USER
        });

        checkTokenTransfers({debug: false});

        assertEq(tokensToDisable, 0, _testCaseErr("Incorrect token to disable"));

        // KEEP 1 CASE

        caseName = string.concat(caseNameBak, " keep 1 token");
        uint256 amount = IERC20(underlying).balanceOf(creditAccount) - 1;

        startTokenTrackingSession(string.concat(caseName, "keep 1"));

        expectTokenTransfer({
            reason: "direct transfer to borrower",
            token: underlying,
            from: creditAccount,
            to: USER,
            amount: _amountMinusFee(amount)
        });

        (tokensToDisable) = creditManager.withdrawCollateral({
            creditAccount: creditAccount,
            token: underlying,
            amount: amount,
            to: USER
        });

        checkTokenTransfers({debug: false});

        assertEq(tokensToDisable, UNDERLYING_TOKEN_MASK, _testCaseErr("Incorrect token to disable"));
    }

    //
    //
    // GETTERS
    //
    //

    /// @dev U:[CM-34]: getTokenMaskOrRevert works correctly
    /// forge-config: default.fuzz.runs = 100
    function test_U_CM_34_getTokenMaskOrRevert_works_correctly(uint8 numberOfTokens) public creditManagerTest {
        vm.assume(numberOfTokens < 254);

        address creditAccount = DUMB_ADDRESS;
        _addTokensBatch({creditAccount: creditAccount, numberOfTokens: numberOfTokens, balance: 2});

        vm.expectRevert(TokenNotAllowedException.selector);
        creditManager.getTokenMaskOrRevert(DUMB_ADDRESS);

        vm.expectRevert(TokenNotAllowedException.selector);
        creditManager.getTokenByMask(1 << 255);

        vm.expectRevert(TokenNotAllowedException.selector);
        creditManager.collateralTokenByMask(1 << 255);

        for (uint256 i = 0; i < numberOfTokens + 1; ++i) {
            uint256 tokenMask = 1 << i;
            assertEq(tokenMask, creditManager.getTokenMaskOrRevert(creditManager.getTokenByMask(tokenMask)));

            (address token,) = creditManager.collateralTokenByMask(tokenMask);
            assertEq(tokenMask, creditManager.getTokenMaskOrRevert(token));
        }
    }

    /// @dev U:[CM-35]: creditAccountInfo getters works correctly
    function test_U_CM_35_creditAccountInfo_getters_works_correctly() public creditManagerTest {
        address creditAccount = DUMB_ADDRESS;

        /// @notice revert if borrower not set
        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditManager.getBorrowerOrRevert(creditAccount);

        uint256 enabledTokensMask = 123412312312;
        uint16 flags = 2333;

        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: 0,
            cumulativeIndexLastUpdate: 0,
            cumulativeQuotaInterest: 1,
            quotaFees: 0,
            enabledTokensMask: enabledTokensMask,
            flags: flags,
            borrower: USER
        });

        assertEq(creditManager.getBorrowerOrRevert(creditAccount), USER, "Incorrect borrower");
        assertEq(creditManager.enabledTokensMaskOf(creditAccount), enabledTokensMask, "Incorrect  enabledTokensMask");
        assertEq(creditManager.flagsOf(creditAccount), flags, "Incorrect flags");
    }

    /// @dev U:[CM-36]: setFlagFor works correctly
    function test_U_CM_36_setFlagFor_works_correctly(uint16 flag) public creditManagerTest {
        address creditAccount = DUMB_ADDRESS;
        for (uint256 j = 0; j < 2; ++j) {
            bool value = j == 1;
            for (uint256 i; i < 16; ++i) {
                creditManager.setCreditAccountInfoMap({
                    creditAccount: creditAccount,
                    debt: 0,
                    cumulativeIndexLastUpdate: 0,
                    cumulativeQuotaInterest: 1,
                    quotaFees: 0,
                    enabledTokensMask: 0,
                    flags: flag,
                    borrower: USER
                });

                uint16 flagToTest = uint16(1 << i);
                creditManager.setFlagFor(creditAccount, flagToTest, value);
                assertEq(creditManager.flagsOf(creditAccount) & flagToTest != 0, value, "Incorrect flag set");
            }
        }
    }

    /// @dev U:[CM-37]: saveEnabledTokensMask works correctly
    function test_U_CM_37_saveEnabledTokensMask_correctly(uint256 mask) public creditManagerTest {
        address creditAccount = DUMB_ADDRESS;

        creditManager.setCollateralTokensCount(255);

        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: 0,
            cumulativeIndexLastUpdate: 0,
            cumulativeQuotaInterest: 1,
            quotaFees: 0,
            enabledTokensMask: 0,
            flags: 0,
            borrower: address(0)
        });

        uint8 maxEnabledTokens = uint8(uint256(keccak256(abi.encode((mask)))) % 255);

        vm.prank(CONFIGURATOR);
        creditManager.setMaxEnabledTokens(maxEnabledTokens);

        if (mask.disable(UNDERLYING_TOKEN_MASK).calcEnabledTokens() > maxEnabledTokens) {
            vm.expectRevert(TooManyEnabledTokensException.selector);
            creditManager.saveEnabledTokensMask(creditAccount, mask);
        } else {
            creditManager.saveEnabledTokensMask(creditAccount, mask);
            uint256 enabledTokensMask = creditManager.enabledTokensMaskOf(creditAccount);
            assertEq(enabledTokensMask, mask);
        }
    }
    //
    //
    // CONFIGURATION
    //
    //

    //
    // ADD TOKEN
    //

    /// @dev U:[CM-38]: addToken reverts if token exists and if collateralTokens > 255
    function test_U_CM_38_addToken_reverts_if_token_exists_and_if_collateralTokens_more_255()
        public
        creditManagerTest
    {
        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(TokenAlreadyAddedException.selector);
        creditManager.addToken(underlying);

        for (uint256 i = creditManager.collateralTokensCount(); i < 255; i++) {
            creditManager.addToken(address(uint160(uint256(keccak256(abi.encodePacked(i))))));
        }

        vm.expectRevert(TooManyTokensException.selector);
        creditManager.addToken(DUMB_ADDRESS);

        vm.stopPrank();
    }

    /// @dev U:[CM-39]: addToken adds token and set tokenMaskMap correctly
    function test_U_CM_39_addToken_adds_token_and_set_tokenMaskMap_correctly() public creditManagerTest {
        uint256 count = creditManager.collateralTokensCount();

        address token = DUMB_ADDRESS;

        vm.prank(CONFIGURATOR);
        creditManager.addToken(token);

        assertEq(creditManager.collateralTokensCount(), count + 1, "collateralTokensCount want incremented");
        assertEq(creditManager.getTokenMaskOrRevert(token), 1 << count, "tokenMaskMap was set incorrectly");

        CollateralTokenData memory ctd = creditManager.getCollateralTokensData(1 << count);

        assertEq(ctd.token, token, "Incorrect token field");
        assertEq(ctd.ltInitial, 0, "Incorrect ltInitial");
        assertEq(ctd.ltFinal, 0, "Incorrect ltFinal");
        assertEq(ctd.timestampRampStart, type(uint40).max, "Incorrect timestampRampStart");
        assertEq(ctd.rampDuration, 0, "Incorrect rampDuration");
    }

    /// @dev U:[CM-40]: setFees sets configuration properly
    function test_U_CM_40_setFees_sets_configuration_properly() public creditManagerTest {
        uint16 s_feeInterest = 8733;
        uint16 s_feeLiquidation = 1233;
        uint16 s_liquidationPremium = 1220;
        uint16 s_feeLiquidationExpired = 1221;
        uint16 s_liquidationPremiumExpired = 7777;

        vm.prank(CONFIGURATOR);
        creditManager.setFees(
            s_feeInterest, s_feeLiquidation, s_liquidationPremium, s_feeLiquidationExpired, s_liquidationPremiumExpired
        );
        (
            uint16 feeInterest,
            uint16 feeLiquidation,
            uint16 liquidationDiscount,
            uint16 feeLiquidationExpired,
            uint16 liquidationPremiumExpired
        ) = creditManager.fees();

        assertEq(feeInterest, s_feeInterest, "Incorrect feeInterest");
        assertEq(feeLiquidation, s_feeLiquidation, "Incorrect feeLiquidation");
        assertEq(liquidationDiscount, s_liquidationPremium, "Incorrect liquidationDiscount");
        assertEq(feeLiquidationExpired, s_feeLiquidationExpired, "Incorrect feeLiquidationExpired");
        assertEq(liquidationPremiumExpired, s_liquidationPremiumExpired, "Incorrect liquidationPremiumExpired");
    }

    //
    // SET LIQUIDATION THRESHOLD
    //

    /// @dev U:[CM-41]: setCollateralTokenData reverts for unknown token
    function test_U_CM_41_setCollateralTokenData_reverts_for_unknown_token() public creditManagerTest {
        vm.prank(CONFIGURATOR);
        vm.expectRevert(TokenNotAllowedException.selector);
        creditManager.setCollateralTokenData(DUMB_ADDRESS, 8000, 8000, type(uint40).max, 0);
    }

    /// @dev U:[CM-42]: setCollateralTokenData sets collateral params properly
    function test_U_CM_42_setCollateralTokenData_sets_collateral_params_properly(
        uint16 ltInitial,
        uint16 ltFinal,
        uint40 timestampRampStart,
        uint24 rampDuration
    ) public creditManagerTest {
        vm.startPrank(CONFIGURATOR);

        ltInitial = uint16(bound(ltInitial, 0, PERCENTAGE_FACTOR));
        ltFinal = uint16(bound(ltFinal, 0, PERCENTAGE_FACTOR));

        vm.assume(uint256(timestampRampStart) + uint256(rampDuration) < type(uint40).max);

        uint256 snapshot = vm.snapshot();

        /// @notice Underlying token case
        creditManager.setCollateralTokenData(underlying, ltInitial, 90_00, type(uint40).max, 230);

        CollateralTokenData memory ctd = creditManager.getCollateralTokensData(UNDERLYING_TOKEN_MASK);

        assertEq(ctd.token, underlying, "Incorrect token field");
        assertEq(ctd.ltInitial, 0, "Incorrect ltInitial");
        assertEq(ctd.ltFinal, 0, "Incorrect ltFinal");
        assertEq(ctd.timestampRampStart, type(uint40).max, "Incorrect timestampRampStart");
        assertEq(ctd.rampDuration, 0, "Incorrect rampDuration");

        assertEq(creditManager.liquidationThresholds(underlying), ltInitial, "Incorrect LT for underlying token");

        vm.revertTo(snapshot);
        /// @notice Non-underlying token case
        address weth = tokenTestSuite.addressOf(Tokens.WETH);

        creditManager.addToken(weth);

        creditManager.setCollateralTokenData(weth, ltInitial, ltFinal, timestampRampStart, rampDuration);

        ctd = creditManager.getCollateralTokensData(creditManager.getTokenMaskOrRevert(weth));

        assertEq(ctd.token, weth, "Incorrect token field");
        assertEq(ctd.ltInitial, ltInitial, "Incorrect ltInitial");
        assertEq(ctd.ltFinal, ltFinal, "Incorrect ltFinal");
        assertEq(ctd.timestampRampStart, timestampRampStart, "Incorrect timestampRampStart");
        assertEq(ctd.rampDuration, rampDuration, "Incorrect rampDuration");

        uint16 expectedLT = CreditLogic.getLiquidationThreshold({
            ltInitial: ctd.ltInitial,
            ltFinal: ctd.ltFinal,
            timestampRampStart: ctd.timestampRampStart,
            rampDuration: ctd.rampDuration
        });

        assertEq(creditManager.liquidationThresholds(weth), expectedLT, "Incorrect LT for weth");

        (, uint16 lt) = creditManager.collateralTokenByMask(creditManager.getTokenMaskOrRevert(weth));

        assertEq(lt, expectedLT, "Incorrect LT for weth");

        vm.stopPrank();
    }

    /// @dev U:[CM-43]: setQuotedMask correctly sets value
    function test_U_CM_43_setQuotedMask_works_correctly() public creditManagerTest {
        vm.prank(CONFIGURATOR);
        creditManager.setQuotedMask(23232256);

        assertEq(creditManager.quotedTokensMask(), 23232256, "Incorrect quotedTokensMask");
    }

    /// @dev U:[CM-44]: setMaxEnabledToken correctly sets value
    function test_U_CM_44_setMaxEnabledTokens_works_correctly() public creditManagerTest {
        vm.prank(CONFIGURATOR);
        creditManager.setMaxEnabledTokens(255);

        assertEq(creditManager.maxEnabledTokens(), 255, "Incorrect max enabled tokens");
    }

    //
    // CHANGE CONTRACT AllowanceAction
    //

    /// @dev U:[CM-45]: setContractAllowance updates adapterToContract
    function test_U_CM_45_setContractAllowance_updates_adapterToContract() public creditManagerTest {
        assertTrue(
            creditManager.adapterToContract(ADAPTER) != DUMB_ADDRESS,
            "SETUP: adapterToContract(ADAPTER) is already the same"
        );

        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(TargetContractNotAllowedException.selector);
        creditManager.setContractAllowance(address(creditManager), DUMB_ADDRESS);

        vm.expectRevert(TargetContractNotAllowedException.selector);
        creditManager.setContractAllowance(DUMB_ADDRESS, address(creditManager));

        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        assertEq(creditManager.adapterToContract(ADAPTER), DUMB_ADDRESS, "adapterToContract is not set correctly");
        assertEq(creditManager.contractToAdapter(DUMB_ADDRESS), ADAPTER, "adapterToContract is not set correctly");

        creditManager.setContractAllowance(ADAPTER, address(0));

        assertEq(creditManager.adapterToContract(ADAPTER), address(0), "adapterToContract is not set correctly");
        assertEq(creditManager.contractToAdapter(address(0)), address(0), "adapterToContract is not set correctly");

        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        creditManager.setContractAllowance(address(0), DUMB_ADDRESS);

        assertEq(creditManager.adapterToContract(address(0)), address(0), "adapterToContract is not set correctly");
        assertEq(creditManager.contractToAdapter(DUMB_ADDRESS), address(0), "adapterToContract is not set correctly");

        vm.stopPrank();
    }

    //
    // UPGRADE CONTRACTS
    //

    /// @dev U:[CM-46]: setCreditFacade updates Credit Facade correctly
    function test_U_CM_46_setCreditFacade_updates_contract_correctly() public creditManagerTest {
        assertTrue(creditManager.creditFacade() != DUMB_ADDRESS, "creditFacade( is already the same");

        vm.startPrank(CONFIGURATOR);
        creditManager.setCreditFacade(DUMB_ADDRESS);

        assertEq(creditManager.creditFacade(), DUMB_ADDRESS, "creditFacade is not set correctly");

        assertTrue(address(creditManager.priceOracle()) != DUMB_ADDRESS2, "priceOracle is already the same");

        creditManager.setPriceOracle(DUMB_ADDRESS2);

        assertEq(address(creditManager.priceOracle()), DUMB_ADDRESS2, "priceOracle is not set correctly");

        assertTrue(creditManager.creditConfigurator() != DUMB_ADDRESS, "creditConfigurator is already the same");

        vm.expectEmit(true, false, false, false);
        emit SetCreditConfigurator(DUMB_ADDRESS);

        creditManager.setCreditConfigurator(DUMB_ADDRESS);

        assertEq(creditManager.creditConfigurator(), DUMB_ADDRESS, "creditConfigurator is not set correctly");
        vm.stopPrank();
    }

    /// @dev U:[CM-47]: poolQuotaKeeper works correctly
    function test_U_CM_47_poolQuotaKeeper_works_correctly() public creditManagerTest {
        poolMock.setPoolQuotaKeeper(DUMB_ADDRESS);

        assertEq(creditManager.poolQuotaKeeper(), DUMB_ADDRESS, "Incorrect poolQuotaKeeper");
    }
}
