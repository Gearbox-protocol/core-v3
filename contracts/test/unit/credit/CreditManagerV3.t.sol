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
import "@openzeppelin/contracts/utils/Strings.sol";

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
import {IPoolQuotaKeeper} from "../../../interfaces/IPoolQuotaKeeper.sol";
import {IPoolService} from "@gearbox-protocol/core-v2/contracts/interfaces/IPoolService.sol";

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// MOCKS
import {PriceOracleMock} from "../../mocks/oracles/PriceOracleMock.sol";
import {PoolMock} from "../../mocks/pool/PoolMock.sol";
import {PoolQuotaKeeperMock} from "../../mocks/pool/PoolQuotaKeeperMock.sol";
import {ERC20FeeMock} from "../../mocks/token/ERC20FeeMock.sol";
import {ERC20Mock} from "@gearbox-protocol/core-v2/contracts/test/mocks/token/ERC20Mock.sol";
import {WETHGatewayMock} from "../../mocks/support/WETHGatewayMock.sol";
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

    AccountFactoryMock accountFactory;
    CreditManagerV3Harness creditManager;
    PoolMock poolMock;
    PoolQuotaKeeperMock poolQuotaKeeperMock;

    PriceOracleMock priceOracle;
    WETHGatewayMock wethGateway;
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
        wethGateway = WETHGatewayMock(addressProvider.getAddressOrRevert(AP_WETH_GATEWAY, 3_00));

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
            poolMock.setPoolQuotaKeeper(address(poolQuotaKeeperMock));
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

    function _decimals(address token) internal view returns (uint8) {
        return IERC20Metadata(token).decimals();
    }

    function _addTokens(address creditAccount, uint8 numberOfTokens, uint256 balance) internal {
        for (uint8 i = 0; i < numberOfTokens; ++i) {
            ERC20Mock t =
            new ERC20Mock(string.concat("new token ", Strings.toString(i+1)),string.concat("NT-", Strings.toString(i+1)), 18);

            creditManager.addToken(address(t));
            creditManager.setCollateralTokenData(address(t), 8000, 8000, type(uint40).max, 0);

            t.mint(creditAccount, balance * ((i + 2) % 5));
        }
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

    //
    //
    // MODIFIERS
    //
    //

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

    //
    //
    // OPEN CREDIT ACCOUNT
    //
    //

    /// @dev U:[CM-6]: open credit account works as expected
    function test_U_CM_06_open_credit_account_works_as_expected() public allQuotaCases {
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

        // todo: check why expectCall doesn't work
        //  vm.expectCall(address(accountFactory), abi.encodeCall(IAccountFactory.takeCreditAccount, (0, 0)));
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

    //
    //
    // CLOSE CREDIT ACCOUNT
    //
    //

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

            assertEq(poolMock.repayAmount(), collateralDebtData.debt, _testCaseErr(caseName, "Incorrect repay amount"));
            assertEq(poolMock.repayProfit(), profit, _testCaseErr(caseName, "Incorrect profit"));
            assertEq(poolMock.repayLoss(), loss, _testCaseErr(caseName, "Incorrect loss"));

            assertEq(remainingFunds, expectedRemainingFunds, _testCaseErr(caseName, "incorrect remainingFunds"));

            assertEq(loss, expectedLoss, _testCaseErr(caseName, "incorrect loss"));

            checkTokenTransfers({debug: false});

            /// @notice Pool balance invariant keeps correct transfer to pool during closure

            expectBalance({
                token: underlying,
                holder: address(poolMock),
                expectedBalance: poolBalanceBefore + collateralDebtData.debt + collateralDebtData.accruedInterest + profit
                    - loss,
                reason: "Pool balance invariant"
            });

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

    /// @dev U:[CM-9]: close credit account works as expected
    function test_U_CM_09_close_credit_transfers_tokens_correctly(uint256 skipTokenMask)
        public
        withFeeTokenCase
        withoutSupportQuotas
    {
        bool convertToEth = (skipTokenMask % 2) != 0;
        uint8 numberOfTokens = uint8(skipTokenMask % 253);

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.debt = DAI_ACCOUNT_AMOUNT;

        /// @notice `+2` for underlying and WETH token
        collateralDebtData.enabledTokensMask =
            uint256(keccak256(abi.encode(skipTokenMask))) & ((1 << (numberOfTokens + 2)) - 1);

        address creditAccount = accountFactory.usedAccount();

        creditManager.setBorrower(creditAccount, USER);
        tokenTestSuite.mint({token: underlying, to: creditAccount, amount: _amountWithFee(collateralDebtData.debt * 2)});

        address weth = tokenTestSuite.addressOf(Tokens.WETH);
        creditManager.addToken(weth);
        creditManager.setCollateralTokenData(weth, 8000, 8000, type(uint40).max, 0);

        {
            uint256 randomAmount = skipTokenMask % DAI_ACCOUNT_AMOUNT;
            tokenTestSuite.mint({token: weth, to: creditAccount, amount: randomAmount});
            _addTokens({creditAccount: creditAccount, numberOfTokens: numberOfTokens, balance: randomAmount});
        }

        string memory caseName = string.concat("token transfer with ", Strings.toString(numberOfTokens), " on account");
        caseName = isFeeToken ? string.concat("Fee token: ", caseName) : caseName;

        startTokenTrackingSession(caseName);

        uint8 len = creditManager.collateralTokensCount();

        /// @notice it starts from 1, because underlying token has index 0
        for (uint8 i = 0; i < len; ++i) {
            uint256 tokenMask = 1 << i;
            address token = creditManager.getTokenByMask(tokenMask);
            uint256 balance = IERC20(token).balanceOf(creditAccount);

            if (
                (collateralDebtData.enabledTokensMask & tokenMask != 0) && (tokenMask & skipTokenMask == 0)
                    && (balance > 1)
            ) {
                if (i == 0) {
                    expectTokenTransfer({
                        reason: "transfer underlying token ",
                        token: underlying,
                        from: creditAccount,
                        to: FRIEND,
                        amount: collateralDebtData.debt - 1
                    });
                } else {
                    expectTokenTransfer({
                        reason: string.concat("transfer token ", IERC20Metadata(token).symbol()),
                        token: token,
                        from: creditAccount,
                        to: (convertToEth && token == weth) ? address(wethGateway) : FRIEND,
                        amount: balance - 1
                    });
                }
            }
        }

        creditManager.closeCreditAccount({
            creditAccount: creditAccount,
            closureAction: ClosureAction.CLOSE_ACCOUNT,
            collateralDebtData: collateralDebtData,
            payer: USER,
            to: FRIEND,
            skipTokensMask: skipTokenMask,
            convertToETH: convertToEth
        });

        checkTokenTransfers({debug: true});
    }

    //
    //
    // MANAGE DEBT
    //
    //

    /// @dev U:[CM-10]: manageDebt increases debt correctly
    function test_U_CM_10_manageDebt_increases_debt_correctly(uint256 amount)
        public
        withFeeTokenCase
        withoutSupportQuotas
    {
        vm.assume(amount < 10 ** 10 * (10 ** _decimals(underlying)));

        address creditAccount = accountFactory.usedAccount();

        CollateralDebtData memory collateralDebtData;

        collateralDebtData.debt = DAI_ACCOUNT_AMOUNT;
        collateralDebtData.cumulativeIndexNow = RAY * 12 / 10;
        collateralDebtData.cumulativeIndexLastUpdate = RAY;

        poolMock.setCumulative_RAY(collateralDebtData.cumulativeIndexNow);

        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: collateralDebtData.debt,
            cumulativeIndexLastUpdate: collateralDebtData.cumulativeIndexLastUpdate,
            cumulativeQuotaInterest: 0,
            enabledTokensMask: 0,
            flags: 0,
            borrower: USER
        });

        tokenTestSuite.mint(underlying, address(poolMock), amount);

        /// @notice this test doesn't check math - it's focused on tranfers only
        (uint256 expectedNewDebt, uint256 expectedCumulativeIndex) = CreditLogic.calcIncrease({
            amount: amount,
            debt: collateralDebtData.debt,
            cumulativeIndexNow: collateralDebtData.cumulativeIndexNow,
            cumulativeIndexLastUpdate: collateralDebtData.cumulativeIndexLastUpdate
        });

        string memory caseName = "increase debt";
        caseName = isFeeToken ? string.concat("Fee token: ", caseName) : caseName;

        startTokenTrackingSession(caseName);

        expectTokenTransfer({
            reason: "transfer from pool to credit account ",
            token: underlying,
            from: address(poolMock),
            to: creditAccount,
            amount: _amountMinusFee(amount)
        });

        /// @notice enabledTokesMask is set to zero, because it has no impact
        (uint256 newDebt, uint256 tokensToEnable, uint256 tokensToDisable) = creditManager.manageDebt({
            creditAccount: creditAccount,
            amount: amount,
            enabledTokensMask: 0,
            action: ManageDebtAction.INCREASE_DEBT
        });

        checkTokenTransfers({debug: false});

        assertEq(newDebt, expectedNewDebt, _testCaseErr(caseName, "Incorrect new debt"));

        assertEq(poolMock.lendAmount(), amount, _testCaseErr(caseName, "Incorrect lend amount"));
        assertEq(poolMock.lendAccount(), creditAccount, _testCaseErr(caseName, "Incorrect credit account"));

        /// @notice checking creditAccountInf update

        (uint256 debt, uint256 cumulativeIndexLastUpdate,,,,) = creditManager.creditAccountInfo(creditAccount);

        assertEq(debt, expectedNewDebt, _testCaseErr(caseName, "Incorrect debt update in creditAccountInfo"));
        assertEq(
            cumulativeIndexLastUpdate,
            expectedCumulativeIndex,
            _testCaseErr(caseName, "Incorrect cumulativeIndexLastUpdate update in creditAccountInfo")
        );

        assertEq(tokensToEnable, UNDERLYING_TOKEN_MASK, _testCaseErr(caseName, "Incorrect tokensToEnable"));
        assertEq(tokensToDisable, 0, _testCaseErr(caseName, "Incorrect tokensToDisable"));
    }

    /// @dev U:[CM-11]: manageDebt decreases debt correctly
    function test_U_CM_11_manageDebt_decreases_debt_correctly(uint256 _amount) public withFeeTokenCase allQuotaCases {
        vm.assume(_amount < 10 ** 10 * (10 ** _decimals(underlying)));

        // uint256 amount = 10000;
        uint8 testCase = uint8(_amount % 3);

        /// @notice for stack optimisation
        uint256 amount = _amount;

        address creditAccount = accountFactory.usedAccount();

        CollateralDebtData memory collateralDebtData;

        collateralDebtData.debt = amount * (amount % 5 + 1);
        collateralDebtData.cumulativeIndexNow = RAY * 12 / 10;
        collateralDebtData.cumulativeIndexLastUpdate = RAY;

        if (supportsQuotas) {
            collateralDebtData.cumulativeQuotaInterest = amount / (amount % 5 + 1);
        }

        poolMock.setCumulative_RAY(collateralDebtData.cumulativeIndexNow);

        /// @notice enabledTokensMask is read directly from function parameters, not from this function
        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: collateralDebtData.debt,
            cumulativeIndexLastUpdate: collateralDebtData.cumulativeIndexLastUpdate,
            cumulativeQuotaInterest: collateralDebtData.cumulativeQuotaInterest + 1,
            enabledTokensMask: 0,
            flags: 0,
            borrower: USER
        });

        {
            uint256 amountOnAccount = amount;
            if (testCase == 1) amountOnAccount++;
            if (testCase == 2) amountOnAccount += amount % 500 + 2;

            tokenTestSuite.mint(underlying, creditAccount, amountOnAccount);
        }
        /// @notice this test doesn't check math - it's focused on tranfers only
        (
            uint256 expectedNewDebt,
            uint256 expectedCumulativeIndex,
            uint256 expectedAmountToRepay,
            uint256 expectedProfit,
            uint256 expectedCumulativeQuotaInterest
        ) = CreditLogic.calcDecrease({
            amount: _amountMinusFee(amount),
            debt: collateralDebtData.debt,
            cumulativeIndexNow: collateralDebtData.cumulativeIndexNow,
            cumulativeIndexLastUpdate: collateralDebtData.cumulativeIndexLastUpdate,
            cumulativeQuotaInterest: collateralDebtData.cumulativeQuotaInterest,
            feeInterest: DEFAULT_FEE_INTEREST
        });

        string memory caseName = "decrease debt &";
        caseName = isFeeToken ? string.concat("Fee token: ", caseName) : caseName;
        caseName = supportsQuotas
            ? string.concat(caseName, ", supportsQuotas = true")
            : string.concat(caseName, ", supportsQuotas = false");

        /// @notice there are 3 cases to test
        /// #0: use whole balance of undelrying asset of CA and keeps 0
        if (testCase == 0) {
            caseName = string.concat(caseName, " keeps 0");
        }
        /// #1: use (whole balance - 1)  of undelrying asset of CA and keeps 1
        else if (testCase == 1) {
            caseName = string.concat(caseName, " keeps 1");
        }
        /// #2: use <(whole balance - 1) of undelrying asset of CA and keeps >1
        else if (testCase == 2) {
            caseName = string.concat(caseName, " keeps >1");
        }

        startTokenTrackingSession(caseName);

        expectTokenTransfer({
            reason: "transfer from user to pool",
            token: underlying,
            from: creditAccount,
            to: address(poolMock),
            amount: _amountMinusFee(amount)
        });

        // if (supportsQuotas) {
        //     vm.expectCall(
        //         address(poolQuotaKeeperMock),
        //         abi.encodeCall(IPoolQuotaKeeper.accrueQuotaInterest, (creditAccount, collateralDebtData.quotedTokens))
        //     );
        // }

        /// @notice enabledTokesMask is set to zero, because it has no impact
        (uint256 newDebt, uint256 tokensToEnable, uint256 tokensToDisable) = creditManager.manageDebt({
            creditAccount: creditAccount,
            amount: amount,
            enabledTokensMask: 0,
            action: ManageDebtAction.DECREASE_DEBT
        });

        checkTokenTransfers({debug: false});

        assertEq(newDebt, expectedNewDebt, _testCaseErr(caseName, "Incorrect new debt"));

        assertEq(poolMock.repayAmount(), expectedAmountToRepay, _testCaseErr(caseName, "Incorrect repay amount"));
        assertEq(poolMock.repayProfit(), expectedProfit, _testCaseErr(caseName, "Incorrect repay profit"));
        assertEq(poolMock.repayLoss(), 0, _testCaseErr(caseName, "Incorrect repay loss"));

        /// @notice checking creditAccountInf update
        {
            (uint256 debt, uint256 cumulativeIndexLastUpdate, uint256 cumulativeQuotaInterest,,,) =
                creditManager.creditAccountInfo(creditAccount);

            assertEq(debt, expectedNewDebt, _testCaseErr(caseName, "Incorrect debt update in creditAccountInfo"));
            assertEq(
                cumulativeIndexLastUpdate,
                expectedCumulativeIndex,
                _testCaseErr(caseName, "Incorrect cumulativeIndexLastUpdate update in creditAccountInfo")
            );

            assertEq(
                cumulativeQuotaInterest,
                expectedCumulativeQuotaInterest,
                _testCaseErr(caseName, "Incorrect cumulativeQuotaInterest update in creditAccountInfo")
            );
        }

        assertEq(tokensToEnable, 0, _testCaseErr(caseName, "Incorrect tokensToEnable"));

        /// @notice it should disable token mask with 0 or 1 balance after
        assertEq(
            tokensToDisable,
            (testCase != 2) ? UNDERLYING_TOKEN_MASK : 0,
            _testCaseErr(caseName, "Incorrect tokensToDisable")
        );
    }

    /// @dev U:[CM-12]: manageDebt with 0 amount doesn't change anythig
    function test_U_CM_12_manageDebt_with_0_amount_doesn_t_change_anythig() public withFeeTokenCase allQuotaCases {
        uint256 debt = 10000;
        address creditAccount = accountFactory.usedAccount();

        CollateralDebtData memory collateralDebtData;

        collateralDebtData.debt = debt * (debt % 5 + 1);
        collateralDebtData.cumulativeIndexNow = RAY * 12 / 10;
        collateralDebtData.cumulativeIndexLastUpdate = RAY;

        if (supportsQuotas) {
            collateralDebtData.cumulativeQuotaInterest = debt / (debt % 5 + 1);
        }

        poolMock.setCumulative_RAY(collateralDebtData.cumulativeIndexNow);

        tokenTestSuite.mint(underlying, creditAccount, debt);

        /// @notice enabledTokensMask is read directly from function parameters, not from this function
        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: collateralDebtData.debt,
            cumulativeIndexLastUpdate: collateralDebtData.cumulativeIndexLastUpdate,
            cumulativeQuotaInterest: collateralDebtData.cumulativeQuotaInterest + 1,
            enabledTokensMask: 0,
            flags: 0,
            borrower: USER
        });

        for (uint256 testCase = 0; testCase < 2; testCase++) {
            string memory caseName = "decrease debt &";
            caseName = isFeeToken ? string.concat("Fee token: ", caseName) : caseName;
            caseName = supportsQuotas
                ? string.concat(caseName, ", supportsQuotas = true")
                : string.concat(caseName, ", supportsQuotas = false");

            caseName =
                testCase == 0 ? string.concat(caseName, ", INCREASE_DEBT") : string.concat(caseName, ", DECREASE_DEBT");

            (uint256 newDebt, uint256 tokensToEnable, uint256 tokensToDisable) = creditManager.manageDebt({
                creditAccount: creditAccount,
                amount: 0,
                enabledTokensMask: 0,
                action: testCase == 0 ? ManageDebtAction.INCREASE_DEBT : ManageDebtAction.DECREASE_DEBT
            });

            assertEq(
                tokensToEnable,
                testCase == 0 ? UNDERLYING_TOKEN_MASK : 0,
                _testCaseErr(caseName, "Incorrect tokensToEnable")
            );
            assertEq(tokensToDisable, 0, _testCaseErr(caseName, "Incorrect tokensToDisable"));

            (uint256 caiDebt, uint256 caiCumulativeIndexLastUpdate, uint256 caiCumulativeQuotaInterest,,,) =
                creditManager.creditAccountInfo(creditAccount);

            assertEq(caiDebt, debt, _testCaseErr(caseName, "Incorrect debt update in creditAccountInfo"));
            assertEq(
                caiCumulativeIndexLastUpdate,
                collateralDebtData.cumulativeIndexLastUpdate,
                _testCaseErr(caseName, "Incorrect cumulativeIndexLastUpdate update in creditAccountInfo")
            );

            assertEq(
                caiCumulativeQuotaInterest,
                collateralDebtData.cumulativeQuotaInterest + 1,
                _testCaseErr(caseName, "Incorrect cumulativeQuotaInterest update in creditAccountInfo")
            );
        }
    }

    //
    //  ADD COLLATERAL
    //
    /// @dev U:[CM-13]: addCollateral works as expected
    function test_U_CM_13_addCollateral_works_as_expected() public withoutSupportQuotas {
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
}
