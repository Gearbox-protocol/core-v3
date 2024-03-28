// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../../../interfaces/IAddressProviderV3.sol";
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";

import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";
import {ERC20PermitMock} from "../../mocks/token/ERC20PermitMock.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IPriceOracleBase} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracleBase.sol";

/// LIBS
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CreditFacadeV3Harness} from "./CreditFacadeV3Harness.sol";

import {CreditManagerMock} from "../../mocks/credit/CreditManagerMock.sol";
import {DegenNFTMock} from "../../mocks/token/DegenNFTMock.sol";
import {AdapterMock} from "../../mocks/core/AdapterMock.sol";
import {BotListMock} from "../../mocks/core/BotListMock.sol";
import {PriceOracleMock} from "../../mocks/oracles/PriceOracleMock.sol";
import {PriceFeedOnDemandMock} from "../../mocks/oracles/PriceFeedOnDemandMock.sol";
import {AdapterCallMock} from "../../mocks/core/AdapterCallMock.sol";
import {PoolMock} from "../../mocks/pool/PoolMock.sol";

import {ENTERED} from "../../../traits/ReentrancyGuardTrait.sol";

import "../../../interfaces/ICreditFacadeV3.sol";
import {
    ICreditManagerV3,
    CollateralCalcTask,
    CollateralDebtData,
    ManageDebtAction,
    BOT_PERMISSIONS_SET_FLAG
} from "../../../interfaces/ICreditManagerV3.sol";
import {AllowanceAction} from "../../../interfaces/ICreditConfiguratorV3.sol";
import {IBotListV3} from "../../../interfaces/IBotListV3.sol";

import {BitMask, UNDERLYING_TOKEN_MASK} from "../../../libraries/BitMask.sol";
import {BalanceWithMask} from "../../../libraries/BalancesLogic.sol";
import {MultiCallBuilder} from "../../lib/MultiCallBuilder.sol";

// DATA

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
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

uint16 constant REFERRAL_CODE = 23;

