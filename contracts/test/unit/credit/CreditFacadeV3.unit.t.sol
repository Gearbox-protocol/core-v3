// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../../../interfaces/IAddressProviderV3.sol";
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";

import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracleV2.sol";

/// LIBS
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CreditFacadeV3Harness} from "./CreditFacadeV3Harness.sol";

import {CreditManagerMock} from "../../mocks/credit/CreditManagerMock.sol";
import {DegenNFTMock} from "../../mocks/token/DegenNFTMock.sol";
import {AdapterMock} from "../../mocks/adapters/AdapterMock.sol";
import {BotListMock} from "../../mocks/support/BotListMock.sol";
import {WithdrawalManagerMock} from "../../mocks/support/WithdrawalManagerMock.sol";
import {PriceOracleMock} from "../../mocks/oracles/PriceOracleMock.sol";
import {PriceFeedOnDemandMock} from "../../mocks/oracles/PriceFeedOnDemandMock.sol";
import {AdapterCallMock} from "../../mocks/adapters/AdapterCallMock.sol";
import {PoolMock} from "../../mocks/pool/PoolMock.sol";

import {ENTERED} from "../../../traits/ReentrancyGuardTrait.sol";

import "../../../interfaces/ICreditFacadeV3.sol";
import {
    ICreditManagerV3,
    ClosureAction,
    CollateralCalcTask,
    CollateralDebtData,
    ManageDebtAction,
    BOT_PERMISSIONS_SET_FLAG
} from "../../../interfaces/ICreditManagerV3.sol";
import {AllowanceAction} from "../../../interfaces/ICreditConfiguratorV3.sol";
import {IBotListV3} from "../../../interfaces/IBotListV3.sol";

import {ClaimAction, ETH_ADDRESS, IWithdrawalManagerV3} from "../../../interfaces/IWithdrawalManagerV3.sol";
import {BitMask, UNDERLYING_TOKEN_MASK} from "../../../libraries/BitMask.sol";
import {MultiCallBuilder} from "../../lib/MultiCallBuilder.sol";

// DATA

import {MultiCall, MultiCallOps} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {Balance, BalanceWithMask} from "../../../libraries/BalancesLogic.sol";

// CONSTANTS
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// TESTS

import "../../lib/constants.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";

import {TestHelper} from "../../lib/helper.sol";
// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";

uint16 constant REFERRAL_CODE = 23;

