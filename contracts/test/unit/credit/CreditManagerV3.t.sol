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
import {CreditAccountMock, CreditAccountMockEvents} from "../../mocks/credit/CreditAccountMock.sol";
// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";
import {CreditConfig} from "../../config/CreditConfig.sol";

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
    using CreditLogic for CollateralDebtData;
    using CreditLogic for CollateralTokenData;
    using USDTFees for uint256;
    using Vars for VarU256;

    IAddressProviderV3 addressProvider;

    AccountFactoryMock accountFactory;
    CreditManagerV3Harness creditManager;
    PoolMock poolMock;
    PoolQuotaKeeperMock poolQuotaKeeperMock;

    PriceOracleMock priceOracleMock;
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
        addressProvider.setAddress(AP_WETH_TOKEN, tokenTestSuite.addressOf(Tokens.WETH), false);

        accountFactory = AccountFactoryMock(addressProvider.getAddressOrRevert(AP_ACCOUNT_FACTORY, NO_VERSION_CONTROL));
        wethGateway = WETHGatewayMock(addressProvider.getAddressOrRevert(AP_WETH_GATEWAY, 3_00));

        priceOracleMock = PriceOracleMock(addressProvider.getAddressOrRevert(AP_PRICE_ORACLE, 2));
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
            caseName = string.concat(caseName, " [ supportsQuotas = true ] ");
        } else {
            caseName = string.concat(caseName, " [ supportsQuotas = false ] ");
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

        creditManager.setCollateralTokenData({
            token: underlying,
            initialLT: LT_UNDERLYING,
            finalLT: LT_UNDERLYING,
            timestampRampStart: type(uint40).max,
            rampDuration: 0
        });
    }

    function _setUnderlying(bool underlyingIsFeeToken) internal {
        uint256 oneUSDT = 10 ** _decimals(tokenTestSuite.addressOf(Tokens.USDT));

        isFeeToken = underlyingIsFeeToken;
        underlying = tokenTestSuite.addressOf(underlyingIsFeeToken ? Tokens.USDT : Tokens.DAI);

        uint256 _tokenFee = underlyingIsFeeToken ? 30_00 : 0;
        uint256 _maxTokenFee = underlyingIsFeeToken ? 1000000000000 * oneUSDT : 0;

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
        creditManager.addToken({token: token});
        creditManager.setCollateralTokenData({
            token: address(token),
            initialLT: lt,
            finalLT: lt,
            timestampRampStart: type(uint40).max,
            rampDuration: 0
        });
    }

    function _addQuotedToken(address token, uint16 lt, uint96 quoted, uint256 outstandingInterest) internal {
        _addToken({token: token, lt: lt});
        poolQuotaKeeperMock.setQuotaAndOutstandingInterest({
            token: token,
            quoted: quoted,
            outstandingInterest: outstandingInterest
        });
    }

    function _addQuotedToken(Tokens token, uint16 lt, uint96 quoted, uint256 outstandingInterest) internal {
        _addQuotedToken({
            token: tokenTestSuite.addressOf(token),
            lt: lt,
            quoted: quoted,
            outstandingInterest: outstandingInterest
        });
    }

    function _addTokensBatch(address creditAccount, uint8 numberOfTokens, uint256 balance) internal {
        for (uint8 i = 0; i < numberOfTokens; ++i) {
            ERC20Mock t =
            new ERC20Mock(string.concat("new token ", Strings.toString(i+1)),string.concat("NT-", Strings.toString(i+1)), 18);

            _addToken({token: address(t), lt: 80_00});

            t.mint(creditAccount, balance * ((i + 2) % 5));

            /// sets price between $0.01 and $60K
            uint256 randomPrice = (uint256(keccak256(abi.encode(numberOfTokens, i, balance))) % 600_0000) * 10 ** 6;
            priceOracleMock.setPrice(address(t), randomPrice);
        }
    }

    function _getTokenMaskOrRevert(Tokens token) internal view returns (uint256) {
        return creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(token));
    }

    function _taskName(CollateralCalcTask task) internal pure returns (string memory) {
        if (task == CollateralCalcTask.GENERIC_PARAMS) return "GENERIC_PARAMS";

        if (task == CollateralCalcTask.DEBT_ONLY) return "DEBT_ONLY";

        if (task == CollateralCalcTask.DEBT_COLLATERAL_WITHOUT_WITHDRAWALS) {
            return "DEBT_COLLATERAL_WITHOUT_WITHDRAWALS";
        }
        if (task == CollateralCalcTask.DEBT_COLLATERAL_CANCEL_WITHDRAWALS) return "DEBT_COLLATERAL_CANCEL_WITHDRAWALS";

        if (task == CollateralCalcTask.DEBT_COLLATERAL_FORCE_CANCEL_WITHDRAWALS) {
            return "DEBT_COLLATERAL_FORCE_CANCEL_WITHDRAWALS";
        }

        if (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY) return "FULL_COLLATERAL_CHECK_LAZY";

        revert("UNKNOWN TASK");
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev U:[CM-1]: credit manager reverts if were called non-creditFacade
    function test_U_CM_01_constructor_sets_correct_values() public allQuotaCases {
        assertEq(address(creditManager.poolService()), address(poolMock), _testCaseErr("Incorrect poolService"));

        assertEq(address(creditManager.pool()), address(poolMock), _testCaseErr("Incorrect pool"));

        assertEq(creditManager.underlying(), tokenTestSuite.addressOf(Tokens.DAI), _testCaseErr("Incorrect underlying"));

        (address token, uint16 lt) = creditManager.collateralTokensByMask(UNDERLYING_TOKEN_MASK);

        assertEq(token, tokenTestSuite.addressOf(Tokens.DAI), _testCaseErr("Incorrect underlying"));

        assertEq(
            creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI)),
            1,
            _testCaseErr("Incorrect token mask for underlying token")
        );

        // assertEq(lt, 0, _testCaseErr("Incorrect LT for underlying"));

        assertEq(creditManager.supportsQuotas(), supportsQuotas, _testCaseErr("Incorrect supportsQuotas"));

        assertEq(
            creditManager.weth(),
            addressProvider.getAddressOrRevert(AP_WETH_TOKEN, 0),
            _testCaseErr("Incorrect WETH token")
        );

        assertEq(
            address(creditManager.wethGateway()),
            addressProvider.getAddressOrRevert(AP_WETH_GATEWAY, 3_00),
            _testCaseErr("Incorrect WETH Gateway")
        );

        assertEq(
            address(creditManager.priceOracle()),
            addressProvider.getAddressOrRevert(AP_PRICE_ORACLE, 2),
            _testCaseErr("Incorrect Price oracle")
        );

        assertEq(
            address(creditManager.accountFactory()), address(accountFactory), _testCaseErr("Incorrect account factory")
        );

        assertEq(
            address(creditManager.creditConfigurator()), address(this), _testCaseErr("Incorrect creditConfigurator")
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
        creditManager.setActiveCreditAccount(DUMB_ADDRESS);

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
        creditManager.setActiveCreditAccount(DUMB_ADDRESS);

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
        uint256 cumulativeIndexNow = RAY * 5;
        poolMock.setCumulativeIndexNow(cumulativeIndexNow);

        tokenTestSuite.mint(Tokens.DAI, address(poolMock), DAI_ACCOUNT_AMOUNT);

        assertEq(creditManager.creditAccounts().length, 0, _testCaseErr("SETUP: incorrect creditAccounts() length"));

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
            address(creditAccount), accountFactory.usedAccount(), _testCaseErr("Incorrect credit account returned")
        );

        (
            uint256 debt,
            uint256 cumulativeIndexLastUpdate,
            uint256 cumulativeQuotaInterest,
            uint256 enabledTokensMask,
            uint16 flags,
            address borrower
        ) = creditManager.creditAccountInfo(creditAccount);

        assertEq(debt, DAI_ACCOUNT_AMOUNT, _testCaseErr("Incorrect debt"));
        assertEq(cumulativeIndexLastUpdate, cumulativeIndexNow, _testCaseErr("Incorrect cumulativeIndexLastUpdate"));
        assertEq(
            cumulativeQuotaInterest,
            supportsQuotas ? 1 : cumulativeQuotaInterestBefore,
            _testCaseErr("Incorrect cumulativeQuotaInterest")
        );
        assertEq(enabledTokensMask, enabledTokensMaskBefore, _testCaseErr("Incorrect enabledTokensMask"));
        assertEq(flags, 0, _testCaseErr("Incorrect flags"));
        assertEq(borrower, USER, _testCaseErr("Incorrect borrower"));

        assertEq(poolMock.lendAmount(), DAI_ACCOUNT_AMOUNT, _testCaseErr("Incorrect amount was borrowed"));
        assertEq(poolMock.lendAccount(), creditAccount, _testCaseErr("Incorrect amount was borrowed"));

        assertEq(creditManager.creditAccounts().length, 1, _testCaseErr("incorrect creditAccounts() length"));
        assertEq(creditManager.creditAccounts()[0], creditAccount, _testCaseErr("incorrect creditAccounts()[0] value"));

        expectBalance(Tokens.DAI, creditAccount, DAI_ACCOUNT_AMOUNT, _testCaseErr("incorrect balance on creditAccount"));
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

            caseName = string.concat(caseName, _case.name);

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

            assertEq(poolMock.repayAmount(), collateralDebtData.debt, _testCaseErr("Incorrect repay amount"));
            assertEq(poolMock.repayProfit(), profit, _testCaseErr("Incorrect profit"));
            assertEq(poolMock.repayLoss(), loss, _testCaseErr("Incorrect loss"));

            assertEq(remainingFunds, expectedRemainingFunds, _testCaseErr("incorrect remainingFunds"));

            assertEq(loss, expectedLoss, _testCaseErr("incorrect loss"));

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

            assertEq(creditManager.creditAccounts().length, 0, _testCaseErr("incorrect creditAccounts() length"));

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
            _addTokensBatch({creditAccount: creditAccount, numberOfTokens: numberOfTokens, balance: randomAmount});
        }

        caseName = string.concat(caseName, "token transfer with ", Strings.toString(numberOfTokens), " on account");

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

        poolMock.setCumulativeIndexNow(collateralDebtData.cumulativeIndexNow);

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

        caseName = string.concat(caseName, "increase debt");
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

        assertEq(newDebt, expectedNewDebt, _testCaseErr("Incorrect new debt"));

        assertEq(poolMock.lendAmount(), amount, _testCaseErr("Incorrect lend amount"));
        assertEq(poolMock.lendAccount(), creditAccount, _testCaseErr("Incorrect credit account"));

        /// @notice checking creditAccountInf update

        (uint256 debt, uint256 cumulativeIndexLastUpdate,,,,) = creditManager.creditAccountInfo(creditAccount);

        assertEq(debt, expectedNewDebt, _testCaseErr("Incorrect debt update in creditAccountInfo"));
        assertEq(
            cumulativeIndexLastUpdate,
            expectedCumulativeIndex,
            _testCaseErr("Incorrect cumulativeIndexLastUpdate update in creditAccountInfo")
        );

        assertEq(tokensToEnable, UNDERLYING_TOKEN_MASK, _testCaseErr("Incorrect tokensToEnable"));
        assertEq(tokensToDisable, 0, _testCaseErr("Incorrect tokensToDisable"));
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

        poolMock.setCumulativeIndexNow(collateralDebtData.cumulativeIndexNow);

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

        caseName = string.concat(caseName, "decrease debt: ");

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

        assertEq(newDebt, expectedNewDebt, _testCaseErr("Incorrect new debt"));

        assertEq(poolMock.repayAmount(), expectedAmountToRepay, _testCaseErr("Incorrect repay amount"));
        assertEq(poolMock.repayProfit(), expectedProfit, _testCaseErr("Incorrect repay profit"));
        assertEq(poolMock.repayLoss(), 0, _testCaseErr("Incorrect repay loss"));

        /// @notice checking creditAccountInf update
        {
            (uint256 debt, uint256 cumulativeIndexLastUpdate, uint256 cumulativeQuotaInterest,,,) =
                creditManager.creditAccountInfo(creditAccount);

            assertEq(debt, expectedNewDebt, _testCaseErr("Incorrect debt update in creditAccountInfo"));
            assertEq(
                cumulativeIndexLastUpdate,
                expectedCumulativeIndex,
                _testCaseErr("Incorrect cumulativeIndexLastUpdate update in creditAccountInfo")
            );

            assertEq(
                cumulativeQuotaInterest,
                expectedCumulativeQuotaInterest,
                _testCaseErr("Incorrect cumulativeQuotaInterest update in creditAccountInfo")
            );
        }

        assertEq(tokensToEnable, 0, _testCaseErr("Incorrect tokensToEnable"));

        /// @notice it should disable token mask with 0 or 1 balance after
        assertEq(
            tokensToDisable, (testCase != 2) ? UNDERLYING_TOKEN_MASK : 0, _testCaseErr("Incorrect tokensToDisable")
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

        poolMock.setCumulativeIndexNow(collateralDebtData.cumulativeIndexNow);

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
            caseName = string.concat(caseName, "decrease debt &");

            caseName =
                testCase == 0 ? string.concat(caseName, ", INCREASE_DEBT") : string.concat(caseName, ", DECREASE_DEBT");

            (uint256 newDebt, uint256 tokensToEnable, uint256 tokensToDisable) = creditManager.manageDebt({
                creditAccount: creditAccount,
                amount: 0,
                enabledTokensMask: 0,
                action: testCase == 0 ? ManageDebtAction.INCREASE_DEBT : ManageDebtAction.DECREASE_DEBT
            });

            assertEq(
                tokensToEnable, testCase == 0 ? UNDERLYING_TOKEN_MASK : 0, _testCaseErr("Incorrect tokensToEnable")
            );
            assertEq(tokensToDisable, 0, _testCaseErr("Incorrect tokensToDisable"));

            (uint256 caiDebt, uint256 caiCumulativeIndexLastUpdate, uint256 caiCumulativeQuotaInterest,,,) =
                creditManager.creditAccountInfo(creditAccount);

            assertEq(caiDebt, debt, _testCaseErr("Incorrect debt update in creditAccountInfo"));
            assertEq(
                caiCumulativeIndexLastUpdate,
                collateralDebtData.cumulativeIndexLastUpdate,
                _testCaseErr("Incorrect cumulativeIndexLastUpdate update in creditAccountInfo")
            );

            assertEq(
                caiCumulativeQuotaInterest,
                collateralDebtData.cumulativeQuotaInterest + 1,
                _testCaseErr("Incorrect cumulativeQuotaInterest update in creditAccountInfo")
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

    //
    //  APPROVE CREDIT ACCOUNT
    //

    /// @dev U:[CM-15]: approveCreditAccount works as expected
    function test_U_CM_15_approveCreditAccount_works_as_expected() public withoutSupportQuotas {
        address creditAccount = address(new CreditAccountMock());
        address linkToken = tokenTestSuite.addressOf(Tokens.LINK);

        creditManager.setActiveCreditAccount(address(creditAccount));
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        /// @notice check that it reverts on unknown token
        vm.prank(ADAPTER);
        vm.expectRevert(TokenNotAllowedException.selector);
        creditManager.approveCreditAccount({token: linkToken, amount: 20000});

        /// @notice logic which works with different token approvals are incapsulated
        /// in CreditAccountHelper librarby and tested also there

        vm.expectCall(
            creditAccount,
            abi.encodeCall(ICreditAccount.execute, (underlying, abi.encodeCall(IERC20.approve, (DUMB_ADDRESS, 20000))))
        );

        vm.expectEmit(true, true, true, true);
        emit ExecuteCall(underlying, abi.encodeCall(IERC20.approve, (DUMB_ADDRESS, 20000)));

        vm.prank(ADAPTER);
        creditManager.approveCreditAccount({token: underlying, amount: 20000});
    }

    //
    //  EXECUTE
    //

    /// @dev U:[CM-16]: executeOrder works as expected
    function test_U_CM_16_executeOrder_works_as_expected() public withoutSupportQuotas {
        address creditAccount = address(new CreditAccountMock());

        creditManager.setActiveCreditAccount(address(creditAccount));
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        bytes memory dumbCallData = bytes("Hello, world");
        bytes memory expectedReturnValue = bytes("Yes,sir!");

        CreditAccountMock(creditAccount).setReturnExecuteResult(expectedReturnValue);

        vm.expectEmit(true, false, false, false);
        emit ExecuteOrder(DUMB_ADDRESS);

        vm.expectCall(creditAccount, abi.encodeCall(ICreditAccount.execute, (DUMB_ADDRESS, dumbCallData)));

        vm.expectEmit(true, true, true, true);
        emit ExecuteCall(DUMB_ADDRESS, dumbCallData);

        vm.prank(ADAPTER);
        bytes memory returnValue = creditManager.executeOrder(dumbCallData);

        assertEq(returnValue, expectedReturnValue, "Incorrect return value");
    }

    //
    //
    // FULL COLLATERAL CHECK
    //
    //

    /// @dev U:[CM-17]: fullCollateralCheck reverts if hf < 10K
    function test_U_CM_17_fullCollateralCheck_reverts_if_hf_less_10K() public withoutSupportQuotas {
        vm.expectRevert(CustomHealthFactorTooLowException.selector);
        creditManager.fullCollateralCheck({
            creditAccount: DUMB_ADDRESS,
            enabledTokensMask: 0,
            collateralHints: new uint256[](0),
            minHealthFactor: PERCENTAGE_FACTOR - 1
        });
    }

    /// @dev U:[CM-18]: fullCollateralCheck reverts if not enough collateral otherwise saves enabledTokensMask
    function test_U_CM_18_fullCollateralCheck_reverts_if_not_enough_collateral_otherwise_saves_enabledTokensMask(
        uint256 amount
    ) public withFeeTokenCase withoutSupportQuotas {
        /// @notice This test doesn't check collateral calculation, it proves that function
        /// reverts if it's not enough collateral otherwise it stores enabledTokensMask to storage

        vm.assume(amount > 0 && amount < 1e20 * WAD);

        // uint256 amount = DAI_ACCOUNT_AMOUNT;
        address creditAccount = DUMB_ADDRESS;
        uint8 numberOfTokens = uint8(amount % 253);

        /// @notice `+1` for underlying token
        uint256 enabledTokensMask = uint256(keccak256(abi.encode(amount))) & ((1 << (numberOfTokens + 1)) - 1);

        creditManager.setMaxEnabledTokens(numberOfTokens + 1);

        tokenTestSuite.mint({token: underlying, to: creditAccount, amount: amount});

        /// @notice sets price 1 USD for underlying
        priceOracleMock.setPrice(underlying, 10 ** 8);

        _addTokensBatch({creditAccount: creditAccount, numberOfTokens: numberOfTokens, balance: amount});

        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: 100330010,
            cumulativeIndexLastUpdate: RAY,
            cumulativeQuotaInterest: 0,
            enabledTokensMask: enabledTokensMask,
            flags: 0,
            borrower: USER
        });

        CollateralDebtData memory collateralDebtData =
            creditManager.calcDebtAndCollateralFC(creditAccount, CollateralCalcTask.DEBT_COLLATERAL_WITHOUT_WITHDRAWALS);

        /// @notice fuzzler could find a combination which enabled tokens with zero balances,
        /// which cause to twvUSD == 0 and arithmetic errr later
        vm.assume(collateralDebtData.twvUSD > 0);

        creditManager.setDebt(creditAccount, collateralDebtData.twvUSD + 1);

        collateralDebtData =
            creditManager.calcDebtAndCollateralFC(creditAccount, CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY);

        assertEq(
            collateralDebtData.twvUSD + 1, collateralDebtData.totalDebtUSD, "SETUP: incorrect params for liquidation"
        );

        vm.expectRevert(NotEnoughCollateralException.selector);
        creditManager.fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMask,
            collateralHints: new uint256[](0),
            minHealthFactor: PERCENTAGE_FACTOR
        });

        assertTrue(
            creditManager.isLiquidatable(creditAccount, PERCENTAGE_FACTOR),
            "isLiquidatable returns false for liqudatable acc"
        );

        /// @notice we run calcDebtAndCollateral to get enabledTokensMask as it should be after check
        creditManager.setDebt(creditAccount, collateralDebtData.twvUSD - 1);

        collateralDebtData =
            creditManager.calcDebtAndCollateralFC(creditAccount, CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY);

        uint256 enabledTokenMaskWithDisableTokens = collateralDebtData.enabledTokensMask;

        assertTrue(
            !creditManager.isLiquidatable(creditAccount, PERCENTAGE_FACTOR),
            "isLiquidatable returns true for non-liqudatable acc"
        );

        /// @notice it makes account non liquidatable and clears mask - to check that it's set
        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: collateralDebtData.twvUSD - 1,
            cumulativeIndexLastUpdate: RAY,
            cumulativeQuotaInterest: 0,
            enabledTokensMask: 0,
            flags: 0,
            borrower: USER
        });

        creditManager.fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMask,
            collateralHints: new uint256[](0),
            minHealthFactor: PERCENTAGE_FACTOR
        });

        (,,, uint256 enabledTokensMaskAfter,,) = creditManager.creditAccountInfo(creditAccount);

        assertEq(enabledTokensMaskAfter, enabledTokenMaskWithDisableTokens, "enabledTokensMask wasn't set correctly");
    }

    //
    //
    // CALC DEBT AND COLLATERAL
    //
    //

    /// @dev U:[CM-19]: calcDebtAndCollateral reverts for FULL_COLLATERAL_CHECK_LAZY
    function test_U_CM_19_calcDebtAndCollateral_reverts_for_FULL_COLLATERAL_CHECK_LAZY() public withoutSupportQuotas {
        vm.expectRevert(IncorrectParameterException.selector);
        creditManager.calcDebtAndCollateral({
            creditAccount: DUMB_ADDRESS,
            task: CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY
        });
    }

    /// @dev U:[CM-20]: calcDebtAndCollateral works correctly for GENERIC_PARAMS task
    function test_U_CM_20_calcDebtAndCollateral_works_correctly_for_GENERIC_PARAMS_task() public withoutSupportQuotas {
        uint256 debt = DAI_ACCOUNT_AMOUNT;
        uint256 cumulativeIndexNow = RAY * 12 / 10;
        uint256 cumulativeIndexLastUpdate = RAY * 11 / 10;

        address creditAccount = DUMB_ADDRESS;

        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: debt,
            cumulativeIndexLastUpdate: cumulativeIndexLastUpdate,
            cumulativeQuotaInterest: 0,
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
    function test_U_CM_21_calcDebtAndCollateral_works_correctly_for_DEBT_ONLY_task() public allQuotaCases {
        uint256 debt = DAI_ACCOUNT_AMOUNT;

        address creditAccount = DUMB_ADDRESS;

        uint96 LINK_QUOTA = uint96(debt / 2);
        uint96 STETH_QUOTA = uint96(debt / 8);

        uint256 LINK_INTEREST = debt / 8;
        uint256 STETH_INTEREST = debt / 100;
        uint256 INITIAL_INTEREST = 500;

        if (supportsQuotas) {
            _addQuotedToken({token: Tokens.LINK, lt: 80_00, quoted: LINK_QUOTA, outstandingInterest: LINK_INTEREST});
            _addQuotedToken({token: Tokens.STETH, lt: 30_00, quoted: STETH_QUOTA, outstandingInterest: STETH_INTEREST});
        } else {
            _addToken({token: Tokens.LINK, lt: 80_00});
            _addToken({token: Tokens.STETH, lt: 30_00});
        }
        uint256 LINK_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.LINK});
        uint256 STETH_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.STETH});

        vars.set("cumulativeIndexNow", RAY * 22 / 10);
        vars.set("cumulativeIndexLastUpdate", RAY * 21 / 10);

        poolMock.setCumulativeIndexNow(vars.get("cumulativeIndexNow"));

        if (supportsQuotas) {
            creditManager.setQuotedMask(LINK_TOKEN_MASK | STETH_TOKEN_MASK);
        }

        creditManager.setCreditAccountInfoMap({
            creditAccount: creditAccount,
            debt: debt,
            cumulativeIndexLastUpdate: vars.get("cumulativeIndexLastUpdate"),
            cumulativeQuotaInterest: INITIAL_INTEREST,
            enabledTokensMask: UNDERLYING_TOKEN_MASK | LINK_TOKEN_MASK | STETH_TOKEN_MASK,
            flags: 0,
            borrower: USER
        });

        poolMock.setCumulativeIndexNow(vars.get("cumulativeIndexNow"));
        creditManager.setMaxEnabledTokens(3);

        CollateralDebtData memory collateralDebtData =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

        assertEq(
            collateralDebtData.enabledTokensMask,
            UNDERLYING_TOKEN_MASK | LINK_TOKEN_MASK | STETH_TOKEN_MASK,
            "Incorrect enabledTokensMask"
        );

        assertEq(
            collateralDebtData._poolQuotaKeeper,
            supportsQuotas ? address(poolQuotaKeeperMock) : address(0),
            "Incorrect _poolQuotaKeeper"
        );

        assertEq(
            collateralDebtData.quotedTokens,
            supportsQuotas ? tokenTestSuite.listOf(Tokens.LINK, Tokens.STETH, Tokens.NO_TOKEN) : new address[](0),
            "Incorrect quotedTokens"
        );

        assertEq(
            collateralDebtData.cumulativeQuotaInterest,
            supportsQuotas ? LINK_INTEREST + STETH_INTEREST + (INITIAL_INTEREST - 1) : 0,
            "Incorrect cumulativeQuotaInterest"
        );

        assertEq(
            collateralDebtData.quotas,
            supportsQuotas ? arrayOf(LINK_QUOTA, STETH_QUOTA, 0) : new uint256[](0),
            "Incorrect quotas"
        );

        assertEq(
            collateralDebtData.quotedLts,
            supportsQuotas ? arrayOfU16(80_00, 30_00, 0) : new uint16[](0),
            "Incorrect quotedLts"
        );

        assertEq(
            collateralDebtData.enabledQuotedTokenMask,
            supportsQuotas ? LINK_TOKEN_MASK | STETH_TOKEN_MASK : 0,
            "Incorrect quotedLts"
        );

        assertEq(
            collateralDebtData.accruedInterest,
            CreditLogic.calcAccruedInterest({
                amount: debt,
                cumulativeIndexLastUpdate: vars.get("cumulativeIndexLastUpdate"),
                cumulativeIndexNow: vars.get("cumulativeIndexNow")
            }) + (supportsQuotas ? LINK_INTEREST + STETH_INTEREST + (INITIAL_INTEREST - 1) : 0),
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
        if (supportsQuotas) {
            _addQuotedToken({
                token: Tokens.LINK,
                lt: uint16(vars.get("LINK_LT")),
                quoted: uint96(vars.get("LINK_QUOTA")),
                outstandingInterest: vars.get("LINK_INTEREST")
            });
        } else {
            _addToken({token: Tokens.LINK, lt: uint16(vars.get("LINK_LT"))});
        }

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

    function test_U_CM_22_calcDebtAndCollateral_works_correctly_for_DEBT_COLLATERAL_task() public allQuotaCases {
        uint256 debt = DAI_ACCOUNT_AMOUNT;

        _collateralTestSetup(debt);

        uint256 LINK_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.LINK});
        uint256 STETH_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.STETH});
        uint256 USDC_TOKEN_MASK = _getTokenMaskOrRevert({token: Tokens.USDC});

        if (supportsQuotas) {
            creditManager.setQuotedMask(LINK_TOKEN_MASK);
        }

        CollateralCalcTestCase[4] memory cases = [
            CollateralCalcTestCase({
                name: "Underlying token on acccount only",
                enabledTokensMask: UNDERLYING_TOKEN_MASK | STETH_TOKEN_MASK | USDC_TOKEN_MASK,
                underlyingBalance: debt,
                linkBalance: 0,
                stEthBalance: 0,
                usdcBalance: 0,
                expectedTotalValueUSD: vars.get("UNDERLYING_PRICE") * debt,
                expectedTwvUSD: vars.get("UNDERLYING_PRICE") * debt * LT_UNDERLYING / PERCENTAGE_FACTOR,
                expectedEnabledTokensMask: UNDERLYING_TOKEN_MASK
            }),
            CollateralCalcTestCase({
                name: "One quoted token with balance < quota",
                enabledTokensMask: LINK_TOKEN_MASK,
                underlyingBalance: 0,
                linkBalance: vars.get("LINK_QUOTA") / 2 / vars.get("LINK_PRICE"),
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
                linkBalance: 2 * vars.get("LINK_QUOTA") * vars.get("UNDERLYING_PRICE") / vars.get("LINK_PRICE"),
                stEthBalance: 0,
                usdcBalance: 0,
                expectedTotalValueUSD: 2 * vars.get("LINK_QUOTA_IN_USD"),
                expectedTwvUSD: (supportsQuotas ? vars.get("LINK_QUOTA_IN_USD") : 2 * vars.get("LINK_QUOTA_IN_USD"))
                    * vars.get("LINK_LT") / PERCENTAGE_FACTOR,
                expectedEnabledTokensMask: LINK_TOKEN_MASK
            }),
            CollateralCalcTestCase({
                name: "It disables non-quoted zero balance tokens",
                enabledTokensMask: UNDERLYING_TOKEN_MASK | LINK_TOKEN_MASK | STETH_TOKEN_MASK | USDC_TOKEN_MASK,
                underlyingBalance: 20_000,
                linkBalance: 0,
                stEthBalance: 20_000,
                usdcBalance: 0,
                expectedTotalValueUSD: 20_000 * vars.get("UNDERLYING_PRICE") + 20_000 * vars.get("STETH_PRICE"),
                expectedTwvUSD: 20_000 * vars.get("UNDERLYING_PRICE") * LT_UNDERLYING / PERCENTAGE_FACTOR
                    + 20_000 * vars.get("STETH_PRICE") * vars.get("STETH_LT") / PERCENTAGE_FACTOR,
                expectedEnabledTokensMask: UNDERLYING_TOKEN_MASK | STETH_TOKEN_MASK | (supportsQuotas ? LINK_TOKEN_MASK : 0)
            })
        ];

        address creditAccount = DUMB_ADDRESS;

        CollateralCalcTask[3] memory tasks = [
            CollateralCalcTask.DEBT_COLLATERAL_WITHOUT_WITHDRAWALS,
            CollateralCalcTask.DEBT_COLLATERAL_CANCEL_WITHDRAWALS,
            CollateralCalcTask.DEBT_COLLATERAL_FORCE_CANCEL_WITHDRAWALS
        ];

        for (uint256 taskIndex = 0; taskIndex < tasks.length; ++taskIndex) {
            caseName = string.concat(caseName, _taskName(tasks[taskIndex]));
            for (uint256 i; i < cases.length; ++i) {
                uint256 snapshot = vm.snapshot();

                CollateralCalcTestCase memory _case = cases[i];
                caseName = string.concat(caseName, _case.name);

                creditManager.setCreditAccountInfoMap({
                    creditAccount: creditAccount,
                    debt: debt,
                    cumulativeIndexLastUpdate: vars.get("cumulativeIndexLastUpdate"),
                    cumulativeQuotaInterest: vars.get("INITIAL_INTEREST") + 1,
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
        uint256 expectedQuotedMask;
        bool expectRevert;
    }

    /// @dev U:[CM-31]: _getQuotedTokensData works correctly
    function test_U_CM_31_getQuotedTokensData_works_correctly() public withSupportQuotas {
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

        creditManager.setQuotedMask(LINK_TOKEN_MASK | USDT_TOKEN_MASK | STETH_TOKEN_MASK | CVX_TOKEN_MASK);
        creditManager.setMaxEnabledTokens(3);

        //
        // CASES
        //
        GetQuotedTokenDataTestCase[5] memory cases = [
            GetQuotedTokenDataTestCase({
                name: "No quoted tokens",
                enabledTokensMask: UNDERLYING_TOKEN_MASK | WETH_TOKEN_MASK | USDC_TOKEN_MASK,
                expectedQuotaTokens: new address[](0),
                expertedOutstandingQuotaInterest: 0,
                expectedQuotas: new uint256[](0),
                expectedLts: new uint16[](0),
                expectedQuotedMask: 0,
                expectRevert: false
            }),
            GetQuotedTokenDataTestCase({
                name: "Revert if quoted tokens > maxEnabledTokens",
                enabledTokensMask: LINK_TOKEN_MASK | USDT_TOKEN_MASK | STETH_TOKEN_MASK | CVX_TOKEN_MASK,
                expectedQuotaTokens: new address[](0),
                expertedOutstandingQuotaInterest: 0,
                expectedQuotas: new uint256[](0),
                expectedLts: new uint16[](0),
                expectedQuotedMask: 0,
                expectRevert: true
            }),
            GetQuotedTokenDataTestCase({
                name: "1 quotes token",
                enabledTokensMask: STETH_TOKEN_MASK | WETH_TOKEN_MASK | USDC_TOKEN_MASK,
                expectedQuotaTokens: tokenTestSuite.listOf(Tokens.STETH, Tokens.NO_TOKEN, Tokens.NO_TOKEN),
                expertedOutstandingQuotaInterest: 10_000,
                expectedQuotas: arrayOf(20_000, 0, 0),
                expectedLts: arrayOfU16(30_00, 0, 0),
                expectedQuotedMask: STETH_TOKEN_MASK,
                expectRevert: false
            }),
            GetQuotedTokenDataTestCase({
                name: "2 quotes token",
                enabledTokensMask: STETH_TOKEN_MASK | LINK_TOKEN_MASK | WETH_TOKEN_MASK | USDC_TOKEN_MASK,
                expectedQuotaTokens: tokenTestSuite.listOf(Tokens.LINK, Tokens.STETH, Tokens.NO_TOKEN),
                expertedOutstandingQuotaInterest: 40_000 + 10_000,
                expectedQuotas: arrayOf(10_000, 20_000, 0),
                expectedLts: arrayOfU16(80_00, 30_00, 0),
                expectedQuotedMask: LINK_TOKEN_MASK | STETH_TOKEN_MASK,
                expectRevert: false
            }),
            GetQuotedTokenDataTestCase({
                name: "3 quotes token",
                enabledTokensMask: STETH_TOKEN_MASK | LINK_TOKEN_MASK | CVX_TOKEN_MASK | WETH_TOKEN_MASK | USDC_TOKEN_MASK,
                expectedQuotaTokens: tokenTestSuite.listOf(Tokens.LINK, Tokens.STETH, Tokens.CVX),
                expertedOutstandingQuotaInterest: 40_000 + 10_000 + 30_000,
                expectedQuotas: arrayOf(10_000, 20_000, 100_000),
                expectedLts: arrayOfU16(80_00, 30_00, 20_00),
                expectedQuotedMask: LINK_TOKEN_MASK | STETH_TOKEN_MASK | CVX_TOKEN_MASK,
                expectRevert: false
            })
        ];

        for (uint256 i; i < cases.length; ++i) {
            uint256 snapshot = vm.snapshot();

            GetQuotedTokenDataTestCase memory _case = cases[i];

            caseName = string.concat(caseName, _case.name);

            /// @notice DUMB_ADDRESS is used because poolQuotaMock has predefined returns
            ///  depended on token only

            if (_case.expectRevert) {
                vm.expectRevert(TooManyEnabledTokensException.selector);
            }

            (
                address[] memory quotaTokens,
                uint256 outstandingQuotaInterest,
                uint256[] memory quotas,
                uint16[] memory lts,
                uint256 quotedMask
            ) = creditManager.getQuotedTokensData({
                creditAccount: DUMB_ADDRESS,
                enabledTokensMask: _case.enabledTokensMask,
                _poolQuotaKeeper: address(poolQuotaKeeperMock)
            });

            if (!_case.expectRevert) {
                assertEq(quotaTokens, _case.expectedQuotaTokens, _testCaseErr("Incorrect quotedTokens"));
                assertEq(
                    outstandingQuotaInterest,
                    _case.expertedOutstandingQuotaInterest,
                    _testCaseErr("Incorrect expertedOutstandingQuotaInterest")
                );
                assertEq(quotas, _case.expectedQuotas, _testCaseErr("Incorrect expectedQuotas"));
                assertEq(lts, _case.expectedLts, _testCaseErr("Incorrect expectedLts"));
                assertEq(quotedMask, _case.expectedQuotedMask, _testCaseErr("Incorrect expectedQuotedMask"));
            }

            vm.revertTo(snapshot);
        }
    }
}