contract CreditFacadeV3UnitTest is TestHelper, BalanceHelper, ICreditFacadeV3Events {
    using BitMask for uint256;

    IAddressProviderV3 addressProvider;

    CreditFacadeV3Harness creditFacade;
    CreditManagerMock creditManagerMock;
    PriceOracleMock priceOracleMock;
    PoolMock poolMock;

    BotListMock botListMock;

    DegenNFTMock degenNFTMock;
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
        tokenTestSuite = new TokensTestSuite();

        tokenTestSuite.topUpWETH{value: 100 * WAD}();

        addressProvider = new AddressProviderV3ACLMock();

        addressProvider.setAddress(AP_WETH_TOKEN, tokenTestSuite.addressOf(Tokens.WETH), false);

        botListMock = BotListMock(addressProvider.getAddressOrRevert(AP_BOT_LIST, 3_00));

        priceOracleMock = PriceOracleMock(addressProvider.getAddressOrRevert(AP_PRICE_ORACLE, 3_00));

        AddressProviderV3ACLMock(address(addressProvider)).addPausableAdmin(CONFIGURATOR);

        poolMock = new PoolMock(address(addressProvider), tokenTestSuite.addressOf(Tokens.DAI));

        creditManagerMock =
            new CreditManagerMock({_addressProvider: address(addressProvider), _pool: address(poolMock)});
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
        poolMock.setVersion(3_00);
        creditFacade = new CreditFacadeV3Harness(address(creditManagerMock), address(degenNFTMock), expirable);

        creditManagerMock.setCreditFacade(address(creditFacade));
    }

    /// @dev U:[FA-1]: constructor sets correct values
    function test_U_FA_01_constructor_sets_correct_values() public allDegenNftCases allExpirableCases {
        assertEq(address(creditFacade.creditManager()), address(creditManagerMock), "Incorrect creditManager");

        assertEq(creditFacade.weth(), tokenTestSuite.addressOf(Tokens.WETH), "Incorrect weth token");

        assertEq(creditFacade.degenNFT(), address(degenNFTMock), "Incorrect degen NFT");
    }

    /// @dev U:[FA-2]: user functions revert if called on pause
    function test_U_FA_02_user_functions_revert_if_called_on_pause() public notExpirableCase {
        creditManagerMock.setBorrower(address(this));

        vm.prank(CONFIGURATOR);
        creditFacade.pause();

        vm.expectRevert("Pausable: paused");
        creditFacade.openCreditAccount({onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});

        vm.expectRevert("Pausable: paused");
        creditFacade.closeCreditAccount({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        /// @notice We'll check that it works for emergency liquidatior as exceptions in another test
        vm.expectRevert("Pausable: paused");
        creditFacade.liquidateCreditAccount({creditAccount: DUMB_ADDRESS, to: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert("Pausable: paused");
        creditFacade.multicall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert("Pausable: paused");
        creditFacade.botMulticall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});
    }

    /// @dev U:[FA-3]: user functions revert if credit facade is expired
    function test_U_FA_03_user_functions_revert_if_credit_facade_is_expired() public expirableCase {
        vm.prank(CONFIGURATOR);
        creditFacade.setExpirationDate(uint40(block.timestamp));
        creditManagerMock.setBorrower(address(this));

        vm.warp(block.timestamp + 1);

        vm.expectRevert(NotAllowedAfterExpirationException.selector);
        creditFacade.openCreditAccount({onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});

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
        creditFacade.openCreditAccount({onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.closeCreditAccount({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.liquidateCreditAccount({creditAccount: DUMB_ADDRESS, to: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.multicall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.botMulticall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.setBotPermissions({creditAccount: DUMB_ADDRESS, bot: DUMB_ADDRESS, permissions: 0});
    }

    /// @dev U:[FA-5]: Account management functions revert if account does not exist
    function test_U_FA_05_account_management_functions_revert_if_account_does_not_exist() public notExpirableCase {
        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditFacade.closeCreditAccount({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditFacade.multicall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditFacade.botMulticall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditFacade.setBotPermissions({creditAccount: DUMB_ADDRESS, bot: DUMB_ADDRESS, permissions: 0});
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

        address weth = tokenTestSuite.addressOf(Tokens.WETH);

        vm.prank(USER);
        creditFacade.openCreditAccount{value: 1 ether}({
            onBehalfOf: USER,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (1 ether))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (weth, 1 ether))
                })
                ),
            referralCode: 0
        });

        expectBalance({t: Tokens.WETH, holder: USER, expectedBalance: 1 ether});

        creditManagerMock.setBorrower(USER);

        vm.prank(USER);
        creditFacade.closeCreditAccount{value: 1 ether}({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});
        expectBalance({t: Tokens.WETH, holder: USER, expectedBalance: 2 ether});

        vm.prank(USER);
        creditFacade.multicall{value: 1 ether}({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        expectBalance({t: Tokens.WETH, holder: USER, expectedBalance: 3 ether});
    }

    //
    // OPEN CREDIT ACCOUNT
    //

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
        creditFacade.openCreditAccount({onBehalfOf: FRIEND, calls: new MultiCall[](0), referralCode: 0});

        degenNFTMock.setRevertOnBurn(true);

        vm.prank(USER);
        vm.expectRevert(InsufficientBalanceException.selector);
        creditFacade.openCreditAccount({onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});
    }

    /// @dev U:[FA-10]: openCreditAccount wokrs as expected
    function test_U_FA_10_openCreditAccount_works_as_expected() public notExpirableCase {
        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(100, 200, 1);

        uint256 debt = 200;

        {
            uint64 blockNow = 100;
            creditFacade.setLastBlockBorrowed(blockNow);

            vm.roll(blockNow);
        }

        uint256 debtInBlock = creditFacade.totalBorrowedInBlockInt();

        address expectedCreditAccount = DUMB_ADDRESS;
        creditManagerMock.setReturnOpenCreditAccount(expectedCreditAccount);

        vm.expectCall(address(creditManagerMock), abi.encodeCall(ICreditManagerV3.openCreditAccount, (FRIEND)));

        vm.expectEmit(true, true, true, true);
        emit OpenCreditAccount(expectedCreditAccount, FRIEND, USER, REFERRAL_CODE);

        vm.expectEmit(true, true, false, false);
        emit StartMultiCall({creditAccount: expectedCreditAccount, caller: USER});

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                ICreditManagerV3.manageDebt, (expectedCreditAccount, debt, 0, ManageDebtAction.INCREASE_DEBT)
            )
        );

        vm.expectEmit(true, true, false, false);
        emit IncreaseDebt({creditAccount: expectedCreditAccount, amount: debt});

        vm.expectEmit(true, false, false, false);
        emit FinishMultiCall();

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck,
                (expectedCreditAccount, 0, new uint256[](0), PERCENTAGE_FACTOR, false)
            )
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount({
            onBehalfOf: FRIEND,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (debt))
                })
                ),
            referralCode: REFERRAL_CODE
        });

        assertEq(creditAccount, expectedCreditAccount, "Incorrect credit account");
        assertEq(creditFacade.totalBorrowedInBlockInt(), debtInBlock + debt, "Debt in block was updated incorrectly");
    }

    /// @dev U:[FA-11]: closeCreditAccount wokrs as expected
    function test_U_FA_11_closeCreditAccount_works_as_expected(uint256 seed) public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        bool hasCalls = (getHash({value: seed, seed: 2}) % 2) == 0;
        bool hasBotPermissions = (getHash({value: seed, seed: 3}) % 2) == 0;
        caseName = string.concat(
            caseName, ", hasCalls = ", boolToStr(hasCalls), ", hasBotPermissions = ", boolToStr(hasBotPermissions)
        );

        address adapter = address(new AdapterMock(address(creditManagerMock), DUMB_ADDRESS));

        creditManagerMock.setContractAllowance({adapter: adapter, targetContract: DUMB_ADDRESS});

        MultiCall[] memory calls;

        creditManagerMock.setBorrower(USER);
        creditManagerMock.setFlagFor(creditAccount, BOT_PERMISSIONS_SET_FLAG, hasBotPermissions);
        if (!hasCalls) creditManagerMock.setRevertOnActiveAccount(true);
        if (!hasBotPermissions) botListMock.setRevertOnErase(true);

        vm.expectCall(address(creditManagerMock), abi.encodeCall(ICreditManagerV3.enabledTokensMaskOf, (creditAccount)));

        vm.expectCall(address(creditManagerMock), abi.encodeCall(ICreditManagerV3.closeCreditAccount, (creditAccount)));

        if (hasCalls) {
            calls = MultiCallBuilder.build(
                MultiCall({target: adapter, callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
            );
        }

        if (hasBotPermissions) {
            vm.expectCall(
                address(botListMock),
                abi.encodeCall(IBotListV3.eraseAllBotPermissions, (address(creditManagerMock), creditAccount))
            );
        }

        vm.expectEmit(true, true, true, true);
        emit CloseCreditAccount(creditAccount, USER);

        vm.prank(USER);
        creditFacade.closeCreditAccount({creditAccount: creditAccount, calls: calls});
    }

    //
    // LIQUIDATE CREDIT ACCOUNT
    //

    /// @dev U:[FA-12]: liquidateCreditAccount allows emergency liquidators when paused
    function test_U_FA_12_liquidateCreditAccount_allows_emergency_liquidators_when_paused() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;
        creditManagerMock.setBorrower(USER);

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.debt = 101;
        collateralDebtData.totalDebtUSD = 101;
        collateralDebtData.twvUSD = 100;
        creditManagerMock.setDebtAndCollateralData(collateralDebtData);

        vm.prank(CONFIGURATOR);
        creditFacade.pause();

        vm.prank(CONFIGURATOR);
        creditFacade.setEmergencyLiquidator(LIQUIDATOR, AllowanceAction.ALLOW);

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount({creditAccount: creditAccount, to: FRIEND, calls: new MultiCall[](0)});

        vm.prank(CONFIGURATOR);
        creditFacade.setEmergencyLiquidator(LIQUIDATOR, AllowanceAction.FORBID);

        vm.expectRevert("Pausable: paused");
        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount({creditAccount: creditAccount, to: FRIEND, calls: new MultiCall[](0)});
    }

    /// @dev U:[FA-13]: liquidateCreditAccount reverts if account is not liquidatable
    function test_U_FA_13_liquidateCreditAccount_reverts_if_account_is_not_liquidatable() public allExpirableCases {
        address creditAccount = DUMB_ADDRESS;
        creditManagerMock.setBorrower(USER);

        // no debt
        vm.expectRevert(CreditAccountNotLiquidatableException.selector);
        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount({creditAccount: creditAccount, to: FRIEND, calls: new MultiCall[](0)});

        // healthy, non-expired
        CollateralDebtData memory collateralDebtData;
        collateralDebtData.debt = 101;
        collateralDebtData.totalDebtUSD = 101;
        collateralDebtData.twvUSD = 101;
        creditManagerMock.setDebtAndCollateralData(collateralDebtData);

        if (expirable) {
            vm.prank(CONFIGURATOR);
            creditFacade.setExpirationDate(uint40(block.timestamp + 1));
        }

        vm.expectRevert(CreditAccountNotLiquidatableException.selector);
        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount({creditAccount: creditAccount, to: FRIEND, calls: new MultiCall[](0)});
    }

    /// @dev U:[FA-14]: liquidateCreditAccount reverts if non-underlying balance increases in multicall
    function test_U_FA_14_liquidateCreditAccount_reverts_if_non_underlying_balance_increases_in_multicall()
        public
        notExpirableCase
    {
        address dai = tokenTestSuite.addressOf(Tokens.DAI);
        address link = tokenTestSuite.addressOf(Tokens.LINK);
        uint256 linkMask = 4;
        creditManagerMock.addToken(link, linkMask);

        AdapterCallMock adapter = new AdapterCallMock();
        creditManagerMock.setContractAllowance(address(adapter), makeAddr("DUMMY"));
        ERC20Mock(dai).set_minter(address(adapter));
        ERC20Mock(link).set_minter(address(adapter));

        address creditAccount = DUMB_ADDRESS;
        creditManagerMock.setBorrower(USER);

        deal({token: dai, to: creditAccount, give: 50});
        deal({token: link, to: creditAccount, give: 50});

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.debt = 101;
        collateralDebtData.totalDebtUSD = 101;
        collateralDebtData.twvUSD = 100;
        collateralDebtData.enabledTokensMask = UNDERLYING_TOKEN_MASK | linkMask;
        creditManagerMock.setDebtAndCollateralData(collateralDebtData);

        for (uint256 i; i < 2; ++i) {
            bool addNonUnderlying = i == 1;
            if (addNonUnderlying) vm.expectRevert(RemainingTokenBalanceIncreasedException.selector);

            vm.prank(LIQUIDATOR);
            creditFacade.liquidateCreditAccount({
                creditAccount: creditAccount,
                to: FRIEND,
                calls: MultiCallBuilder.build(
                    MultiCall(
                        address(adapter),
                        abi.encodeCall(
                            AdapterCallMock.makeCall,
                            (addNonUnderlying ? link : dai, abi.encodeCall(ERC20Mock.mint, (creditAccount, 10)))
                        )
                    )
                    )
            });
        }
    }

    /// @dev U:[FA-15]: liquidateCreditAccount correctly determines liquidation type
    function test_U_FA_15_liquidateCreditAccount_correctly_determines_liquidation_type() public allExpirableCases {
        address creditAccount = DUMB_ADDRESS;
        creditManagerMock.setBorrower(USER);

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.debt = 101;
        collateralDebtData.totalDebtUSD = 101;

        // unhealthy, non-expired
        collateralDebtData.twvUSD = 100;
        creditManagerMock.setDebtAndCollateralData(collateralDebtData);

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount({creditAccount: creditAccount, to: FRIEND, calls: new MultiCall[](0)});
        assertFalse(creditManagerMock.liquidateIsExpired(), "isExpired on unhealthy non-expired liquidation");

        if (expirable) {
            vm.prank(CONFIGURATOR);
            creditFacade.setExpirationDate(uint40(block.timestamp - 1));

            // healthy, expired
            collateralDebtData.twvUSD = 101;
            creditManagerMock.setDebtAndCollateralData(collateralDebtData);

            vm.prank(LIQUIDATOR);
            creditFacade.liquidateCreditAccount({creditAccount: creditAccount, to: FRIEND, calls: new MultiCall[](0)});
            assertTrue(creditManagerMock.liquidateIsExpired(), "isExpired on healthy expired liquidation");

            // unhealthy, expired
            collateralDebtData.twvUSD = 100;
            creditManagerMock.setDebtAndCollateralData(collateralDebtData);

            vm.prank(LIQUIDATOR);
            creditFacade.liquidateCreditAccount({creditAccount: creditAccount, to: FRIEND, calls: new MultiCall[](0)});
            assertFalse(creditManagerMock.liquidateIsExpired(), "isExpired on unhealthy expired liquidation");
        }
    }

    /// @dev U:[FA-16]: liquidateCreditAccount works as expected
    function test_U_FA_16_liquidateCreditAccount_works_as_expected() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;
        creditManagerMock.setBorrower(USER);

        address usdc = tokenTestSuite.addressOf(Tokens.USDC);
        address weth = tokenTestSuite.addressOf(Tokens.WETH);
        address link = tokenTestSuite.addressOf(Tokens.LINK);
        creditManagerMock.addToken(usdc, 2);
        creditManagerMock.addToken(weth, 4);
        creditManagerMock.addToken(link, 8);

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.debt = 101;
        collateralDebtData.totalDebtUSD = 101;
        collateralDebtData.twvUSD = 100;
        collateralDebtData.enabledTokensMask = 2 | 4;
        creditManagerMock.setDebtAndCollateralData(collateralDebtData);
        creditManagerMock.setAddCollateral(8);
        creditManagerMock.setWithdrawCollateral(4);
        creditManagerMock.setLiquidateCreditAccountReturns(123, 0);

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.calcDebtAndCollateral, (creditAccount, CollateralCalcTask.DEBT_COLLATERAL))
        );

        CollateralDebtData memory collateralDebtDataAfter = collateralDebtData;
        collateralDebtDataAfter.enabledTokensMask = 1 | 2;
        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                ICreditManagerV3.liquidateCreditAccount, (creditAccount, collateralDebtDataAfter, FRIEND, false)
            )
        );

        vm.expectEmit(true, true, true, true);
        emit LiquidateCreditAccount(creditAccount, LIQUIDATOR, FRIEND, 123);

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount({
            creditAccount: creditAccount,
            to: FRIEND,
            calls: MultiCallBuilder.build(
                MultiCall(address(creditFacade), abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (link, 2))),
                MultiCall(
                    address(creditFacade), abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (usdc, 2, FRIEND))
                )
                )
        });
    }

    /// @dev U:[FA-17]: liquidateCreditAccount correctly handles loss
    function test_U_FA_17_liquidateCreditAccount_correctly_handles_loss() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;
        creditManagerMock.setBorrower(USER);

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.debt = 101;
        collateralDebtData.totalDebtUSD = 101;
        collateralDebtData.twvUSD = 100;
        creditManagerMock.setDebtAndCollateralData(collateralDebtData);

        creditManagerMock.setLiquidateCreditAccountReturns(0, 100);

        vm.startPrank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, 100, 10);
        creditFacade.setCumulativeLossParams(150, true);
        creditFacade.setEmergencyLiquidator(LIQUIDATOR, AllowanceAction.ALLOW);
        vm.stopPrank();

        // first liquidation with loss
        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount({creditAccount: creditAccount, to: FRIEND, calls: new MultiCall[](0)});

        assertEq(creditFacade.maxDebtPerBlockMultiplier(), 0, "Borrowing not forbidden after liquidation with loss");
        (uint128 cumulativeLoss,) = creditFacade.lossParams();
        assertEq(cumulativeLoss, 100, "Incorrect cumulative loss after first liquidation");
        assertFalse(creditFacade.paused(), "Paused too early");

        // liquidation with loss that breaks cumulative loss limit
        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount({creditAccount: creditAccount, to: FRIEND, calls: new MultiCall[](0)});

        assertEq(creditFacade.maxDebtPerBlockMultiplier(), 0, "Borrowing not forbidden after liquidation with loss");
        (cumulativeLoss,) = creditFacade.lossParams();
        assertEq(cumulativeLoss, 200, "Incorrect cumulative loss after second liquidation");
        assertTrue(creditFacade.paused(), "Not paused after breaking cumulative loss limit");

        // emergency liquidation with loss after cumulative loss limit is already broken
        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount({creditAccount: creditAccount, to: FRIEND, calls: new MultiCall[](0)});

        assertEq(creditFacade.maxDebtPerBlockMultiplier(), 0, "Borrowing not forbidden after liquidation with loss");
        (cumulativeLoss,) = creditFacade.lossParams();
        assertEq(cumulativeLoss, 300, "Incorrect cumulative loss after third liquidation");
        assertTrue(creditFacade.paused(), "Not paused after breaking cumulative loss limit");
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

        botListMock.setBotStatusReturns(ALL_PERMISSIONS, false, false);

        creditManagerMock.setEnabledTokensMask(enabledTokensMaskBefore);
        creditManagerMock.setBorrower(USER);
        creditManagerMock.setFlagFor(creditAccount, BOT_PERMISSIONS_SET_FLAG, true);

        uint256 enabledTokensMaskAfter = enabledTokensMaskBefore;

        for (uint256 testCase = 0; testCase < 2; ++testCase) {
            bool botMulticallCase = testCase == 1;

            vm.expectCall(
                address(creditManagerMock),
                abi.encodeCall(
                    ICreditManagerV3.fullCollateralCheck,
                    (creditAccount, enabledTokensMaskAfter, new uint256[](0), PERCENTAGE_FACTOR, false)
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

    /// @dev U:[FA-19]: botMulticall reverts if 1. bot permissions flag is false 2. no permissions are set 3. bot is forbidden
    function test_U_FA_19_botMulticall_reverts_for_invalid_bots() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;
        creditManagerMock.setBorrower(USER);
        MultiCall[] memory calls;

        creditManagerMock.setFlagFor(creditAccount, BOT_PERMISSIONS_SET_FLAG, true);

        botListMock.setBotStatusReturns(ALL_PERMISSIONS, true, false);

        vm.expectRevert(NotApprovedBotException.selector);
        creditFacade.botMulticall(creditAccount, calls);

        botListMock.setBotStatusReturns(0, false, false);

        vm.expectRevert(NotApprovedBotException.selector);
        creditFacade.botMulticall(creditAccount, calls);

        creditManagerMock.setFlagFor(creditAccount, BOT_PERMISSIONS_SET_FLAG, false);

        botListMock.setBotStatusReturns(ALL_PERMISSIONS, false, false);

        vm.expectRevert(NotApprovedBotException.selector);
        creditFacade.botMulticall(creditAccount, calls);

        botListMock.setBotStatusReturns(ALL_PERMISSIONS, false, true);

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

        priceOracleMock.addPriceFeed(token, priceFeedOnDemandMock);

        creditManagerMock.setBorrower(USER);

        MultiCallPermissionTestCase[9] memory cases = [
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
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateralWithPermit, (token, 0, 0, 0, bytes32(0), bytes32(0))
                    ),
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
                callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (token, 0, USER)),
                permissionRquired: WITHDRAW_COLLATERAL_PERMISSION
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.revokeAdapterAllowances, (new RevocationPair[](0))),
                permissionRquired: REVOKE_ALLOWANCES_PERMISSION
            })
        ];

        uint256 len = cases.length;
        for (uint256 i = 0; i < len; ++i) {
            vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, cases[i].permissionRquired));

            creditFacade.multicallInt({
                creditAccount: creditAccount,
                calls: MultiCallBuilder.build(MultiCall({target: address(creditFacade), callData: cases[i].callData})),
                enabledTokensMask: 0,
                flags: type(uint256).max.disable(cases[i].permissionRquired)
            });
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

    /// @dev U:[FA-23]: multicall slippage check works properly
    function test_U_FA_23_multicall_slippage_check_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        address link = tokenTestSuite.addressOf(Tokens.LINK);
        BalanceDelta[] memory expectedBalance = new BalanceDelta[](1);

        address acm = address(new AdapterCallMock());

        creditManagerMock.setContractAllowance(acm, DUMB_ADDRESS3);

        ERC20Mock(link).set_minter(acm);

        for (uint256 testCase = 0; testCase < 6; ++testCase) {
            // case 0: no revert if expected 0
            // case 1: reverts because expects 1
            // case 2: no revert because expects 1 and it mints 1 during the call
            // case 3: reverts because called twice
            // case 4: reverts because checked without saving balances
            // case 5: reverts because failed the second check

            expectedBalance[0] = BalanceDelta({token: link, amount: int256(uint256(testCase > 0 ? 1 : 0))});

            MultiCall[] memory calls = MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.storeExpectedBalances, (expectedBalance))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.compareBalances, ())
                })
            );

            if (testCase == 1) {
                vm.expectRevert(BalanceLessThanExpectedException.selector);
            }

            if (testCase == 2) {
                calls = MultiCallBuilder.build(
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.storeExpectedBalances, (expectedBalance))
                    }),
                    MultiCall({
                        target: acm,
                        callData: abi.encodeCall(
                            AdapterCallMock.makeCall, (link, abi.encodeCall(ERC20Mock.mint, (creditAccount, 1)))
                            )
                    }),
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.compareBalances, ())
                    })
                );
            }

            if (testCase == 3) {
                calls = MultiCallBuilder.build(
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.storeExpectedBalances, (expectedBalance))
                    }),
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.storeExpectedBalances, (expectedBalance))
                    })
                );
                vm.expectRevert(ExpectedBalancesAlreadySetException.selector);
            }

            if (testCase == 4) {
                calls = MultiCallBuilder.build(
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.compareBalances, ())
                    })
                );
                vm.expectRevert(ExpectedBalancesNotSetException.selector);
            }

            if (testCase == 5) {
                calls = MultiCallBuilder.build(
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.storeExpectedBalances, (expectedBalance))
                    }),
                    MultiCall({
                        target: acm,
                        callData: abi.encodeCall(
                            AdapterCallMock.makeCall, (link, abi.encodeCall(ERC20Mock.mint, (creditAccount, 1)))
                            )
                    }),
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.compareBalances, ())
                    }),
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.storeExpectedBalances, (expectedBalance))
                    })
                );
                vm.expectRevert(BalanceLessThanExpectedException.selector);
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

        uint256[] memory collateralHints;
        uint16 minHealthFactor;

        minHealthFactor = PERCENTAGE_FACTOR - 1;
        vm.expectRevert(CustomHealthFactorTooLowException.selector);
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.setFullCheckParams, (new uint256[](0), PERCENTAGE_FACTOR - 1)
                        )
                })
                ),
            enabledTokensMask: 0,
            flags: 0
        });

        minHealthFactor = PERCENTAGE_FACTOR;
        collateralHints = new uint256[](1);
        vm.expectRevert(InvalidCollateralHintException.selector);
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.setFullCheckParams, (collateralHints, PERCENTAGE_FACTOR))
                })
                ),
            enabledTokensMask: 0,
            flags: 0
        });

        collateralHints[0] = 3;
        vm.expectRevert(InvalidCollateralHintException.selector);
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.setFullCheckParams, (collateralHints, PERCENTAGE_FACTOR))
                })
                ),
            enabledTokensMask: 0,
            flags: 0
        });

        collateralHints = new uint256[](2);
        collateralHints[0] = 16;
        collateralHints[1] = 32;
        minHealthFactor = 12_320;

        FullCheckParams memory fullCheckParams = creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.setFullCheckParams, (collateralHints, minHealthFactor))
                })
                ),
            enabledTokensMask: 0,
            flags: 0
        });

        assertEq(fullCheckParams.minHealthFactor, minHealthFactor, "Incorrect minHealthFactor");
        assertEq(fullCheckParams.collateralHints, collateralHints, "Incorrect collateralHints");
    }

    /// @dev U:[FA-25]: multicall onDemandPriceUpdate works properly
    function test_U_FA_25_multicall_onDemandPriceUpdate_works_properly() public notExpirableCase {
        bytes memory cd = bytes("Hellew");

        address token = tokenTestSuite.addressOf(Tokens.LINK);

        creditManagerMock.setPriceOracle(address(priceOracleMock));

        address priceFeedOnDemandMock = address(new PriceFeedOnDemandMock());

        priceOracleMock.addPriceFeed(token, priceFeedOnDemandMock);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.onDemandPriceUpdate, (token, false, cd))
            })
        );

        // vm.expectCall(address(priceOracleMock), abi.encodeCall(IPriceOracleBase.priceFeeds, (token)));
        vm.expectCall(address(priceFeedOnDemandMock), abi.encodeCall(PriceFeedOnDemandMock.updatePrice, (cd)));
        creditFacade.applyPriceOnDemandInt({calls: calls});

        /// @notice it reverts for zero value
        calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.onDemandPriceUpdate, (DUMB_ADDRESS, false, cd))
            })
        );

        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        creditFacade.applyPriceOnDemandInt({calls: calls});
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

    /// @dev U:[FA-26B]: multicall addCollateralWithPermit works properly
    function test_U_FA_26B_multicall_addCollateralWithPermit_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        (address user, uint256 key) = makeAddrAndKey("user");

        ERC20PermitMock token = new ERC20PermitMock("Test Token", "TEST", 18);
        uint256 amount = 12333345;
        uint256 mask = 1 << 5;
        uint256 deadline = block.timestamp + 1;

        creditManagerMock.setAddCollateral(mask);

        for (uint256 testCase = 0; testCase < 2; ++testCase) {
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(key, token.getPermitHash(user, address(creditManagerMock), amount, deadline));

            MultiCall[] memory calls = MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.addCollateralWithPermit, (address(token), amount, deadline, v, r, s)
                        )
                })
            );

            creditManagerMock.setQuotedTokensMask(testCase == 0 ? 0 : mask);

            vm.expectCall(
                address(token),
                abi.encodeCall(IERC20Permit.permit, (user, address(creditManagerMock), amount, deadline, v, r, s))
            );

            vm.expectCall(
                address(creditManagerMock),
                abi.encodeCall(ICreditManagerV3.addCollateral, (user, creditAccount, address(token), amount))
            );

            vm.expectEmit(true, true, true, true);
            emit AddCollateral(creditAccount, address(token), amount);

            vm.prank(user);
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
    function test_U_FA_27_multicall_increaseDebt_works_properly() public notExpirableCase {
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

    /// @dev U:[FA-30]: multicall increaseDebt / withdrawCollateral set revertOnForbiddenTokens flag
    function test_U_FA_30_multicall_increaseDebt_and_withdrawCollateral_set_revertOnForbiddenTokens()
        public
        notExpirableCase
    {
        address creditAccount = DUMB_ADDRESS;

        address link = tokenTestSuite.addressOf(Tokens.LINK);
        uint256 linkMask = 1 << 8;
        tokenTestSuite.mint(link, DUMB_ADDRESS, 1000);

        creditManagerMock.addToken(link, linkMask);

        vm.prank(CONFIGURATOR);
        creditFacade.setTokenAllowance(link, AllowanceAction.FORBID);

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, 100, 1);

        creditManagerMock.setManageDebt({newDebt: 50, tokensToEnable: UNDERLYING_TOKEN_MASK, tokensToDisable: 0});

        FullCheckParams memory params = creditFacade.multicallInt({
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
        assertTrue(params.revertOnForbiddenTokens, "revertOnForbiddenTokens is false after increaseDebt");

        params = creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (link, 1000, USER))
                })
                ),
            enabledTokensMask: linkMask,
            flags: WITHDRAW_COLLATERAL_PERMISSION
        });
        assertTrue(params.revertOnForbiddenTokens, "revertOnForbiddenTokens is false after withdrawCollateral");
    }

    ///

    /// @dev U:[FA-31]: multicall decreaseDebt works properly
    function test_U_FA_31_multicall_decreaseDebt_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        uint256 amount = 50;

        uint256 mask = 1232322 | UNDERLYING_TOKEN_MASK;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, 100, 1);

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

    /// @dev U:[FA-33A]: multicall decreaseDebt allows zero debt
    function test_U_FA_33A_multicall_decreaseDebt_allows_zero_debt() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        uint128 minDebt = 100;

        uint256 mask = 1232322;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(minDebt, minDebt + 100, 1);

        creditManagerMock.setManageDebt({newDebt: 0, tokensToEnable: 0, tokensToDisable: UNDERLYING_TOKEN_MASK});

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

        int96 change = -19900;

        creditManagerMock.setUpdateQuota({tokensToEnable: maskToEnable, tokensToDisable: maskToDisable});

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                ICreditManagerV3.updateQuota,
                (creditAccount, link, change / 10_000 * 10_000, 0, uint96(maxDebt * creditFacade.maxQuotaMultiplier()))
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

    /// @dev U:[FA-34A]: multicall updateQuota reverts on trying to increase quota for forbidden token
    function test_U_FA_34A_multicall_updateQuota_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        address link = tokenTestSuite.addressOf(Tokens.LINK);
        uint256 linkMask = 1 << 8;
        tokenTestSuite.mint(link, DUMB_ADDRESS, 1000);

        creditManagerMock.addToken(link, linkMask);

        vm.prank(CONFIGURATOR);
        creditFacade.setTokenAllowance(link, AllowanceAction.FORBID);

        uint96 maxDebt = 443330;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(0, maxDebt, type(uint8).max);

        int96 change = 990;

        vm.expectRevert(ForbiddenTokensException.selector);
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (link, change, 0))
                })
                ),
            enabledTokensMask: linkMask,
            flags: UPDATE_QUOTA_PERMISSION | FORBIDDEN_TOKENS_BEFORE_CALLS
        });

        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (link, -change, 0))
                })
                ),
            enabledTokensMask: linkMask,
            flags: UPDATE_QUOTA_PERMISSION | FORBIDDEN_TOKENS_BEFORE_CALLS
        });
    }

    /// @dev U:[FA-35]: multicall `withdrawCollateral` works properly
    function test_U_FA_35_multicall_withdrawCollateral_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        address link = tokenTestSuite.addressOf(Tokens.LINK);
        uint256 maskToDisable = 1 << 7;

        uint256 amount = 100;
        creditManagerMock.setWithdrawCollateral({tokensToDisable: maskToDisable});

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.withdrawCollateral, (creditAccount, link, amount, USER))
        );

        vm.expectEmit(true, true, false, true);
        emit WithdrawCollateral(creditAccount, link, amount, USER);

        FullCheckParams memory fullCheckParams = creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (link, amount, USER))
                })
                ),
            enabledTokensMask: maskToDisable | UNDERLYING_TOKEN_MASK,
            flags: WITHDRAW_COLLATERAL_PERMISSION
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

    /// @dev U:[FA-41]: setBotPermissions calls works properly
    function test_U_FA_41_setBotPermissions_calls_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;
        address bot = makeAddr("BOT");

        creditManagerMock.setBorrower(USER);

        /// It reverts if passed unexpected permissions
        vm.expectRevert(UnexpectedPermissionsException.selector);
        vm.prank(USER);
        creditFacade.setBotPermissions({creditAccount: creditAccount, bot: bot, permissions: type(uint192).max});

        creditManagerMock.setFlagFor({creditAccount: creditAccount, flag: BOT_PERMISSIONS_SET_FLAG, value: false});

        botListMock.setBotPermissionsReturn(1);

        /// It sets flag to true if it was false before
        vm.expectCall(address(creditManagerMock), abi.encodeCall(ICreditManagerV3.flagsOf, (creditAccount)));
        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.setFlagFor, (creditAccount, BOT_PERMISSIONS_SET_FLAG, true))
        );
        vm.expectCall(
            address(botListMock),
            abi.encodeCall(IBotListV3.setBotPermissions, (bot, address(creditManagerMock), creditAccount, 1))
        );

        vm.prank(USER);
        creditFacade.setBotPermissions({creditAccount: creditAccount, bot: bot, permissions: 1});

        /// It removes flag if no bots left
        botListMock.setBotPermissionsReturn(0);
        vm.expectCall(
            address(botListMock),
            abi.encodeCall(IBotListV3.setBotPermissions, (bot, address(creditManagerMock), creditAccount, 1))
        );

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.setFlagFor, (creditAccount, BOT_PERMISSIONS_SET_FLAG, false))
        );
        vm.prank(USER);
        creditFacade.setBotPermissions({creditAccount: creditAccount, bot: bot, permissions: 1});
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
        address creditAccount = DUMB_ADDRESS;
        uint256 enabledTokensMaskBefore = UNDERLYING_TOKEN_MASK;

        address link = tokenTestSuite.addressOf(Tokens.LINK);
        uint256 linkMask = 2;
        deal({token: link, to: creditAccount, give: 1000});

        creditManagerMock.addToken(link, linkMask);
        uint256 forbiddenTokensMask = linkMask;

        uint256[] memory collateralHints = new uint256[](1);
        collateralHints[0] = linkMask;

        FullCheckParams memory params = FullCheckParams({
            collateralHints: collateralHints,
            minHealthFactor: 123,
            enabledTokensMaskAfter: enabledTokensMaskBefore | linkMask,
            useSafePrices: true,
            revertOnForbiddenTokens: true
        });

        vm.expectRevert(ForbiddenTokensException.selector);
        creditFacade.fullCollateralCheckInt(
            creditAccount, enabledTokensMaskBefore, params, new BalanceWithMask[](0), forbiddenTokensMask
        );

        params.revertOnForbiddenTokens = false;
        vm.expectRevert(ForbiddenTokenEnabledException.selector);
        creditFacade.fullCollateralCheckInt(
            creditAccount, enabledTokensMaskBefore, params, new BalanceWithMask[](0), forbiddenTokensMask
        );

        enabledTokensMaskBefore |= linkMask;

        BalanceWithMask[] memory forbiddenBalances = new BalanceWithMask[](1);
        forbiddenBalances[0] = BalanceWithMask(link, linkMask, 900);
        vm.expectRevert(ForbiddenTokenBalanceIncreasedException.selector);
        creditFacade.fullCollateralCheckInt(
            creditAccount, enabledTokensMaskBefore, params, forbiddenBalances, forbiddenTokensMask
        );

        forbiddenBalances[0] = BalanceWithMask(link, linkMask, 1100);
        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck,
                (creditAccount, enabledTokensMaskBefore, collateralHints, 123, true)
            )
        );
        creditFacade.fullCollateralCheckInt(
            creditAccount, enabledTokensMaskBefore, params, forbiddenBalances, forbiddenTokensMask
        );
    }

    /// @dev U:[FA-46]: isExpired works properly
    function test_U_FA_46_isExpired_works_properly(uint40 timestamp) public allExpirableCases {
        vm.assume(timestamp > 1);

        assertTrue(!creditFacade.isExpired(), "isExpired unexpectedly returns true (expiration date not set)");

        if (expirable) {
            vm.prank(CONFIGURATOR);
            creditFacade.setExpirationDate(timestamp);
        }

        vm.warp(timestamp - 1);
        assertTrue(!creditFacade.isExpired(), "isExpired unexpectedly returns true (not expired)");

        vm.warp(timestamp);
        assertEq(creditFacade.isExpired(), expirable, "Incorrect isExpired");
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
        creditFacade.setDebtLimits({newMinDebt: 1, newMaxDebt: 2, newMaxDebtPerBlockMultiplier: 3});

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
}