contract CreditFacadeV3UnitTest is TestHelper, BalanceHelper, ICreditFacadeV3Events {
    using BitMask for uint256;

    IAddressProviderV3 addressProvider;

    CreditFacadeV3Harness creditFacade;
    CreditManagerMock creditManagerMock;
    WithdrawalManagerMock withdrawalManagerMock;
    PriceOracleMock priceOracleMock;
    PoolMock poolMock;

    BotListMock botListMock;

    DegenNFTMock degenNFTMock;
    bool whitelisted;

    bool expirable;

    bool v1PoolUsed;

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

    modifier withV1PoolTest() {
        uint256 snapshot = vm.snapshot();
        v1PoolUsed = false;
        _;
        vm.revertTo(snapshot);
        v1PoolUsed = true;
        _;
    }

    function setUp() public {
        tokenTestSuite = new TokensTestSuite();

        tokenTestSuite.topUpWETH{value: 100 * WAD}();

        addressProvider = new AddressProviderV3ACLMock();

        addressProvider.setAddress(AP_WETH_TOKEN, tokenTestSuite.addressOf(Tokens.WETH), false);

        botListMock = BotListMock(addressProvider.getAddressOrRevert(AP_BOT_LIST, 3_00));

        withdrawalManagerMock = WithdrawalManagerMock(addressProvider.getAddressOrRevert(AP_WITHDRAWAL_MANAGER, 3_00));

        priceOracleMock = PriceOracleMock(addressProvider.getAddressOrRevert(AP_PRICE_ORACLE, 2));

        AddressProviderV3ACLMock(address(addressProvider)).addPausableAdmin(CONFIGURATOR);

        poolMock = new PoolMock(
            address(addressProvider),
            tokenTestSuite.addressOf(Tokens.DAI)
        );

        creditManagerMock = new CreditManagerMock({
            _addressProvider: address(addressProvider),
            _pool: address(poolMock)
        });

        creditManagerMock.setSupportsQuotas(true);
    }

    function _withoutDegenNFT() internal {
        degenNFTMock = DegenNFTMock(address(0));
    }

    function _withDegenNFT() internal {
        whitelisted = true;
        degenNFTMock = new DegenNFTMock();
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
        poolMock.setVersion(v1PoolUsed ? 1 : 3_00);
        creditFacade = new CreditFacadeV3Harness(
            address(creditManagerMock),
            address(degenNFTMock),
            expirable
        );

        creditManagerMock.setCreditFacade(address(creditFacade));
    }

    /// @dev U:[FA-1]: constructor sets correct values
    function test_U_FA_01_constructor_sets_correct_values() public allDegenNftCases allExpirableCases {
        assertEq(address(creditFacade.creditManager()), address(creditManagerMock), "Incorrect creditManager");

        assertEq(creditFacade.weth(), creditManagerMock.weth(), "Incorrect weth token");

        assertEq(creditFacade.withdrawalManager(), address(withdrawalManagerMock), "Incorrect withdrawalManager");

        assertEq(creditFacade.degenNFT(), address(degenNFTMock), "Incorrect degen NFT");
    }

    /// @dev U:[FA-2]: user functions revert if called on pause
    function test_U_FA_02_user_functions_revert_if_called_on_pause() public notExpirableCase {
        creditManagerMock.setBorrower(address(this));

        vm.prank(CONFIGURATOR);
        creditFacade.pause();

        vm.expectRevert("Pausable: paused");
        creditFacade.openCreditAccount({debt: 0, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});

        vm.expectRevert("Pausable: paused");
        creditFacade.closeCreditAccount({
            creditAccount: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });

        /// @notice We'll check that it works for emergency liquidatior as exceptions in another test
        vm.expectRevert("Pausable: paused");
        creditFacade.liquidateCreditAccount({
            creditAccount: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });

        vm.expectRevert("Pausable: paused");
        creditFacade.multicall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert("Pausable: paused");
        creditFacade.botMulticall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert("Pausable: paused");
        creditFacade.claimWithdrawals({creditAccount: DUMB_ADDRESS, to: DUMB_ADDRESS});
    }

    /// @dev U:[FA-3]: user functions revert if credit facade is expired
    function test_U_FA_03_user_functions_revert_if_credit_facade_is_expired() public expirableCase {
        vm.prank(CONFIGURATOR);
        creditFacade.setExpirationDate(uint40(block.timestamp));
        creditManagerMock.setBorrower(address(this));

        vm.warp(block.timestamp + 1);

        vm.expectRevert(NotAllowedAfterExpirationException.selector);
        creditFacade.openCreditAccount({debt: 0, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});

        vm.expectRevert(NotAllowedAfterExpirationException.selector);
        creditFacade.multicall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert(NotAllowedAfterExpirationException.selector);
        creditFacade.botMulticall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});
    }

    /// @dev U:[FA-4]: non-reentrancy works for all non-cofigurable functions
    function test_U_FA_04_non_reentrancy_works_for_all_non_cofigurable_functions() public notExpirableCase {
        creditFacade.setReentrancy(ENTERED);
        creditManagerMock.setBorrower(address(this));

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.openCreditAccount({debt: 0, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.closeCreditAccount({
            creditAccount: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.liquidateCreditAccount({
            creditAccount: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.multicall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.botMulticall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.claimWithdrawals({creditAccount: DUMB_ADDRESS, to: DUMB_ADDRESS});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.setBotPermissions({
            creditAccount: DUMB_ADDRESS,
            bot: DUMB_ADDRESS,
            permissions: 0,
            fundingAmount: 0,
            weeklyFundingAllowance: 0
        });
    }

    /// @dev U:[FA-5]: borrower related functions revert if called not by borrower
    function test_U_FA_05_borrower_related_functions_revert_if_called_not_by_borrower() public notExpirableCase {
        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditFacade.closeCreditAccount({
            creditAccount: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditFacade.liquidateCreditAccount({
            creditAccount: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditFacade.multicall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditFacade.claimWithdrawals({creditAccount: DUMB_ADDRESS, to: DUMB_ADDRESS});

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditFacade.setBotPermissions({
            creditAccount: DUMB_ADDRESS,
            bot: DUMB_ADDRESS,
            permissions: 0,
            fundingAmount: 0,
            weeklyFundingAllowance: 0
        });
    }

    /// @dev U:[FA-6]: all configurator functions revert if called by non-configurator
    function test_U_FA_06_all_configurator_functions_revert_if_called_by_non_configurator() public notExpirableCase {
        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setExpirationDate(0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setDebtLimits(0, 0, 0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setBotList(address(1));

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setCumulativeLossParams(0, false);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setTokenAllowance(address(0), AllowanceAction.ALLOW);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setEmergencyLiquidator(address(0), AllowanceAction.ALLOW);
    }

    /// @dev U:[FA-7]: payable functions wraps eth to msg.sender
    function test_U_FA_07_payable_functions_wraps_eth_to_msg_sender() public notExpirableCase {
        vm.deal(USER, 3 ether);

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1 ether, 9 ether, 9);

        vm.prank(USER);
        creditFacade.openCreditAccount{value: 1 ether}({
            debt: 1 ether,
            onBehalfOf: USER,
            calls: new MultiCall[](0),
            referralCode: 0
        });

        expectBalance({t: Tokens.WETH, holder: USER, expectedBalance: 1 ether});

        creditManagerMock.setBorrower(USER);

        vm.prank(USER);
        creditFacade.closeCreditAccount{value: 1 ether}({
            creditAccount: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });
        expectBalance({t: Tokens.WETH, holder: USER, expectedBalance: 2 ether});

        vm.prank(USER);
        creditFacade.multicall{value: 1 ether}({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        expectBalance({t: Tokens.WETH, holder: USER, expectedBalance: 3 ether});
    }

    //
    // OPEN CREDIT ACCOUNT
    //

    /// @dev U:[FA-8]: openCreditAccount reverts if out of limits
    function test_U_FA_08_openCreditAccount_reverts_if_out_of_limits(uint128 a, uint128 b)
        public
        withV1PoolTest
        notExpirableCase
    {
        vm.assume(a > 0 && b > 0);

        uint128 minDebt = uint128(Math.min(a, b));
        uint128 maxDebt = uint128(Math.max(a, b));
        uint8 multiplier = uint8((maxDebt % 255) + 1);

        vm.assume(maxDebt < type(uint128).max / 256);

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(minDebt, maxDebt, 0);

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        creditFacade.openCreditAccount({debt: minDebt - 1, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        creditFacade.openCreditAccount({debt: maxDebt + 1, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});

        creditFacade.setTotalBorrowedInBlock(maxDebt * multiplier - minDebt + 1);

        vm.expectRevert(BorrowedBlockLimitException.selector);
        creditFacade.openCreditAccount({debt: minDebt, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});

        if (v1PoolUsed) {
            vm.prank(CONFIGURATOR);
            creditFacade.setDebtLimits(minDebt, maxDebt, type(uint8).max);

            vm.prank(CONFIGURATOR);
            creditFacade.setTotalDebtParams(b - minDebt + 1, b);

            vm.expectRevert(CreditManagerCantBorrowException.selector);
            creditFacade.openCreditAccount({debt: minDebt, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});
        }
    }

    /// @dev U:[FA-9]: openCreditAccount reverts in whitelisted if user has no rights
    function test_U_FA_09_openCreditAccount_reverts_in_whitelisted_if_user_has_no_rights()
        public
        withDegenNFT
        notExpirableCase
    {
        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, 2, 2);

        vm.prank(USER);

        vm.expectRevert(ForbiddenInWhitelistedModeException.selector);
        creditFacade.openCreditAccount({debt: 1, onBehalfOf: FRIEND, calls: new MultiCall[](0), referralCode: 0});

        degenNFTMock.setRevertOnBurn(true);

        vm.prank(USER);
        vm.expectRevert(InsufficientBalanceException.selector);
        creditFacade.openCreditAccount({debt: 1, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});
    }

    /// @dev U:[FA-10]: openCreditAccount wokrs as expected
    function test_U_FA_10_openCreditAccount_works_as_expected() public withV1PoolTest notExpirableCase {
        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(100, 200, 1);

        uint256 debt = 200;

        {
            uint64 blockNow = 100;
            creditFacade.setLastBlockBorrowed(blockNow);

            vm.roll(blockNow);
        }

        uint256 debtInBlock = creditFacade.totalBorrowedInBlockInt();

        if (v1PoolUsed) {
            vm.prank(CONFIGURATOR);
            creditFacade.setTotalDebtParams(uint128(debt), uint128(debt * 2));
        }

        (uint256 totalDebt,) = creditFacade.totalDebt();

        address expectedCreditAccount = DUMB_ADDRESS;
        creditManagerMock.setReturnOpenCreditAccount(expectedCreditAccount);

        vm.expectCall(address(creditManagerMock), abi.encodeCall(ICreditManagerV3.openCreditAccount, (debt, FRIEND)));

        vm.expectEmit(true, true, true, true);
        emit OpenCreditAccount(expectedCreditAccount, FRIEND, USER, debt, REFERRAL_CODE);

        vm.expectEmit(true, true, false, false);
        emit StartMultiCall({creditAccount: expectedCreditAccount, caller: USER});

        vm.expectEmit(true, false, false, false);
        emit FinishMultiCall();

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck,
                (expectedCreditAccount, UNDERLYING_TOKEN_MASK, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount({
            debt: debt,
            onBehalfOf: FRIEND,
            calls: new MultiCall[](0),
            referralCode: REFERRAL_CODE
        });

        assertEq(creditAccount, expectedCreditAccount, "Incorrect credit account");
        assertEq(creditFacade.totalBorrowedInBlockInt(), debtInBlock + debt, "Debt in block was updated incorrectly");

        if (v1PoolUsed) {
            (uint256 totalDebtNow,) = creditFacade.totalDebt();

            assertEq(totalDebtNow, totalDebt + debt, "Incorrect total debt update");
        }
    }

    /// @dev U:[FA-11]: closeCreditAccount wokrs as expected
    function test_U_FA_11_closeCreditAccount_works_as_expected(uint256 enabledTokensMask)
        public
        withV1PoolTest
        notExpirableCase
    {
        address creditAccount = DUMB_ADDRESS;

        bool hasCalls = (getHash({value: enabledTokensMask, seed: 2}) % 2) == 0;
        bool hasBotPermissions = (getHash({value: enabledTokensMask, seed: 3}) % 2) == 0;

        uint256 LINK_TOKEN_MASK = 4;
        uint128 debt = uint128(getHash({value: enabledTokensMask, seed: 2})) / 2;

        if (v1PoolUsed) {
            vm.prank(CONFIGURATOR);
            creditFacade.setTotalDebtParams(uint128(debt) + 500, uint128(debt * 2));
        }

        address adapter = address(new AdapterMock(address(creditManagerMock), DUMB_ADDRESS));

        creditManagerMock.setContractAllowance({adapter: adapter, targetContract: DUMB_ADDRESS});

        MultiCall[] memory calls;

        creditManagerMock.setBorrower(USER);
        creditManagerMock.setFlagFor(creditAccount, BOT_PERMISSIONS_SET_FLAG, hasBotPermissions);

        CollateralDebtData memory collateralDebtData = CollateralDebtData({
            debt: debt,
            cumulativeIndexNow: getHash({value: enabledTokensMask, seed: 3}),
            cumulativeIndexLastUpdate: getHash({value: enabledTokensMask, seed: 4}),
            cumulativeQuotaInterest: uint128(getHash({value: enabledTokensMask, seed: 5})),
            accruedInterest: getHash({value: enabledTokensMask, seed: 6}),
            accruedFees: getHash({value: enabledTokensMask, seed: 7}),
            totalDebtUSD: 0,
            totalValue: 0,
            totalValueUSD: 0,
            twvUSD: 0,
            enabledTokensMask: enabledTokensMask,
            quotedTokensMask: 0,
            quotedTokens: new address[](0),
            // quotedLts: new uint16[](0),
            // quotas: new uint256[](0),
            _poolQuotaKeeper: address(0)
        });

        CollateralDebtData memory expectedCollateralDebtData = clone(collateralDebtData);

        if (hasCalls) {
            calls = MultiCallBuilder.build(
                MultiCall({target: adapter, callData: abi.encodeCall(AdapterMock.dumbCall, (LINK_TOKEN_MASK, 0))})
            );

            expectedCollateralDebtData.enabledTokensMask |= LINK_TOKEN_MASK;
        } else {
            creditManagerMock.setRevertOnActiveAccount(true);
        }

        creditManagerMock.setDebtAndCollateralData(collateralDebtData);

        bool convertToETH = (getHash({value: enabledTokensMask, seed: 1}) % 2) == 1;

        caseName =
            string.concat(caseName, "convertToETH = ", boolToStr(convertToETH), ", hasCalls = ", boolToStr(hasCalls));

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.calcDebtAndCollateral, (creditAccount, CollateralCalcTask.DEBT_ONLY))
        );

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.claimWithdrawals, (creditAccount, FRIEND, ClaimAction.FORCE_CLAIM))
        );

        uint256 skipTokenMask = getHash({value: enabledTokensMask, seed: 1});

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                ICreditManagerV3.closeCreditAccount,
                (
                    creditAccount,
                    ClosureAction.CLOSE_ACCOUNT,
                    expectedCollateralDebtData,
                    USER,
                    FRIEND,
                    skipTokenMask,
                    convertToETH
                )
            )
        );

        if (convertToETH) {
            vm.expectCall(
                address(withdrawalManagerMock),
                abi.encodeCall(IWithdrawalManagerV3.claimImmediateWithdrawal, (ETH_ADDRESS, FRIEND))
            );
        }

        if (hasBotPermissions) {
            vm.expectCall(address(botListMock), abi.encodeCall(IBotListV3.eraseAllBotPermissions, (creditAccount)));
        } else {
            botListMock.setRevertOnErase(true);
        }

        vm.expectEmit(true, true, true, true);
        emit CloseCreditAccount(creditAccount, USER, FRIEND);

        vm.prank(USER);
        creditFacade.closeCreditAccount({
            creditAccount: creditAccount,
            to: FRIEND,
            skipTokenMask: skipTokenMask,
            convertToETH: convertToETH,
            calls: calls
        });

        assertEq(
            creditManagerMock.closeCollateralDebtData(),
            expectedCollateralDebtData,
            _testCaseErr("Incorrect collateralDebtData")
        );

        if (v1PoolUsed) {
            (uint256 totalDebtNow,) = creditFacade.totalDebt();

            assertEq(totalDebtNow, 500, "Incorrect total debt update");
        }
    }

    //
    // LIQUIDATE CREDIT ACCOUNT
    //

    /// @dev U:[FA-12]: liquidateCreditAccount allows emergency liquidators when paused
    function test_U_FA_12_liquidateCreditAccount_allows_emergency_liquidators_when_paused() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        creditManagerMock.setBorrower(USER);

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.totalDebtUSD = 101;
        collateralDebtData.twvUSD = 100;

        creditManagerMock.setDebtAndCollateralData(collateralDebtData);

        vm.prank(CONFIGURATOR);
        creditFacade.pause();

        for (uint256 i = 0; i < 2; ++i) {
            bool isEmergencyLiquidator = i == 0;

            vm.prank(CONFIGURATOR);
            creditFacade.setEmergencyLiquidator(
                LIQUIDATOR, isEmergencyLiquidator ? AllowanceAction.ALLOW : AllowanceAction.FORBID
            );

            caseName = string.concat(caseName, "isEmergencyLiquidator = ", boolToStr(isEmergencyLiquidator));

            if (!isEmergencyLiquidator) {
                vm.expectRevert("Pausable: paused");
            }

            vm.prank(LIQUIDATOR);
            creditFacade.liquidateCreditAccount({
                creditAccount: creditAccount,
                to: FRIEND,
                skipTokenMask: 0,
                convertToETH: false,
                calls: new MultiCall[](0)
            });
        }
    }

    /// @dev U:[FA-13]: liquidateCreditAccount reverts if account has enough collateral
    function test_U_FA_13_liquidateCreditAccount_reverts_if_account_has_enough_collateral(uint40 timestamp)
        public
        allExpirableCases
    {
        address creditAccount = DUMB_ADDRESS;

        uint40 expiredAt = uint40(getHash({value: timestamp, seed: 1}) % type(uint40).max);

        if (expirable) {
            vm.prank(CONFIGURATOR);
            creditFacade.setExpirationDate(expiredAt);
        }

        creditManagerMock.setBorrower(USER);

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.totalDebtUSD = 100;
        collateralDebtData.twvUSD = 100;

        creditManagerMock.setDebtAndCollateralData(collateralDebtData);

        vm.warp(timestamp);

        bool isExpiredLiquidatable = expirable && (timestamp >= expiredAt);

        if (!isExpiredLiquidatable) {
            vm.expectRevert(CreditAccountNotLiquidatableException.selector);
        }

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount({
            creditAccount: creditAccount,
            to: FRIEND,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });
    }

    /// @dev U:[FA-14]: liquidateCreditAccount picks correct close action
    function test_U_FA_14_liquidateCreditAccount_picks_correct_close_action(uint40 timestamp)
        public
        allExpirableCases
    {
        address creditAccount = DUMB_ADDRESS;

        uint40 expiredAt = uint40(getHash({value: timestamp, seed: 1}) % type(uint40).max);

        if (expirable) {
            vm.prank(CONFIGURATOR);
            creditFacade.setExpirationDate(expiredAt);
        }

        creditManagerMock.setBorrower(USER);

        vm.warp(timestamp);

        bool isExpiredLiquidatable = expirable && (timestamp >= expiredAt);

        bool enoughCollateral;
        if (isExpiredLiquidatable) {
            enoughCollateral = (getHash({value: timestamp, seed: 3}) % 2) == 0;
        }

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.totalDebtUSD = 101;
        collateralDebtData.twvUSD = enoughCollateral ? 101 : 100;

        creditManagerMock.setDebtAndCollateralData(collateralDebtData);

        ClosureAction closeAction = (enoughCollateral && isExpiredLiquidatable)
            ? ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT
            : ClosureAction.LIQUIDATE_ACCOUNT;

        vm.expectEmit(true, true, true, true);
        emit LiquidateCreditAccount(creditAccount, USER, LIQUIDATOR, FRIEND, closeAction, 0);

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                ICreditManagerV3.closeCreditAccount,
                (creditAccount, closeAction, collateralDebtData, LIQUIDATOR, FRIEND, 0, false)
            )
        );

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount({
            creditAccount: creditAccount,
            to: FRIEND,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });
    }

    /// @dev U:[FA-15]: liquidateCreditAccount claims correct withdrawal amount and enable token
    function test_U_FA_15_liquidateCreditAccount_claims_correct_withdrawal_amount() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        uint256 cancelMask = 1 << 7;

        creditManagerMock.setBorrower(USER);

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.totalDebtUSD = 101;
        collateralDebtData.twvUSD = 100;

        creditManagerMock.setDebtAndCollateralData(collateralDebtData);
        creditManagerMock.setClaimWithdrawals(cancelMask);

        vm.prank(CONFIGURATOR);
        creditFacade.setEmergencyLiquidator(LIQUIDATOR, AllowanceAction.ALLOW);

        CollateralDebtData memory expectedCollateralDebtData = clone(collateralDebtData);
        expectedCollateralDebtData.enabledTokensMask = cancelMask;

        for (uint256 i = 0; i < 2; ++i) {
            uint256 snapshot = vm.snapshot();
            bool isEmergencyLiquidation = i == 1;

            if (isEmergencyLiquidation) {
                vm.prank(CONFIGURATOR);
                creditFacade.pause();
            }

            caseName = string.concat(caseName, "isEmergencyLiquidation = ", boolToStr(isEmergencyLiquidation));

            vm.expectCall(
                address(creditManagerMock),
                abi.encodeCall(
                    ICreditManagerV3.calcDebtAndCollateral,
                    (
                        creditAccount,
                        isEmergencyLiquidation
                            ? CollateralCalcTask.DEBT_COLLATERAL_FORCE_CANCEL_WITHDRAWALS
                            : CollateralCalcTask.DEBT_COLLATERAL_CANCEL_WITHDRAWALS
                    )
                )
            );

            vm.expectCall(
                address(creditManagerMock),
                abi.encodeCall(
                    ICreditManagerV3.claimWithdrawals,
                    (creditAccount, USER, isEmergencyLiquidation ? ClaimAction.FORCE_CANCEL : ClaimAction.CANCEL)
                )
            );

            vm.prank(LIQUIDATOR);
            creditFacade.liquidateCreditAccount({
                creditAccount: creditAccount,
                to: FRIEND,
                skipTokenMask: 0,
                convertToETH: false,
                calls: new MultiCall[](0)
            });

            assertEq(
                creditManagerMock.closeCollateralDebtData(),
                expectedCollateralDebtData,
                _testCaseErr("Incorrect collateralDebtData")
            );

            vm.revertTo(snapshot);
        }
    }

    /// @dev U:[FA-16]: liquidate wokrs as expected
    function test_U_FA_16_liquidate_wokrs_as_expected(uint256 enabledTokensMask)
        public
        withV1PoolTest
        notExpirableCase
    {
        address creditAccount = DUMB_ADDRESS;

        bool hasCalls = (getHash({value: enabledTokensMask, seed: 2}) % 2) == 0;
        bool hasBotPermissions = (getHash({value: enabledTokensMask, seed: 3}) % 2) == 0;

        uint128 debt = uint128(getHash({value: enabledTokensMask, seed: 2})) / 2;

        if (v1PoolUsed) {
            vm.prank(CONFIGURATOR);
            creditFacade.setTotalDebtParams(uint128(debt) + 500, uint128(debt * 2));
        }

        uint256 cancelMask = 1 << 7;
        uint256 LINK_TOKEN_MASK = 4;

        address adapter = address(new AdapterMock(address(creditManagerMock), DUMB_ADDRESS));

        creditManagerMock.setContractAllowance({adapter: adapter, targetContract: DUMB_ADDRESS});

        MultiCall[] memory calls;

        creditManagerMock.setBorrower(USER);
        creditManagerMock.setFlagFor(creditAccount, BOT_PERMISSIONS_SET_FLAG, hasBotPermissions);

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.debt = debt;
        collateralDebtData.totalDebtUSD = 101;
        collateralDebtData.twvUSD = 100;

        creditManagerMock.setDebtAndCollateralData(collateralDebtData);
        creditManagerMock.setClaimWithdrawals(cancelMask);

        vm.prank(CONFIGURATOR);
        creditFacade.setEmergencyLiquidator(LIQUIDATOR, AllowanceAction.ALLOW);

        CollateralDebtData memory expectedCollateralDebtData = clone(collateralDebtData);
        expectedCollateralDebtData.enabledTokensMask = cancelMask;

        if (hasCalls) {
            calls = MultiCallBuilder.build(
                MultiCall({target: adapter, callData: abi.encodeCall(AdapterMock.dumbCall, (LINK_TOKEN_MASK, 0))})
            );

            expectedCollateralDebtData.enabledTokensMask |= LINK_TOKEN_MASK;
        } else {
            creditManagerMock.setRevertOnActiveAccount(true);
        }

        bool convertToETH = (getHash({value: enabledTokensMask, seed: 1}) % 2) == 1;

        caseName =
            string.concat(caseName, "convertToETH = ", boolToStr(convertToETH), ", hasCalls = ", boolToStr(hasCalls));

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                ICreditManagerV3.calcDebtAndCollateral,
                (creditAccount, CollateralCalcTask.DEBT_COLLATERAL_CANCEL_WITHDRAWALS)
            )
        );

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.claimWithdrawals, (creditAccount, USER, ClaimAction.CANCEL))
        );

        uint256 skipTokenMask = getHash({value: enabledTokensMask, seed: 1});

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                ICreditManagerV3.closeCreditAccount,
                (
                    creditAccount,
                    ClosureAction.LIQUIDATE_ACCOUNT,
                    expectedCollateralDebtData,
                    LIQUIDATOR,
                    FRIEND,
                    skipTokenMask,
                    convertToETH
                )
            )
        );

        if (convertToETH) {
            vm.expectCall(
                address(withdrawalManagerMock),
                abi.encodeCall(IWithdrawalManagerV3.claimImmediateWithdrawal, (ETH_ADDRESS, FRIEND))
            );
        }

        if (hasBotPermissions) {
            vm.expectCall(address(botListMock), abi.encodeCall(IBotListV3.eraseAllBotPermissions, (creditAccount)));
        } else {
            botListMock.setRevertOnErase(true);
        }
        creditManagerMock.setCloseCreditAccountReturns(1_000, 0);

        vm.expectEmit(true, true, true, true);
        emit LiquidateCreditAccount(creditAccount, USER, LIQUIDATOR, FRIEND, ClosureAction.LIQUIDATE_ACCOUNT, 1_000);

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount({
            creditAccount: creditAccount,
            to: FRIEND,
            skipTokenMask: skipTokenMask,
            convertToETH: convertToETH,
            calls: calls
        });

        assertEq(
            creditManagerMock.closeCollateralDebtData(),
            expectedCollateralDebtData,
            _testCaseErr("Incorrect collateralDebtData")
        );

        if (v1PoolUsed) {
            (uint256 totalDebtNow,) = creditFacade.totalDebt();

            assertEq(totalDebtNow, 500, "Incorrect total debt update");
        }
    }

    /// @dev U:[FA-17]: liquidate correctly computes cumulative loss and pause contract if needed
    function test_U_FA_17_liquidate_correctly_computes_cumulative_loss_and_pause_contract_if_needed(uint128 maxLoss)
        public
        notExpirableCase
    {
        vm.assume(maxLoss > 0 && maxLoss < type(uint120).max);

        address creditAccount = DUMB_ADDRESS;

        MultiCall[] memory calls;

        vm.prank(CONFIGURATOR);
        creditFacade.setCumulativeLossParams(maxLoss, true);

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, 100, 10);

        assertEq(creditFacade.maxDebtPerBlockMultiplier(), 10, "SETUP: incorrect  maxDebtPerBlockMultiplier");

        uint256 step = maxLoss / ((getHash(maxLoss, 3) % 5) + 1) + 1;

        uint256 expectedCumulativeLoss;

        creditManagerMock.setBorrower(USER);

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.totalDebtUSD = 101;
        collateralDebtData.twvUSD = 100;

        creditManagerMock.setDebtAndCollateralData(collateralDebtData);
        creditManagerMock.setClaimWithdrawals(0);

        creditManagerMock.setCloseCreditAccountReturns(1000, step);

        do {
            vm.expectCall(
                address(creditManagerMock),
                abi.encodeCall(
                    ICreditManagerV3.closeCreditAccount,
                    (creditAccount, ClosureAction.LIQUIDATE_ACCOUNT, collateralDebtData, LIQUIDATOR, FRIEND, 0, false)
                )
            );

            vm.expectEmit(true, true, true, true);
            emit LiquidateCreditAccount(creditAccount, USER, LIQUIDATOR, FRIEND, ClosureAction.LIQUIDATE_ACCOUNT, 1_000);

            vm.prank(LIQUIDATOR);
            creditFacade.liquidateCreditAccount({
                creditAccount: creditAccount,
                to: FRIEND,
                skipTokenMask: 0,
                convertToETH: false,
                calls: calls
            });

            assertEq(creditFacade.maxDebtPerBlockMultiplier(), 0, "maxDebtPerBlockMultiplier wasnt set to zero");

            (uint128 currentCumulativeLoss,) = creditFacade.lossParams();

            expectedCumulativeLoss += step;

            assertEq(currentCumulativeLoss, expectedCumulativeLoss, "Incorrect currentCumulativeLoss");

            bool shoudBePaused = expectedCumulativeLoss > maxLoss;

            assertEq(creditFacade.paused(), shoudBePaused, "Paused wasn't set");
        } while (expectedCumulativeLoss < maxLoss);
    }

    //
    //
    // MULTICALL
    //
    //

    /// @dev U:[FA-18]: multicall execute calls and call fullCollateralCheck
    function test_U_FA_18_multicall_and_botMulticall_execute_calls_and_call_fullCollateralCheck()
        public
        notExpirableCase
    {
        address creditAccount = DUMB_ADDRESS;
        MultiCall[] memory calls;

        uint256 enabledTokensMaskBefore = 123123123;

        botListMock.setBotStatusReturns(ALL_PERMISSIONS, false);

        creditManagerMock.setEnabledTokensMask(enabledTokensMaskBefore);
        creditManagerMock.setBorrower(USER);

        uint256 enabledTokensMaskAfter = enabledTokensMaskBefore;

        for (uint256 testCase = 0; testCase < 2; ++testCase) {
            bool botMulticallCase = testCase == 1;

            vm.expectCall(
                address(creditManagerMock),
                abi.encodeCall(
                    ICreditManagerV3.fullCollateralCheck,
                    (creditAccount, enabledTokensMaskAfter, new uint256[](0), PERCENTAGE_FACTOR)
                )
            );

            vm.expectEmit(true, true, false, false);
            emit StartMultiCall({creditAccount: creditAccount, caller: botMulticallCase ? address(this) : USER});

            vm.expectEmit(true, false, false, false);
            emit FinishMultiCall();

            if (botMulticallCase) {
                creditFacade.botMulticall(creditAccount, calls);
            } else {
                vm.prank(USER);
                creditFacade.multicall(creditAccount, calls);
            }
        }
    }

    /// @dev U:[FA-19]: botMulticall reverts if bot forbidden or has no permission
    function test_U_FA_19_botMulticall_reverts_if_bot_forbidden_or_has_no_permission() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;
        MultiCall[] memory calls;

        botListMock.setBotStatusReturns(ALL_PERMISSIONS, true);

        vm.expectRevert(NotApprovedBotException.selector);
        creditFacade.botMulticall(creditAccount, calls);

        botListMock.setBotStatusReturns(0, false);

        vm.expectRevert(NotApprovedBotException.selector);
        creditFacade.botMulticall(creditAccount, calls);
    }

    /// @dev U:[FA-20]: only botMulticall doesn't revert for pay bot call
    function test_U_FA_20_only_botMulticall_doesnt_revert_for_pay_bot_call() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, 100, 1);

        creditManagerMock.setBorrower(USER);
        botListMock.setBotStatusReturns(ALL_PERMISSIONS, false);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(creditFacade), callData: abi.encodeCall(ICreditFacadeV3Multicall.payBot, (1))})
        );

        vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, PAY_BOT_CAN_BE_CALLED));
        creditFacade.openCreditAccount({debt: 1, onBehalfOf: USER, calls: calls, referralCode: 0});

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, PAY_BOT_CAN_BE_CALLED));
        creditFacade.multicall(creditAccount, calls);

        /// Case: it works for bot multicall
        creditFacade.botMulticall(creditAccount, calls);
    }

    struct MultiCallPermissionTestCase {
        bytes callData;
        uint256 permissionRquired;
    }

    /// @dev U:[FA-21]: multicall reverts if called without particaular permission
    function test_U_FA_21_multicall_reverts_if_called_without_particaular_permission() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        address token = tokenTestSuite.addressOf(Tokens.LINK);
        creditManagerMock.addToken(token, 1 << 4);

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, 100, 1);

        creditManagerMock.setManageDebt(2, 0, 0);

        creditManagerMock.setPriceOracle(address(priceOracleMock));

        address priceFeedOnDemandMock = address(new PriceFeedOnDemandMock());

        priceOracleMock.setPriceFeed(token, priceFeedOnDemandMock);

        creditManagerMock.setBorrower(USER);

        MultiCallPermissionTestCase[12] memory cases = [
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.revertIfReceivedLessThan, (new Balance[](0))),
                permissionRquired: 0
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.enableToken, (token)),
                permissionRquired: ENABLE_TOKEN_PERMISSION
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.disableToken, (token)),
                permissionRquired: DISABLE_TOKEN_PERMISSION
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (token, 0)),
                permissionRquired: ADD_COLLATERAL_PERMISSION
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (1)),
                permissionRquired: INCREASE_DEBT_PERMISSION
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (0)),
                permissionRquired: DECREASE_DEBT_PERMISSION
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (token, 0, 0)),
                permissionRquired: UPDATE_QUOTA_PERMISSION
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.setFullCheckParams, (new uint256[](0), 10_001)),
                permissionRquired: 0
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.scheduleWithdrawal, (token, 0)),
                permissionRquired: WITHDRAW_PERMISSION
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.revokeAdapterAllowances, (new RevocationPair[](0))),
                permissionRquired: REVOKE_ALLOWANCES_PERMISSION
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.onDemandPriceUpdate, (token, bytes(""))),
                permissionRquired: 0
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.payBot, (0)),
                permissionRquired: PAY_BOT_CAN_BE_CALLED
            })
        ];

        uint256 len = cases.length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 cur_flags = type(uint256).max.disable(cases[i].permissionRquired);
            for (uint256 j = 0; j < len; ++j) {
                if (i == j && cases[i].permissionRquired != 0) {
                    vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, cases[i].permissionRquired));
                }
                creditFacade.multicallInt({
                    creditAccount: creditAccount,
                    calls: MultiCallBuilder.build(MultiCall({target: address(creditFacade), callData: cases[j].callData})),
                    enabledTokensMask: 0,
                    flags: cur_flags
                });
            }
        }

        uint256 flags = type(uint256).max.disable(EXTERNAL_CALLS_PERMISSION);

        vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, EXTERNAL_CALLS_PERMISSION));
        creditFacade.multicallInt(
            creditAccount, MultiCallBuilder.build(MultiCall({target: DUMB_ADDRESS4, callData: bytes("")})), 0, flags
        );
    }

    /// @dev U:[FA-22]: multicall reverts if called without particaular permission
    function test_U_FA_22_multicall_reverts_if_called_without_particaular_permission() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        vm.expectRevert(UnknownMethodException.selector);
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(MultiCall({target: address(creditFacade), callData: bytes("123")})),
            enabledTokensMask: 0,
            flags: 0
        });
    }

    /// @dev U:[FA-23]: multicall revertIfReceivedLessThan works properly
    function test_U_FA_23_multicall_revertIfReceivedLessThan_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        address link = tokenTestSuite.addressOf(Tokens.LINK);
        Balance[] memory expectedBalance = new Balance[](1);

        address acm = address(new AdapterCallMock());

        creditManagerMock.setContractAllowance(acm, DUMB_ADDRESS3);

        ERC20Mock(link).set_minter(acm);

        for (uint256 testCase = 0; testCase < 4; ++testCase) {
            /// case 0: no revert if expected 0
            /// case 1: reverts because expect 1
            /// case 2: no reverty because expect 1 and it mints 1 duyring the call
            /// case 3: reverts because called twice

            expectedBalance[0] = Balance({token: link, balance: testCase > 0 ? 1 : 0});

            MultiCall[] memory calls = MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.revertIfReceivedLessThan, (expectedBalance))
                })
            );

            if (testCase == 1) {
                vm.expectRevert(BalanceLessThanMinimumDesiredException.selector);
            }

            if (testCase == 2) {
                calls = MultiCallBuilder.build(
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.revertIfReceivedLessThan, (expectedBalance))
                    }),
                    MultiCall({
                        target: acm,
                        callData: abi.encodeCall(
                            AdapterCallMock.makeCall, (link, abi.encodeCall(ERC20Mock.mint, (creditAccount, 1)))
                            )
                    })
                );
            }

            if (testCase == 3) {
                calls = MultiCallBuilder.build(
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.revertIfReceivedLessThan, (expectedBalance))
                    }),
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.revertIfReceivedLessThan, (expectedBalance))
                    })
                );
                vm.expectRevert(ExpectedBalancesAlreadySetException.selector);
            }

            creditFacade.multicallInt({
                creditAccount: creditAccount,
                calls: calls,
                enabledTokensMask: 0,
                flags: EXTERNAL_CALLS_PERMISSION
            });
        }
    }

    /// @dev U:[FA-24]: multicall setFullCheckParams works properly
    function test_U_FA_24_multicall_setFullCheckParams_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        uint256[] memory collateralHints = new uint256[](2);

        collateralHints[0] = 2323;
        collateralHints[1] = 8823;

        uint16 hf = 12_320;

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.setFullCheckParams, (collateralHints, hf))
            })
        );

        FullCheckParams memory fullCheckParams =
            creditFacade.multicallInt({creditAccount: creditAccount, calls: calls, enabledTokensMask: 0, flags: 0});

        assertEq(fullCheckParams.minHealthFactor, hf, "Incorrect hf");
        assertEq(fullCheckParams.collateralHints, collateralHints, "Incorrect collateralHints");
    }

    /// @dev U:[FA-25]: multicall onDemandPriceUpdate works properly
    function test_U_FA_25_multicall_onDemandPriceUpdate_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;
        bytes memory cd = bytes("Hellew");

        address token = tokenTestSuite.addressOf(Tokens.LINK);

        creditManagerMock.setPriceOracle(address(priceOracleMock));

        address priceFeedOnDemandMock = address(new PriceFeedOnDemandMock());

        priceOracleMock.setPriceFeed(token, priceFeedOnDemandMock);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.onDemandPriceUpdate, (token, cd))
            })
        );

        vm.expectCall(address(priceOracleMock), abi.encodeCall(IPriceOracleV2.priceFeeds, (token)));
        vm.expectCall(address(priceFeedOnDemandMock), abi.encodeCall(PriceFeedOnDemandMock.updatePrice, (cd)));
        creditFacade.multicallInt({creditAccount: creditAccount, calls: calls, enabledTokensMask: 0, flags: 0});

        /// @notice it reverts for zero value
        calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.onDemandPriceUpdate, (DUMB_ADDRESS, cd))
            })
        );

        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        creditFacade.multicallInt({creditAccount: creditAccount, calls: calls, enabledTokensMask: 0, flags: 0});
    }

    /// @dev U:[FA-26]: multicall addCollateral works properly
    function test_U_FA_26_multicall_addCollateral_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        address token = tokenTestSuite.addressOf(Tokens.LINK);
        uint256 amount = 12333345;
        uint256 mask = 1 << 5;

        creditManagerMock.setAddCollateral(mask);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (token, amount))
            })
        );

        string memory caseNameBak = caseName;

        for (uint256 testCase = 0; testCase < 2; ++testCase) {
            caseName = string.concat(caseNameBak, testCase == 0 ? "not in quoted mask" : "in quoted mask");

            creditManagerMock.setQuotedTokensMask(testCase == 0 ? 0 : mask);

            vm.expectCall(
                address(creditManagerMock),
                abi.encodeCall(ICreditManagerV3.addCollateral, (address(this), creditAccount, token, amount))
            );

            vm.expectEmit(true, true, true, true);
            emit AddCollateral(creditAccount, token, amount);

            FullCheckParams memory fullCheckParams = creditFacade.multicallInt({
                creditAccount: creditAccount,
                calls: calls,
                enabledTokensMask: UNDERLYING_TOKEN_MASK,
                flags: ADD_COLLATERAL_PERMISSION
            });

            assertEq(
                fullCheckParams.enabledTokensMaskAfter,
                testCase == 0 ? (mask | UNDERLYING_TOKEN_MASK) : UNDERLYING_TOKEN_MASK,
                _testCaseErr("Incorrect enabledTokenMask")
            );
        }
    }

    /// @dev U:[FA-27]: multicall increaseDebt works properly
    function test_U_FA_27_multicall_increaseDebt_works_properly() public withV1PoolTest notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        uint256 amount = 50;

        uint256 mask = 1232322;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, 100, 1);

        {
            uint64 blockNow = 100;
            creditFacade.setLastBlockBorrowed(blockNow);

            vm.roll(blockNow);
        }

        uint256 debtInBlock = creditFacade.totalBorrowedInBlockInt();

        if (v1PoolUsed) {
            vm.prank(CONFIGURATOR);
            creditFacade.setTotalDebtParams(uint128(amount), uint128(amount * 2));
        }

        (uint256 totalDebt,) = creditFacade.totalDebt();

        creditManagerMock.setManageDebt({newDebt: 50, tokensToEnable: UNDERLYING_TOKEN_MASK, tokensToDisable: 0});

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (amount))
            })
        );

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.manageDebt, (creditAccount, amount, mask, ManageDebtAction.INCREASE_DEBT))
        );

        vm.expectEmit(true, true, false, false);
        emit IncreaseDebt(creditAccount, amount);

        FullCheckParams memory fullCheckParams = creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: calls,
            enabledTokensMask: mask,
            flags: INCREASE_DEBT_PERMISSION
        });

        assertEq(
            fullCheckParams.enabledTokensMaskAfter,
            mask | UNDERLYING_TOKEN_MASK,
            _testCaseErr("Incorrect enabledTokenMask")
        );

        assertEq(creditFacade.totalBorrowedInBlockInt(), debtInBlock + amount, "Debt in block was updated incorrectly");

        if (v1PoolUsed) {
            (uint256 totalDebtNow,) = creditFacade.totalDebt();

            assertEq(totalDebtNow, totalDebt + amount, "Incorrect total debt update");
        }
    }

    /// @dev U:[FA-28]: multicall increaseDebt reverts if out of debt
    function test_U_FA_28_multicall_increaseDebt_reverts_if_out_of_debt() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        uint128 maxDebt = 100;

        uint256 mask = 1232322;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, maxDebt, 1);

        creditManagerMock.setManageDebt({newDebt: 50, tokensToEnable: UNDERLYING_TOKEN_MASK, tokensToDisable: 0});

        vm.expectRevert(BorrowedBlockLimitException.selector);
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (maxDebt + 1))
                })
                ),
            enabledTokensMask: mask,
            flags: INCREASE_DEBT_PERMISSION
        });

        creditManagerMock.setManageDebt({
            newDebt: maxDebt + 1,
            tokensToEnable: UNDERLYING_TOKEN_MASK,
            tokensToDisable: 0
        });

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (1))
                })
                ),
            enabledTokensMask: mask,
            flags: INCREASE_DEBT_PERMISSION
        });
    }

    /// @dev U:[FA-29]: multicall decrease debt reverts after increase debt
    function test_U_FA_29_multicall_decrease_debt_reverts_after_increase_debt() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, 100, 1);

        creditManagerMock.setManageDebt({newDebt: 50, tokensToEnable: UNDERLYING_TOKEN_MASK, tokensToDisable: 0});

        vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, DECREASE_DEBT_PERMISSION));

        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (10))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (1))
                })
                ),
            enabledTokensMask: 0,
            flags: INCREASE_DEBT_PERMISSION | DECREASE_DEBT_PERMISSION
        });
    }

    /// @dev U:[FA-30]: multicall increase debt if forbid tokens on account
    function test_U_FA_30_multicall_increase_debt_if_forbid_tokens_on_account() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        address link = tokenTestSuite.addressOf(Tokens.LINK);
        uint256 linkMask = 1 << 8;

        creditManagerMock.addToken(link, linkMask);

        vm.prank(CONFIGURATOR);
        creditFacade.setTokenAllowance(link, AllowanceAction.FORBID);

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, 100, 1);

        creditManagerMock.setManageDebt({newDebt: 50, tokensToEnable: UNDERLYING_TOKEN_MASK, tokensToDisable: 0});

        vm.expectRevert(ForbiddenTokensException.selector);
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(),
            enabledTokensMask: linkMask,
            flags: INCREASE_DEBT_WAS_CALLED
        });

        vm.expectRevert(ForbiddenTokensException.selector);
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (10))
                })
                ),
            enabledTokensMask: linkMask,
            flags: INCREASE_DEBT_PERMISSION
        });
    }

    ///

    /// @dev U:[FA-31]: multicall decreaseDebt works properly
    function test_U_FA_31_multicall_decreaseDebt_works_properly() public withV1PoolTest notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        uint256 amount = 50;

        uint256 mask = 1232322 | UNDERLYING_TOKEN_MASK;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, 100, 1);

        if (v1PoolUsed) {
            vm.prank(CONFIGURATOR);
            creditFacade.setTotalDebtParams(uint128(amount), uint128(amount * 2));
        }

        (uint256 totalDebt,) = creditFacade.totalDebt();

        creditManagerMock.setManageDebt({newDebt: 50, tokensToEnable: 0, tokensToDisable: UNDERLYING_TOKEN_MASK});

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.manageDebt, (creditAccount, amount, mask, ManageDebtAction.DECREASE_DEBT))
        );

        vm.expectEmit(true, true, false, false);
        emit DecreaseDebt(creditAccount, amount);

        FullCheckParams memory fullCheckParams = creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (amount))
                })
                ),
            enabledTokensMask: mask,
            flags: DECREASE_DEBT_PERMISSION
        });

        assertEq(
            fullCheckParams.enabledTokensMaskAfter,
            mask & (~UNDERLYING_TOKEN_MASK),
            _testCaseErr("Incorrect enabledTokenMask")
        );

        if (v1PoolUsed) {
            (uint256 totalDebtNow,) = creditFacade.totalDebt();

            assertEq(totalDebtNow, totalDebt - amount, "Incorrect total debt update");
        }
    }

    /// @dev U:[FA-32]: multicall decreaseDebt reverts if out of debt
    function test_U_FA_32_multicall_decreaseDebt_reverts_if_out_of_debt() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        uint128 minDebt = 100;

        uint256 mask = 1232322;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(minDebt, minDebt + 100, 1);

        creditManagerMock.setManageDebt({
            newDebt: minDebt - 1,
            tokensToEnable: 0,
            tokensToDisable: UNDERLYING_TOKEN_MASK
        });

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (1))
                })
                ),
            enabledTokensMask: mask,
            flags: DECREASE_DEBT_PERMISSION
        });
    }

    /// @dev U:[FA-33]: multicall enableToken works properly
    function test_U_FA_33_multicall_enableToken_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        address link = tokenTestSuite.addressOf(Tokens.LINK);
        uint256 mask = 1 << 5;

        creditManagerMock.addToken(link, mask);

        string memory caseNameBak = caseName;

        for (uint256 testCase = 0; testCase < 2; ++testCase) {
            caseName = string.concat(caseNameBak, testCase == 0 ? "not in quoted mask" : "in quoted mask");

            creditManagerMock.setQuotedTokensMask(testCase == 0 ? 0 : mask);

            FullCheckParams memory fullCheckParams = creditFacade.multicallInt({
                creditAccount: creditAccount,
                calls: MultiCallBuilder.build(
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.enableToken, (link))
                    })
                    ),
                enabledTokensMask: UNDERLYING_TOKEN_MASK,
                flags: ENABLE_TOKEN_PERMISSION
            });

            assertEq(
                fullCheckParams.enabledTokensMaskAfter,
                testCase == 0 ? (mask | UNDERLYING_TOKEN_MASK) : UNDERLYING_TOKEN_MASK,
                _testCaseErr("Incorrect enabledTokenMask for enableToken")
            );

            fullCheckParams = creditFacade.multicallInt({
                creditAccount: creditAccount,
                calls: MultiCallBuilder.build(
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.disableToken, (link))
                    })
                    ),
                enabledTokensMask: UNDERLYING_TOKEN_MASK | mask,
                flags: DISABLE_TOKEN_PERMISSION
            });

            assertEq(
                fullCheckParams.enabledTokensMaskAfter,
                testCase == 0 ? UNDERLYING_TOKEN_MASK : (mask | UNDERLYING_TOKEN_MASK),
                _testCaseErr("Incorrect enabledTokenMask for disableToken")
            );
        }
    }

    /// @dev U:[FA-34]: multicall updateQuota works properly
    function test_U_FA_34_multicall_updateQuota_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        uint96 maxDebt = 443330;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(0, maxDebt, type(uint8).max);

        address link = tokenTestSuite.addressOf(Tokens.LINK);
        uint256 maskToEnable = 1 << 4;
        uint256 maskToDisable = 1 << 7;

        int96 change = -990;

        creditManagerMock.setUpdateQuota({change: change, tokensToEnable: maskToEnable, tokensToDisable: maskToDisable});

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                ICreditManagerV3.updateQuota,
                (creditAccount, link, change, 0, uint96(maxDebt * creditFacade.maxQuotaMultiplier()))
            )
        );

        FullCheckParams memory fullCheckParams = creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (link, change, 0))
                })
                ),
            enabledTokensMask: maskToDisable | UNDERLYING_TOKEN_MASK,
            flags: UPDATE_QUOTA_PERMISSION
        });

        assertEq(
            fullCheckParams.enabledTokensMaskAfter,
            maskToEnable | UNDERLYING_TOKEN_MASK,
            _testCaseErr("Incorrect enabledTokenMask")
        );
    }

    /// @dev U:[FA-35]: multicall `scheduleWithdrawal` works properly
    function test_U_FA_35_multicall_scheduleWithdrawal_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        address link = tokenTestSuite.addressOf(Tokens.LINK);
        uint256 maskToDisable = 1 << 7;

        uint256 amount = 100;
        creditManagerMock.setScheduleWithdrawal({tokensToDisable: maskToDisable});

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.scheduleWithdrawal, (creditAccount, link, amount))
        );

        FullCheckParams memory fullCheckParams = creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.scheduleWithdrawal, (link, amount))
                })
                ),
            enabledTokensMask: maskToDisable | UNDERLYING_TOKEN_MASK,
            flags: WITHDRAW_PERMISSION
        });

        assertEq(
            fullCheckParams.enabledTokensMaskAfter, UNDERLYING_TOKEN_MASK, _testCaseErr("Incorrect enabledTokenMask")
        );
    }

    /// @dev U:[FA-36]: multicall revokeAdapterAllowances works properly
    function test_U_FA_36_multicall_revokeAdapterAllowances_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        RevocationPair[] memory rp = new RevocationPair[](1);
        rp[0].token = tokenTestSuite.addressOf(Tokens.LINK);
        rp[0].spender = DUMB_ADDRESS;

        vm.expectCall(
            address(creditManagerMock), abi.encodeCall(ICreditManagerV3.revokeAdapterAllowances, (creditAccount, rp))
        );

        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.revokeAdapterAllowances, (rp))
                })
                ),
            enabledTokensMask: 0,
            flags: REVOKE_ALLOWANCES_PERMISSION
        });
    }

    /// @dev U:[FA-37]: multicall payBot works properly
    function test_U_FA_37_multicall_payBot_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        creditManagerMock.setBorrower(USER);

        uint72 paymentAmount = 100_000;

        address bot = makeAddr("BOT");
        vm.expectCall(
            address(botListMock), abi.encodeCall(IBotListV3.payBot, (USER, creditAccount, bot, paymentAmount))
        );

        vm.prank(bot);
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.payBot, (paymentAmount))
                })
                ),
            enabledTokensMask: 0,
            flags: PAY_BOT_CAN_BE_CALLED
        });

        vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, PAY_BOT_CAN_BE_CALLED));
        vm.prank(bot);
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.payBot, (paymentAmount))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.payBot, (paymentAmount))
                })
                ),
            enabledTokensMask: 0,
            flags: PAY_BOT_CAN_BE_CALLED
        });
    }

    struct ExternalCallTestCase {
        string name;
        uint256 quotedTokensMask;
        uint256 tokenMaskBefore;
        uint256 expectedTokensMaskAfter;
    }

    /// @dev U:[FA-38]: multicall external calls works properly
    function test_U_FA_38_multicall_external_calls_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        creditManagerMock.setBorrower(USER);

        address adapter = address(new AdapterMock(address(creditManagerMock), DUMB_ADDRESS));

        creditManagerMock.setContractAllowance({adapter: adapter, targetContract: DUMB_ADDRESS});

        uint256 tokensToEnable = 1 << 4;
        uint256 tokensToDisable = 1 << 7;

        ExternalCallTestCase[3] memory cases = [
            ExternalCallTestCase({
                name: "not in quoted mask",
                quotedTokensMask: 0,
                tokenMaskBefore: UNDERLYING_TOKEN_MASK | tokensToDisable,
                expectedTokensMaskAfter: UNDERLYING_TOKEN_MASK | tokensToEnable
            }),
            ExternalCallTestCase({
                name: "in quoted mask, mask is tokensToEnable",
                quotedTokensMask: tokensToEnable,
                tokenMaskBefore: UNDERLYING_TOKEN_MASK | tokensToDisable,
                expectedTokensMaskAfter: UNDERLYING_TOKEN_MASK
            }),
            ExternalCallTestCase({
                name: "in quoted mask, mask is tokensToDisable",
                quotedTokensMask: tokensToDisable,
                tokenMaskBefore: UNDERLYING_TOKEN_MASK | tokensToDisable,
                expectedTokensMaskAfter: UNDERLYING_TOKEN_MASK | tokensToEnable | tokensToDisable
            })
        ];

        uint256 len = cases.length;

        for (uint256 testCase = 0; testCase < len; ++testCase) {
            uint256 snapshot = vm.snapshot();

            ExternalCallTestCase memory _case = cases[testCase];

            caseName = string.concat(caseName, _case.name);
            creditManagerMock.setQuotedTokensMask(_case.quotedTokensMask);

            vm.expectCall(adapter, abi.encodeCall(AdapterMock.dumbCall, (tokensToEnable, tokensToDisable)));

            vm.expectCall(
                address(creditManagerMock), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (creditAccount))
            );

            vm.expectCall(
                address(creditManagerMock), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (address(1)))
            );

            FullCheckParams memory fullCheckParams = creditFacade.multicallInt({
                creditAccount: creditAccount,
                calls: MultiCallBuilder.build(
                    MultiCall({
                        target: adapter,
                        callData: abi.encodeCall(AdapterMock.dumbCall, (tokensToEnable, tokensToDisable))
                    })
                    ),
                enabledTokensMask: _case.tokenMaskBefore,
                flags: EXTERNAL_CALLS_PERMISSION
            });

            assertEq(
                fullCheckParams.enabledTokensMaskAfter,
                _case.expectedTokensMaskAfter,
                _testCaseErr("Incorrect enabledTokenMask")
            );

            vm.revertTo(snapshot);
        }
    }

    /// @dev U:[FA-39]: revertIfNoPermission calls works properly
    function test_U_FA_39_revertIfNoPermission_calls_properly(uint256 mask) public notExpirableCase {
        uint8 index = uint8(getHash(mask, 1));
        uint256 permission = 1 << index;

        creditFacade.revertIfNoPermission(mask | permission, permission);

        vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, permission));

        creditFacade.revertIfNoPermission(mask & ~(permission), permission);
    }

    /// @dev U:[FA-40]: claimWithdrawals calls works properly
    function test_U_FA_40_claimWithdrawals_calls_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;
        address to = makeAddr("TO");

        creditManagerMock.setBorrower(USER);

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.claimWithdrawals, (creditAccount, to, ClaimAction.CLAIM))
        );

        vm.prank(USER);
        creditFacade.claimWithdrawals(creditAccount, to);
    }

    /// @dev U:[FA-41]: setBotPermissions calls works properly
    function test_U_FA_41_setBotPermissions_calls_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;
        address bot = makeAddr("BOT");

        creditManagerMock.setBorrower(USER);

        creditManagerMock.setFlagFor({creditAccount: creditAccount, flag: BOT_PERMISSIONS_SET_FLAG, value: false});

        botListMock.setBotPermissionsReturn(1);

        /// It erases all previious bot permission and set flag if flag was false before

        vm.expectCall(address(creditManagerMock), abi.encodeCall(ICreditManagerV3.flagsOf, (creditAccount)));
        vm.expectCall(address(botListMock), abi.encodeCall(IBotListV3.eraseAllBotPermissions, (creditAccount)));

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.setFlagFor, (creditAccount, BOT_PERMISSIONS_SET_FLAG, true))
        );

        vm.expectCall(address(botListMock), abi.encodeCall(IBotListV3.setBotPermissions, (creditAccount, bot, 1, 2, 3)));

        vm.prank(USER);
        creditFacade.setBotPermissions({
            creditAccount: creditAccount,
            bot: bot,
            permissions: 1,
            fundingAmount: 2,
            weeklyFundingAllowance: 3
        });

        /// It doesn't erase permission is bot already set
        botListMock.setRevertOnErase(true);
        vm.expectCall(address(botListMock), abi.encodeCall(IBotListV3.setBotPermissions, (creditAccount, bot, 1, 2, 3)));

        vm.prank(USER);
        creditFacade.setBotPermissions({
            creditAccount: creditAccount,
            bot: bot,
            permissions: 1,
            fundingAmount: 2,
            weeklyFundingAllowance: 3
        });

        /// It removes flag if no bots left
        botListMock.setBotPermissionsReturn(0);
        vm.expectCall(address(botListMock), abi.encodeCall(IBotListV3.setBotPermissions, (creditAccount, bot, 1, 2, 3)));

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.setFlagFor, (creditAccount, BOT_PERMISSIONS_SET_FLAG, false))
        );
        vm.prank(USER);
        creditFacade.setBotPermissions({
            creditAccount: creditAccount,
            bot: bot,
            permissions: 1,
            fundingAmount: 2,
            weeklyFundingAllowance: 3
        });
    }

    /// @dev U:[FA-42]: eraseAllBotPermissionsAtClosure works properly
    function test_U_FA_42_eraseAllBotPermissionsAtClosure_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        botListMock.setRevertOnErase(true);
        creditManagerMock.setFlagFor({creditAccount: creditAccount, flag: BOT_PERMISSIONS_SET_FLAG, value: false});
        creditFacade.eraseAllBotPermissionsAtClosure(creditAccount);

        botListMock.setRevertOnErase(false);
        creditManagerMock.setFlagFor({creditAccount: creditAccount, flag: BOT_PERMISSIONS_SET_FLAG, value: true});
        vm.expectCall(address(botListMock), abi.encodeCall(IBotListV3.eraseAllBotPermissions, (creditAccount)));
        creditFacade.eraseAllBotPermissionsAtClosure(creditAccount);
    }

    /// @dev U:[FA-43]: revertIfOutOfBorrowingLimit works properly
    function test_U_FA_43_revertIfOutOfBorrowingLimit_works_properly() public notExpirableCase {
        //
        // Case: It does nothing is maxDebtPerBlockMultiplier == type(uint8).max
        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(0, 0, type(uint8).max);
        creditFacade.revertIfOutOfBorrowingLimit(type(uint256).max);

        //
        // Case: it updates lastBlockBorrowed and rewrites totalBorrowedInBlock for new block
        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(0, 800, 2);

        creditFacade.setTotalBorrowedInBlock(500);

        uint64 blockNow = 100;
        creditFacade.setLastBlockBorrowed(blockNow - 1);

        vm.roll(blockNow);
        creditFacade.revertIfOutOfBorrowingLimit(200);

        assertEq(creditFacade.lastBlockBorrowedInt(), blockNow, "Incorrect lastBlockBorrowed");
        assertEq(creditFacade.totalBorrowedInBlockInt(), 200, "Incorrect totalBorrowedInBlock");

        //
        // Case: it summarize if the called in the same block
        creditFacade.revertIfOutOfBorrowingLimit(400);

        assertEq(creditFacade.lastBlockBorrowedInt(), blockNow, "Incorrect lastBlockBorrowed");
        assertEq(creditFacade.totalBorrowedInBlockInt(), 200 + 400, "Incorrect totalBorrowedInBlock");

        //
        // Case it reverts if borrowed more than limit
        vm.expectRevert(BorrowedBlockLimitException.selector);
        creditFacade.revertIfOutOfBorrowingLimit(800 * 2 - (200 + 400) + 1);
    }

    /// @dev U:[FA-44]: revertIfOutOfBorrowingLimit works properly
    function test_U_FA_44_revertIfOutOfDebtLimits_works_properly() public notExpirableCase {
        uint128 minDebt = 100;
        uint128 maxDebt = 200;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(minDebt, maxDebt, 1);

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        creditFacade.revertIfOutOfDebtLimits(minDebt - 1);

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        creditFacade.revertIfOutOfDebtLimits(maxDebt + 1);
    }

    /// @dev U:[FA-45]: fullCollateralCheck works properly
    function test_U_FA_45_fullCollateralCheck_works_properly() public notExpirableCase {
        // todo: add forbidden case check when it'll be updated
    }

    /// @dev U:[FA-46]: isExpired works properly
    function test_U_FA_46_isExpired_works_properly(uint40 timestamp) public allExpirableCases {
        vm.assume(timestamp > 1);

        if (expirable) {
            vm.prank(CONFIGURATOR);
            creditFacade.setExpirationDate(timestamp);
        }

        vm.warp(timestamp - 1);
        assertTrue(!creditFacade.isExpired(), "isExpired unexpectedly returns true");

        vm.warp(timestamp);
        assertEq(creditFacade.isExpired(), expirable, "Incorrect isExpired");
    }

    /// @dev U:[FA-47]: revertIfOutOfTotalDebtLimit works properly
    function test_U_FA_47_revertIfOutOfTotalDebtLimit_works_properly() public notExpirableCase {
        uint128 initialTD = 10_000;
        uint128 limit = 50_000;

        // Case: it increases currentTotalDebt if ManageDebtAction.INCREASE_DEBT
        vm.prank(CONFIGURATOR);
        creditFacade.setTotalDebtParams(initialTD, limit);

        creditFacade.revertIfOutOfTotalDebtLimit(100, ManageDebtAction.INCREASE_DEBT);
        (uint128 currentTotalDebt,) = creditFacade.totalDebt();
        assertEq(currentTotalDebt, initialTD + 100, "Incorrect total debt after increase");

        // Case: it decreases currentTotalDebt if ManageDebtAction.DECREASE_DEBT
        vm.prank(CONFIGURATOR);
        creditFacade.setTotalDebtParams(initialTD, limit);

        creditFacade.revertIfOutOfTotalDebtLimit(100, ManageDebtAction.DECREASE_DEBT);
        (currentTotalDebt,) = creditFacade.totalDebt();
        assertEq(currentTotalDebt, initialTD - 100, "Incorrect total debt after increase");

        // Case: it reverts of currentTotalDebt > limit
        vm.prank(CONFIGURATOR);
        creditFacade.setTotalDebtParams(initialTD, limit);
        vm.expectRevert(CreditManagerCantBorrowException.selector);
        creditFacade.revertIfOutOfTotalDebtLimit(limit - initialTD + 1, ManageDebtAction.INCREASE_DEBT);

        // Case: it doesn't reverts for decrease debt more than expecetd
        vm.prank(CONFIGURATOR);
        creditFacade.setTotalDebtParams(initialTD, limit);
        creditFacade.revertIfOutOfTotalDebtLimit(type(uint128).max, ManageDebtAction.DECREASE_DEBT);
    }

    /// @dev U:[FA-48]: rsetExpirationDate works properly
    function test_U_FA_48_setExpirationDate_works_properly() public allExpirableCases {
        assertEq(creditFacade.expirationDate(), 0, "SETUP: incorrect expiration date");

        if (!expirable) {
            vm.expectRevert(NotAllowedWhenNotExpirableException.selector);
        }

        vm.prank(CONFIGURATOR);
        creditFacade.setExpirationDate(100);

        assertEq(creditFacade.expirationDate(), expirable ? 100 : 0, "Incorrect expiration date");
    }

    /// @dev U:[FA-49]: setDebtLimits works properly
    function test_U_FA_49_setDebtLimits_works_properly() public notExpirableCase {
        uint8 maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();
        (uint128 minDebt, uint128 maxDebt) = creditFacade.debtLimits();

        assertEq(maxDebtPerBlockMultiplier, 0, "SETUP: incorrect maxDebtPerBlockMultiplier");
        assertEq(minDebt, 0, "SETUP: incorrect minDebt");
        assertEq(maxDebt, 0, "SETUP: incorrect maxDebt");

        // Case: it reverts if _maxDebtPerBlockMultiplier) * _maxDebt >= type(uint128).max
        vm.expectRevert(IncorrectParameterException.selector);

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, type(uint128).max, 2);

        // Case: it sets parameters properly
        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits({_minDebt: 1, _maxDebt: 2, _maxDebtPerBlockMultiplier: 3});

        maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();
        (minDebt, maxDebt) = creditFacade.debtLimits();

        assertEq(maxDebtPerBlockMultiplier, 3, " incorrect maxDebtPerBlockMultiplier");
        assertEq(minDebt, 1, " incorrect minDebt");
        assertEq(maxDebt, 2, " incorrect maxDebt");
    }

    /// @dev U:[FA-50]: setBotList works properly
    function test_U_FA_50_setBotList_works_properly() public notExpirableCase {
        assertEq(creditFacade.botList(), address(botListMock), "SETUP: incorrect botList");

        vm.prank(CONFIGURATOR);
        creditFacade.setBotList(DUMB_ADDRESS);

        assertEq(creditFacade.botList(), DUMB_ADDRESS, "incorrect botList");
    }

    /// @dev U:[FA-51]: setCumulativeLossParams works properly
    function test_U_FA_51_setCumulativeLossParams_works_properly() public notExpirableCase {
        (uint128 currentCumulativeLoss, uint128 maxCumulativeLoss) = creditFacade.lossParams();

        assertEq(maxCumulativeLoss, 0, "SETUP: incorrect maxCumulativeLoss");
        assertEq(currentCumulativeLoss, 0, "SETUP: incorrect currentCumulativeLoss");

        creditFacade.setCurrentCumulativeLoss(500);
        (currentCumulativeLoss,) = creditFacade.lossParams();

        assertEq(currentCumulativeLoss, 500, "SETUP: incorrect currentCumulativeLoss");

        vm.prank(CONFIGURATOR);
        creditFacade.setCumulativeLossParams(200, false);

        (currentCumulativeLoss, maxCumulativeLoss) = creditFacade.lossParams();

        assertEq(maxCumulativeLoss, 200, "SETUP: incorrect maxCumulativeLoss");
        assertEq(currentCumulativeLoss, 500, "SETUP: incorrect currentCumulativeLoss");

        vm.prank(CONFIGURATOR);
        creditFacade.setCumulativeLossParams(400, true);

        (currentCumulativeLoss, maxCumulativeLoss) = creditFacade.lossParams();

        assertEq(maxCumulativeLoss, 400, "SETUP: incorrect maxCumulativeLoss");
        assertEq(currentCumulativeLoss, 0, "SETUP: incorrect currentCumulativeLoss");
    }

    /// @dev U:[FA-52]: setTokenAllowance works properly
    function test_U_FA_52_setTokenAllowance_works_properly() public notExpirableCase {
        assertEq(creditFacade.forbiddenTokenMask(), 0, "SETUP: incorrect forbiddenTokenMask");

        vm.expectRevert(TokenNotAllowedException.selector);

        vm.prank(CONFIGURATOR);
        creditFacade.setTokenAllowance(DUMB_ADDRESS, AllowanceAction.ALLOW);

        address link = tokenTestSuite.addressOf(Tokens.LINK);
        uint256 mask = 1 << 8;
        creditManagerMock.addToken(link, mask);

        vm.prank(CONFIGURATOR);
        creditFacade.setTokenAllowance(link, AllowanceAction.FORBID);

        assertEq(creditFacade.forbiddenTokenMask(), mask, "incorrect forbiddenTokenMask");

        vm.prank(CONFIGURATOR);
        creditFacade.setTokenAllowance(link, AllowanceAction.ALLOW);

        assertEq(creditFacade.forbiddenTokenMask(), 0, "incorrect forbiddenTokenMask");
    }

    /// @dev U:[FA-53]: setEmergencyLiquidator works properly
    function test_U_FA_53_setEmergencyLiquidator_works_properly() public notExpirableCase {
        assertEq(
            creditFacade.canLiquidateWhilePaused(LIQUIDATOR),
            false,
            "SETUP: incorrect canLiquidateWhilePaused for LIQUIDATOR"
        );

        vm.prank(CONFIGURATOR);
        creditFacade.setEmergencyLiquidator(LIQUIDATOR, AllowanceAction.ALLOW);

        assertEq(
            creditFacade.canLiquidateWhilePaused(LIQUIDATOR),
            true,
            "incorrect canLiquidateWhilePaused for LIQUIDATOR after ALLOW"
        );

        vm.prank(CONFIGURATOR);
        creditFacade.setEmergencyLiquidator(LIQUIDATOR, AllowanceAction.FORBID);

        assertEq(
            creditFacade.canLiquidateWhilePaused(LIQUIDATOR),
            false,
            "incorrect canLiquidateWhilePaused for LIQUIDATOR after ALLOW"
        );
    }

    /// @dev U:[FA-54]: setTotalDebtParams works properly
    function test_U_FA_54_setTotalDebtParams_works_properly() public notExpirableCase {
        (uint128 currentTotalDebt, uint128 totalDebtLimit) = creditFacade.totalDebt();
        assertEq(currentTotalDebt, 0, "SETUP: incorrect currentTotalDebt");
        assertEq(totalDebtLimit, 0, "SETUP: incorrect totalDebtLimit");

        vm.prank(CONFIGURATOR);
        creditFacade.setTotalDebtParams(100, 200);

        (currentTotalDebt, totalDebtLimit) = creditFacade.totalDebt();
        assertEq(currentTotalDebt, 100, "incorrect currentTotalDebt");
        assertEq(totalDebtLimit, 200, "incorrect totalDebtLimit");
    }
}
