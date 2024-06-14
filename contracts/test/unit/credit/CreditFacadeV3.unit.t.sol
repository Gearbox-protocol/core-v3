// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.23;

import "../../interfaces/IAddressProviderV3.sol";
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";

import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";
import {ERC20PermitMock} from "../../mocks/token/ERC20PermitMock.sol";
import {PhantomTokenMock} from "../../mocks/token/PhantomTokenMock.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// LIBS
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CreditFacadeV3Harness} from "./CreditFacadeV3Harness.sol";

import {GeneralMock} from "../../mocks/GeneralMock.sol";
import {CreditManagerMock} from "../../mocks/credit/CreditManagerMock.sol";
import {DegenNFTMock} from "../../mocks/token/DegenNFTMock.sol";
import {AdapterMock} from "../../mocks/core/AdapterMock.sol";
import {PhantomTokenAdapterMock} from "../../mocks/core/PhantomTokenAdapterMock.sol";
import {BotListMock} from "../../mocks/core/BotListMock.sol";
import {PriceOracleMock} from "../../mocks/oracles/PriceOracleMock.sol";
import {UpdatablePriceFeedMock} from "../../mocks/oracles/UpdatablePriceFeedMock.sol";
import {AdapterCallMock} from "../../mocks/core/AdapterCallMock.sol";
import {PoolMock} from "../../mocks/pool/PoolMock.sol";

import {ENTERED} from "../../../traits/ReentrancyGuardTrait.sol";

import "../../../interfaces/ICreditFacadeV3.sol";
import {
    ICreditManagerV3,
    CollateralCalcTask,
    CollateralDebtData,
    ManageDebtAction
} from "../../../interfaces/ICreditManagerV3.sol";
import {AllowanceAction} from "../../../interfaces/ICreditConfiguratorV3.sol";
import {IBotListV3} from "../../../interfaces/IBotListV3.sol";
import {IPriceOracleV3, PriceUpdate} from "../../../interfaces/IPriceOracleV3.sol";

import {BitMask} from "../../../libraries/BitMask.sol";
import {BalanceWithMask} from "../../../libraries/BalancesLogic.sol";
import {MultiCallBuilder} from "../../lib/MultiCallBuilder.sol";

// CONSTANTS
import {
    DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER,
    PERCENTAGE_FACTOR,
    UNDERLYING_TOKEN_MASK
} from "../../../libraries/Constants.sol";

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

contract CreditFacadeV3UnitTest is TestHelper, BalanceHelper {
    using BitMask for uint256;

    IAddressProviderV3 addressProvider;

    CreditFacadeV3Harness creditFacade;
    CreditManagerMock creditManagerMock;
    PriceOracleMock priceOracleMock;
    BotListMock botListMock;

    DegenNFTMock degenNFTMock;
    address treasury;
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

        botListMock = BotListMock(addressProvider.getAddressOrRevert(AP_BOT_LIST, 3_10));
        botListMock.setCreditManagerAddedReturns(true);

        priceOracleMock = PriceOracleMock(addressProvider.getAddressOrRevert(AP_PRICE_ORACLE, 3_10));

        AddressProviderV3ACLMock(address(addressProvider)).addPausableAdmin(CONFIGURATOR);

        PoolMock poolMock = new PoolMock(address(addressProvider), tokenTestSuite.addressOf(Tokens.DAI));
        treasury = makeAddr("TREASURY");
        poolMock.setTreasury(treasury);

        creditManagerMock =
            new CreditManagerMock({_addressProvider: address(addressProvider), _pool: address(poolMock)});
    }

    function _withoutDegenNFT() internal {
        degenNFTMock = DegenNFTMock(address(0));
    }

    function _withDegenNFT() internal {
        whitelisted = true;
        degenNFTMock = new DegenNFTMock("DegenNFT", "DNFT");
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
        creditFacade = new CreditFacadeV3Harness(
            address(addressProvider),
            address(creditManagerMock),
            address(botListMock),
            tokenTestSuite.addressOf(Tokens.WETH),
            address(degenNFTMock),
            expirable
        );

        creditManagerMock.setCreditFacade(address(creditFacade));
    }

    /// @dev U:[FA-1]: constructor sets correct values
    function test_U_FA_01_constructor_sets_correct_values() public allDegenNftCases allExpirableCases {
        assertEq(creditFacade.creditManager(), address(creditManagerMock), "Incorrect creditManager");
        assertEq(creditFacade.underlying(), tokenTestSuite.addressOf(Tokens.DAI), "Incorrect underlying");
        assertEq(creditFacade.treasury(), treasury, "Incorrect treasury");

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
        creditFacade.partiallyLiquidateCreditAccount({
            creditAccount: DUMB_ADDRESS,
            token: address(0),
            repaidAmount: 0,
            minSeizedAmount: 0,
            to: DUMB_ADDRESS,
            priceUpdates: new PriceUpdate[](0)
        });

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
        creditFacade.partiallyLiquidateCreditAccount({
            creditAccount: DUMB_ADDRESS,
            token: address(0),
            repaidAmount: 0,
            minSeizedAmount: 0,
            to: DUMB_ADDRESS,
            priceUpdates: new PriceUpdate[](0)
        });

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.multicall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.botMulticall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});
    }

    /// @dev U:[FA-5]: Account management functions revert if account does not exist
    function test_U_FA_05_account_management_functions_revert_if_account_does_not_exist() public notExpirableCase {
        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditFacade.closeCreditAccount({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditFacade.multicall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditFacade.botMulticall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});
    }

    /// @dev U:[FA-6]: all configurator functions revert if called by non-configurator
    function test_U_FA_06_all_configurator_functions_revert_if_called_by_non_configurator() public notExpirableCase {
        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setExpirationDate(0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setDebtLimits(0, 0, 0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setLossLiquidator(address(0));

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setForbiddenTokensMask(0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setEmergencyLiquidator(address(0), AllowanceAction.ALLOW);
    }

    /// @dev U:[FA-7]: payable functions wraps eth to msg.sender
    function test_U_FA_07_payable_functions_wraps_eth_to_msg_sender() public notExpirableCase {
        vm.deal(USER, 3 ether);
        creditManagerMock.setManageDebt(1 ether);

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1 ether, 9 ether, 9);
        vm.roll(block.number + 1);

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

        vm.expectRevert(ForbiddenInWhitelistedModeException.selector);
        vm.prank(USER);
        creditFacade.openCreditAccount({onBehalfOf: FRIEND, calls: new MultiCall[](0), referralCode: 0});

        vm.expectRevert(InsufficientBalanceException.selector);
        vm.prank(USER);
        creditFacade.openCreditAccount({onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});
    }

    /// @dev U:[FA-10]: openCreditAccount wokrs as expected
    function test_U_FA_10_openCreditAccount_works_as_expected() public notExpirableCase {
        address token = makeAddr("token");
        address expectedCreditAccount = DUMB_ADDRESS;

        creditManagerMock.setReturnOpenCreditAccount(expectedCreditAccount);

        vm.expectCall(address(creditManagerMock), abi.encodeCall(ICreditManagerV3.openCreditAccount, (FRIEND)));

        vm.expectEmit(true, true, true, true);
        emit ICreditFacadeV3.OpenCreditAccount(expectedCreditAccount, FRIEND, USER, REFERRAL_CODE);

        vm.expectEmit(true, true, false, false);
        emit ICreditFacadeV3.StartMultiCall({creditAccount: expectedCreditAccount, caller: USER});

        vm.expectEmit(true, false, false, false);
        emit ICreditFacadeV3.FinishMultiCall();

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck,
                (expectedCreditAccount, UNDERLYING_TOKEN_MASK, new uint256[](0), PERCENTAGE_FACTOR, false)
            )
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount({
            onBehalfOf: FRIEND,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (token, 0))
                })
            ),
            referralCode: REFERRAL_CODE
        });

        assertEq(creditAccount, expectedCreditAccount, "Incorrect credit account");
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
        if (!hasCalls) creditManagerMock.setRevertOnActiveAccount(true);

        if (hasCalls) {
            vm.expectCall(
                address(creditManagerMock), abi.encodeCall(ICreditManagerV3.enabledTokensMaskOf, (creditAccount))
            );
        }

        vm.expectCall(address(creditManagerMock), abi.encodeCall(ICreditManagerV3.closeCreditAccount, (creditAccount)));

        if (hasCalls) {
            calls =
                MultiCallBuilder.build(MultiCall({target: adapter, callData: abi.encodeCall(AdapterMock.dumbCall, ())}));
        }

        if (hasBotPermissions) {
            vm.expectCall(address(botListMock), abi.encodeCall(IBotListV3.eraseAllBotPermissions, (creditAccount)));
        }

        vm.expectEmit(true, true, true, true);
        emit ICreditFacadeV3.CloseCreditAccount(creditAccount, USER);

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
            if (addNonUnderlying) {
                vm.expectRevert(abi.encodeWithSelector(RemainingTokenBalanceIncreasedException.selector, (link)));
            }

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
        creditManagerMock.setLiquidateCreditAccountReturns(123, 0);

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.calcDebtAndCollateral, (creditAccount, CollateralCalcTask.DEBT_COLLATERAL))
        );

        CollateralDebtData memory collateralDebtDataAfter = collateralDebtData;
        collateralDebtDataAfter.enabledTokensMask = 1 | 2 | 4;
        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                ICreditManagerV3.liquidateCreditAccount, (creditAccount, collateralDebtDataAfter, FRIEND, false)
            )
        );

        vm.expectEmit(true, true, true, true);
        emit ICreditFacadeV3.LiquidateCreditAccount(creditAccount, LIQUIDATOR, FRIEND, 123);

        vm.prank(LIQUIDATOR);
        uint256 loss = creditFacade.liquidateCreditAccount({
            creditAccount: creditAccount,
            to: FRIEND,
            calls: MultiCallBuilder.build(
                MultiCall(address(creditFacade), abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (link, 2))),
                MultiCall(
                    address(creditFacade), abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (usdc, 2, FRIEND))
                )
            )
        });
        assertEq(loss, 0, "Non-zero loss");
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

        // loss forbids borrowing, anyone can call
        vm.prank(FRIEND);
        uint256 loss =
            creditFacade.liquidateCreditAccount({creditAccount: creditAccount, to: FRIEND, calls: new MultiCall[](0)});
        assertEq(loss, 100, "Incorrect loss");
        assertEq(creditFacade.maxDebtPerBlockMultiplier(), 0, "Borrowing not forbidden");

        vm.etch(LIQUIDATOR, "CODE");
        vm.prank(CONFIGURATOR);
        creditFacade.setLossLiquidator(LIQUIDATOR);

        // only the loss liquidator can call
        vm.expectRevert(CallerNotLossLiquidatorException.selector);
        vm.prank(FRIEND);
        creditFacade.liquidateCreditAccount({creditAccount: creditAccount, to: FRIEND, calls: new MultiCall[](0)});

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount({creditAccount: creditAccount, to: FRIEND, calls: new MultiCall[](0)});
        assertEq(loss, 100, "Incorrect loss");
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

        uint256 enabledTokensMask = 123123123;

        botListMock.setBotPermissionsReturns(ALL_PERMISSIONS);

        creditManagerMock.setEnabledTokensMask(enabledTokensMask);
        creditManagerMock.setBorrower(USER);

        for (uint256 testCase = 0; testCase < 2; ++testCase) {
            bool botMulticallCase = testCase == 1;

            vm.expectCall(
                address(creditManagerMock),
                abi.encodeCall(
                    ICreditManagerV3.fullCollateralCheck,
                    (creditAccount, enabledTokensMask, new uint256[](0), PERCENTAGE_FACTOR, false)
                )
            );

            vm.expectEmit(true, true, false, false);
            emit ICreditFacadeV3.StartMultiCall({
                creditAccount: creditAccount,
                caller: botMulticallCase ? address(this) : USER
            });

            vm.expectEmit(true, false, false, false);
            emit ICreditFacadeV3.FinishMultiCall();

            if (botMulticallCase) {
                creditFacade.botMulticall(creditAccount, calls);
            } else {
                vm.prank(USER);
                creditFacade.multicall(creditAccount, calls);
            }
        }
    }

    /// @dev U:[FA-19]: botMulticall reverts for not approved bots
    function test_U_FA_19_botMulticall_reverts_for_not_approved_bots() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;
        creditManagerMock.setBorrower(USER);
        MultiCall[] memory calls;

        botListMock.setBotPermissionsReturns(0);
        vm.expectRevert(abi.encodeWithSelector(NotApprovedBotException.selector, (address(this))));
        creditFacade.botMulticall(creditAccount, calls);
    }

    struct MultiCallPermissionTestCase {
        bytes callData;
        uint192 permissionRequired;
    }

    /// @dev U:[FA-21]: multicall reverts if called without particaular permission
    function test_U_FA_21_multicall_reverts_if_called_without_particaular_permission() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        address token = tokenTestSuite.addressOf(Tokens.LINK);
        creditManagerMock.addToken(token, 1 << 4);

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, 100, 1);

        creditManagerMock.setManageDebt(2);

        creditManagerMock.setPriceOracle(address(priceOracleMock));

        address priceFeed = address(new UpdatablePriceFeedMock());

        priceOracleMock.addPriceFeed(token, priceFeed);

        creditManagerMock.setBorrower(USER);

        MultiCallPermissionTestCase[7] memory cases = [
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (token, 0)),
                permissionRequired: ADD_COLLATERAL_PERMISSION
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateralWithPermit, (token, 0, 0, 0, bytes32(0), bytes32(0))
                ),
                permissionRequired: ADD_COLLATERAL_PERMISSION
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (1)),
                permissionRequired: INCREASE_DEBT_PERMISSION
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (0)),
                permissionRequired: DECREASE_DEBT_PERMISSION
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (token, 0, 0)),
                permissionRequired: UPDATE_QUOTA_PERMISSION
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (token, 0, USER)),
                permissionRequired: WITHDRAW_COLLATERAL_PERMISSION
            }),
            MultiCallPermissionTestCase({
                callData: abi.encodeCall(ICreditFacadeV3Multicall.setBotPermissions, (address(0), 0)),
                permissionRequired: SET_BOT_PERMISSIONS_PERMISSION
            })
        ];

        uint256 len = cases.length;
        for (uint256 i = 0; i < len; ++i) {
            vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, cases[i].permissionRequired));

            creditFacade.multicallInt({
                creditAccount: creditAccount,
                calls: MultiCallBuilder.build(MultiCall({target: address(creditFacade), callData: cases[i].callData})),
                enabledTokensMask: 0,
                flags: ALL_PERMISSIONS & ~cases[i].permissionRequired
            });
        }

        vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, EXTERNAL_CALLS_PERMISSION));
        creditFacade.multicallInt(
            creditAccount,
            MultiCallBuilder.build(MultiCall({target: DUMB_ADDRESS4, callData: bytes("")})),
            0,
            ALL_PERMISSIONS & ~EXTERNAL_CALLS_PERMISSION
        );
    }

    /// @dev U:[FA-22]: multicall reverts if unexpected method is called
    function test_U_FA_22_multicall_reverts_if_unexpected_method_is_called() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        vm.expectRevert(
            abi.encodeWithSelector(
                UnknownMethodException.selector, (ICreditFacadeV3Multicall.setFullCheckParams.selector)
            )
        );
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.setFullCheckParams, (new uint256[](0), 0))
                })
            ),
            enabledTokensMask: 0,
            flags: SKIP_COLLATERAL_CHECK_FLAG
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                UnknownMethodException.selector, (ICreditFacadeV3Multicall.onDemandPriceUpdates.selector)
            )
        );
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall(
                    address(creditFacade),
                    abi.encodeCall(ICreditFacadeV3Multicall.setFullCheckParams, (new uint256[](0), PERCENTAGE_FACTOR))
                ),
                MultiCall(
                    address(creditFacade),
                    abi.encodeCall(ICreditFacadeV3Multicall.onDemandPriceUpdates, (new PriceUpdate[](0)))
                )
            ),
            enabledTokensMask: 0,
            flags: 0
        });

        vm.expectRevert(abi.encodeWithSelector(UnknownMethodException.selector, (bytes4(bytes("123")))));
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
                vm.expectRevert(abi.encodeWithSelector(BalanceLessThanExpectedException.selector, (link)));
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
                vm.expectRevert(abi.encodeWithSelector(BalanceLessThanExpectedException.selector, (link)));
            }

            creditFacade.multicallInt({
                creditAccount: creditAccount,
                calls: calls,
                enabledTokensMask: 0,
                flags: EXTERNAL_CALLS_PERMISSION
            });
        }
    }

    /// @dev U:[FA-24]: multicall `setFullCheckParams` works properly
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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.setFullCheckParams, (collateralHints, minHealthFactor))
                })
            ),
            enabledTokensMask: 0,
            flags: 0
        });

        minHealthFactor = PERCENTAGE_FACTOR;
        collateralHints = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(InvalidCollateralHintException.selector, (0)));
        creditFacade.multicallInt({
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

        collateralHints[0] = 3;
        vm.expectRevert(abi.encodeWithSelector(InvalidCollateralHintException.selector, (3)));
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

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                creditManagerMock.fullCollateralCheck,
                (creditAccount, UNDERLYING_TOKEN_MASK, collateralHints, minHealthFactor, false)
            )
        );
        creditFacade.multicallInt({
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
    }

    /// @dev U:[FA-25]: multicall `onDemandPriceUpdates` works properly
    function test_U_FA_25_multicall_onDemandPriceUpdates_works_properly() public notExpirableCase {
        creditManagerMock.setPriceOracle(address(priceOracleMock));

        PriceUpdate[] memory updates = new PriceUpdate[](2);
        updates[0] = PriceUpdate(makeAddr("token0"), "data0");
        updates[1] = PriceUpdate(makeAddr("token1"), "data1");

        vm.expectCall(address(priceOracleMock), abi.encodeCall(IPriceOracleV3.updatePrices, (updates)));
        creditFacade.multicallInt({
            creditAccount: DUMB_ADDRESS,
            calls: MultiCallBuilder.build(
                MultiCall(address(creditFacade), abi.encodeCall(ICreditFacadeV3Multicall.onDemandPriceUpdates, (updates)))
            ),
            enabledTokensMask: 0,
            flags: 0
        });
    }

    /// @dev U:[FA-26A]: multicall addCollateral works properly
    function test_U_FA_26A_multicall_addCollateral_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        address token = tokenTestSuite.addressOf(Tokens.LINK);
        uint256 amount = 12333345;

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (token, amount))
            })
        );

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.addCollateral, (address(this), creditAccount, token, amount))
        );

        vm.expectEmit(true, true, true, true);
        emit ICreditFacadeV3.AddCollateral(creditAccount, token, amount);

        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: calls,
            enabledTokensMask: UNDERLYING_TOKEN_MASK,
            flags: ADD_COLLATERAL_PERMISSION
        });
    }

    /// @dev U:[FA-26B]: multicall addCollateralWithPermit works properly
    function test_U_FA_26B_multicall_addCollateralWithPermit_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        (address user, uint256 key) = makeAddrAndKey("user");

        ERC20PermitMock token = new ERC20PermitMock("Test Token", "TEST", 18);
        uint256 amount = 12333345;
        uint256 deadline = block.timestamp + 1;

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

        vm.expectCall(
            address(token),
            abi.encodeCall(IERC20Permit.permit, (user, address(creditManagerMock), amount, deadline, v, r, s))
        );

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.addCollateral, (user, creditAccount, address(token), amount))
        );

        vm.expectEmit(true, true, true, true);
        emit ICreditFacadeV3.AddCollateral(creditAccount, address(token), amount);

        vm.prank(user);
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: calls,
            enabledTokensMask: UNDERLYING_TOKEN_MASK,
            flags: ADD_COLLATERAL_PERMISSION
        });
    }

    /// @dev U:[FA-27]: multicall increaseDebt works properly
    function test_U_FA_27_multicall_increaseDebt_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        uint256 amount = 50;

        uint256 mask = 1232322;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, 100, 1);

        creditFacade.setLastBlockBorrowed(uint64(block.number + 100));
        creditFacade.setTotalBorrowedInBlock(0);
        vm.roll(block.number + 100);

        uint256 debtInBlock = creditFacade.totalBorrowedInBlockInt();

        creditManagerMock.setManageDebt(50);

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

        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: calls,
            enabledTokensMask: mask,
            flags: INCREASE_DEBT_PERMISSION
        });

        assertEq(creditFacade.totalBorrowedInBlockInt(), debtInBlock + amount, "Debt in block was updated incorrectly");
    }

    /// @dev U:[FA-28]: multicall increaseDebt reverts if out of debt
    function test_U_FA_28_multicall_increaseDebt_reverts_if_out_of_debt() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        uint128 maxDebt = 100;

        uint256 mask = 1232322;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, maxDebt, 1);
        vm.roll(block.number + 1);

        creditManagerMock.setManageDebt(50);

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

        creditManagerMock.setManageDebt(maxDebt + 1);

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

    /// @dev U:[FA-31]: multicall decreaseDebt works properly
    function test_U_FA_31_multicall_decreaseDebt_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        uint256 amount = 50;

        uint256 mask = 1232322 | UNDERLYING_TOKEN_MASK;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, 100, 1);

        creditManagerMock.setManageDebt(50);

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.manageDebt, (creditAccount, amount, mask, ManageDebtAction.DECREASE_DEBT))
        );

        creditFacade.multicallInt({
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
    }

    /// @dev U:[FA-32]: multicall decreaseDebt reverts if out of debt
    function test_U_FA_32_multicall_decreaseDebt_reverts_if_out_of_debt() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        uint128 minDebt = 100;

        uint256 mask = 1232322;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(minDebt, minDebt + 100, 1);

        creditManagerMock.setManageDebt(minDebt - 1);

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

    /// @dev U:[FA-33]: multicall decreaseDebt allows zero debt
    function test_U_FA_33_multicall_decreaseDebt_allows_zero_debt() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        uint128 minDebt = 100;

        uint256 mask = 1232322;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(minDebt, minDebt + 100, 1);

        creditManagerMock.setManageDebt(0);

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

    /// @dev U:[FA-34]: multicall updateQuota works properly
    function test_U_FA_34_multicall_updateQuota_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        address underlying = tokenTestSuite.addressOf(Tokens.DAI);
        vm.expectRevert(TokenIsNotQuotedException.selector);
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (underlying, 0, 0))
                })
            ),
            enabledTokensMask: 0,
            flags: UPDATE_QUOTA_PERMISSION
        });

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

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                creditManagerMock.fullCollateralCheck,
                (creditAccount, maskToEnable | UNDERLYING_TOKEN_MASK, new uint256[](0), PERCENTAGE_FACTOR, false)
            )
        );
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (link, change, 0))
                })
            ),
            enabledTokensMask: maskToDisable,
            flags: UPDATE_QUOTA_PERMISSION
        });
    }

    /// @dev U:[FA-36]: multicall `withdrawCollateral` works properly
    function test_U_FA_36_multicall_withdrawCollateral_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        address link = tokenTestSuite.addressOf(Tokens.LINK);

        uint256 amount = 100;

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.withdrawCollateral, (creditAccount, link, amount, USER))
        );

        vm.expectEmit(true, true, false, true);
        emit ICreditFacadeV3.WithdrawCollateral(creditAccount, link, amount, USER);

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                creditManagerMock.fullCollateralCheck,
                (creditAccount, UNDERLYING_TOKEN_MASK, new uint256[](0), PERCENTAGE_FACTOR, true)
            )
        );

        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (link, amount, USER))
                })
            ),
            enabledTokensMask: 0,
            flags: WITHDRAW_COLLATERAL_PERMISSION
        });
    }

    /// @dev U:[FA-36A]: multicall `withdrawCollateral` with phantom tokens works properly
    function test_U_FA_36A_multicall_withdrawCollateral_with_phantom_token_works_correctly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        address ptUnderlying = makeAddr("PTU");

        PhantomTokenMock ptMock = new PhantomTokenMock(ptUnderlying);

        address adapter = address(new PhantomTokenAdapterMock(address(creditManagerMock), address(ptMock)));

        creditManagerMock.setContractAllowance(address(adapter), address(ptMock));

        uint256 amount = 100;

        vm.expectCall(address(adapter), abi.encodeCall(PhantomTokenMock.withdrawalCall, (DUMB_ADDRESS, 100)));

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.withdrawCollateral, (creditAccount, ptUnderlying, amount, USER))
        );

        vm.expectEmit(true, true, false, true);
        emit WithdrawCollateral(creditAccount, ptUnderlying, amount, USER);

        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (address(ptMock), amount, USER))
                })
            ),
            enabledTokensMask: 0,
            flags: WITHDRAW_COLLATERAL_PERMISSION
        });
    }

    /// @dev U:[FA-37]: multicall `setBotPermissions` works properly
    function test_U_FA_37_setBotPermissions_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;
        address bot = makeAddr("BOT");

        creditManagerMock.setBorrower(USER);

        // It reverts if passed unexpected permissions, e.g. `1 << 3`
        vm.expectRevert(abi.encodeWithSelector(UnexpectedPermissionsException.selector, (1 << 3)));
        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall(
                    address(creditFacade), abi.encodeCall(ICreditFacadeV3Multicall.setBotPermissions, (bot, 1 << 3))
                )
            )
        );

        // It calls `botList.setBotPermissions` otherwise
        vm.expectCall(address(botListMock), abi.encodeCall(IBotListV3.setBotPermissions, (bot, creditAccount, 1)));
        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall(address(creditFacade), abi.encodeCall(ICreditFacadeV3Multicall.setBotPermissions, (bot, 1)))
            )
        );
    }

    /// @dev U:[FA-38]: multicall external call works properly
    function test_U_FA_38_multicall_externalCall_works_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        creditManagerMock.setBorrower(USER);

        AdapterMock adapter = new AdapterMock(address(creditManagerMock), DUMB_ADDRESS);
        adapter.setReturn_useSafePrices(true);

        creditManagerMock.setContractAllowance({adapter: address(adapter), targetContract: DUMB_ADDRESS});

        vm.expectCall(address(adapter), abi.encodeCall(adapter.dumbCall, ()));

        vm.expectCall(
            address(creditManagerMock), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (creditAccount))
        );

        vm.expectCall(address(creditManagerMock), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (address(1))));

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                creditManagerMock.fullCollateralCheck,
                (creditAccount, UNDERLYING_TOKEN_MASK, new uint256[](0), PERCENTAGE_FACTOR, true)
            )
        );

        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall({target: address(adapter), callData: abi.encodeCall(adapter.dumbCall, ())})
            ),
            enabledTokensMask: 0,
            flags: EXTERNAL_CALLS_PERMISSION
        });
    }

    /// @dev U:[FA-39]: revertIfNoPermission works properly
    function test_U_FA_39_revertIfNoPermission_works_properly(uint256 mask) public notExpirableCase {
        uint8 index = uint8(getHash(mask, 1));
        uint256 permission = 1 << index;

        creditFacade.revertIfNoPermission(mask | permission, permission);

        vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, permission));

        creditFacade.revertIfNoPermission(mask & ~(permission), permission);
    }

    /// @dev U:[FA-43]: revertIfOutOfDebtPerBlockLimit works properly
    function test_U_FA_43_revertIfOutOfDebtPerBlockLimit_works_properly() public notExpirableCase {
        //
        // Case: It does nothing is maxDebtPerBlockMultiplier == type(uint8).max
        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(0, 0, type(uint8).max);
        creditFacade.revertIfOutOfDebtPerBlockLimit(type(uint256).max);

        //
        // Case: it updates lastBlockBorrowed and rewrites totalBorrowedInBlock for new block
        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(0, 800, 2);

        creditFacade.setTotalBorrowedInBlock(500);

        uint64 blockNow = 100;
        creditFacade.setLastBlockBorrowed(blockNow - 1);

        vm.roll(blockNow);
        creditFacade.revertIfOutOfDebtPerBlockLimit(200);

        assertEq(creditFacade.lastBlockBorrowedInt(), blockNow, "Incorrect lastBlockBorrowed");
        assertEq(creditFacade.totalBorrowedInBlockInt(), 200, "Incorrect totalBorrowedInBlock");

        //
        // Case: it summarize if the called in the same block
        creditFacade.revertIfOutOfDebtPerBlockLimit(400);

        assertEq(creditFacade.lastBlockBorrowedInt(), blockNow, "Incorrect lastBlockBorrowed");
        assertEq(creditFacade.totalBorrowedInBlockInt(), 200 + 400, "Incorrect totalBorrowedInBlock");

        //
        // Case it reverts if borrowed more than limit
        vm.expectRevert(BorrowedBlockLimitException.selector);
        creditFacade.revertIfOutOfDebtPerBlockLimit(800 * 2 - (200 + 400) + 1);
    }

    /// @dev U:[FA-44]: revertIfOutOfDebtLimits works properly
    function test_U_FA_44_revertIfOutOfDebtLimits_works_properly() public notExpirableCase {
        uint128 minDebt = 100;
        uint128 maxDebt = 200;

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(minDebt, maxDebt, 1);

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        creditFacade.revertIfOutOfDebtLimits(0, ManageDebtAction.INCREASE_DEBT);

        creditFacade.revertIfOutOfDebtLimits(0, ManageDebtAction.DECREASE_DEBT);

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        creditFacade.revertIfOutOfDebtLimits(minDebt - 1, ManageDebtAction.INCREASE_DEBT);

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        creditFacade.revertIfOutOfDebtLimits(minDebt - 1, ManageDebtAction.DECREASE_DEBT);

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        creditFacade.revertIfOutOfDebtLimits(maxDebt + 1, ManageDebtAction.INCREASE_DEBT);

        creditFacade.revertIfOutOfDebtLimits(maxDebt + 1, ManageDebtAction.DECREASE_DEBT);
    }

    /// @dev U:[FA-45]: multicall handles forbidden tokens properly
    function test_U_FA_45_multicall_handles_forbidden_tokens_properly() public notExpirableCase {
        address creditAccount = DUMB_ADDRESS;

        address link = tokenTestSuite.addressOf(Tokens.LINK);
        uint256 linkMask = 1 << 8;
        creditManagerMock.addToken(link, linkMask);

        vm.prank(CONFIGURATOR);
        creditFacade.setForbiddenTokensMask(linkMask);

        AdapterMock adapter = new AdapterMock(address(creditManagerMock), address(tokenTestSuite));
        vm.prank(CONFIGURATOR);
        creditManagerMock.setContractAllowance({adapter: address(adapter), targetContract: address(tokenTestSuite)});

        // reverts if trying to increase debt if there are enabled foribdden tokens
        vm.expectRevert(abi.encodeWithSelector(ForbiddenTokensException.selector, (linkMask)));
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall(address(creditFacade), abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (0)))
            ),
            enabledTokensMask: linkMask,
            flags: INCREASE_DEBT_PERMISSION
        });

        // reverts if trying to withdraw collateral if there are enabled foribdden tokens
        vm.expectRevert(abi.encodeWithSelector(ForbiddenTokensException.selector, (linkMask)));
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall(
                    address(creditFacade), abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (link, 0, USER))
                )
            ),
            enabledTokensMask: linkMask,
            flags: WITHDRAW_COLLATERAL_PERMISSION
        });

        // reverts if trying to perform unsafe adapter call if there are enabled foribdden tokens
        adapter.setReturn_useSafePrices(true);
        vm.expectRevert(abi.encodeWithSelector(ForbiddenTokensException.selector, (linkMask)));
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(MultiCall(address(adapter), abi.encodeCall(adapter.dumbCall, ()))),
            enabledTokensMask: linkMask,
            flags: EXTERNAL_CALLS_PERMISSION
        });

        // reverts on trying to increase quota of forbidden token
        vm.expectRevert(abi.encodeWithSelector(ForbiddenTokenQuotaIncreasedException.selector, (link)));
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall(address(creditFacade), abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (link, 1, 0)))
            ),
            enabledTokensMask: 0,
            flags: UPDATE_QUOTA_PERMISSION
        });

        // reverts on trying to increase balance of enabled forbidden token
        adapter.setReturn_useSafePrices(false);
        vm.expectRevert(abi.encodeWithSelector(ForbiddenTokenBalanceIncreasedException.selector, (link)));
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(
                MultiCall(
                    address(adapter), abi.encodeWithSignature("mint(uint8,address,uint256)", Tokens.LINK, creditAccount, 10)
                )
            ),
            enabledTokensMask: linkMask,
            flags: EXTERNAL_CALLS_PERMISSION
        });

        // enabled forbidden tokens activate collateral check with safe prices
        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(
                creditManagerMock.fullCollateralCheck,
                (creditAccount, linkMask | UNDERLYING_TOKEN_MASK, new uint256[](0), PERCENTAGE_FACTOR, true)
            )
        );
        creditFacade.multicallInt({
            creditAccount: creditAccount,
            calls: MultiCallBuilder.build(),
            enabledTokensMask: linkMask,
            flags: 0
        });
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
    function test_U_FA_48_setExpirationDate_works_properly() public expirableCase {
        assertEq(creditFacade.expirationDate(), 0, "SETUP: incorrect expiration date");

        vm.prank(CONFIGURATOR);
        creditFacade.setExpirationDate(100);

        assertEq(creditFacade.expirationDate(), expirable ? 100 : 0, "Incorrect expiration date");
    }

    /// @dev U:[FA-49]: setDebtLimits works properly
    function test_U_FA_49_setDebtLimits_works_properly() public notExpirableCase {
        (uint128 minDebt, uint128 maxDebt) = creditFacade.debtLimits();
        assertEq(
            creditFacade.maxDebtPerBlockMultiplier(),
            DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER,
            "SETUP: incorrect maxDebtPerBlockMultiplier"
        );
        assertEq(minDebt, 0, "SETUP: incorrect minDebt");
        assertEq(maxDebt, 0, "SETUP: incorrect maxDebt");
        assertEq(creditFacade.lastBlockBorrowedInt(), 0, "SETUP: incorrect lastBlockBorrowed");
        assertEq(creditFacade.totalBorrowedInBlockInt(), 0, "SETUP: incorrect totalBorrowedInBlock");

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits({newMinDebt: 1, newMaxDebt: 2, newMaxDebtPerBlockMultiplier: 3});

        (minDebt, maxDebt) = creditFacade.debtLimits();
        assertEq(creditFacade.maxDebtPerBlockMultiplier(), 3, " incorrect maxDebtPerBlockMultiplier");
        assertEq(minDebt, 1, " incorrect minDebt");
        assertEq(maxDebt, 2, " incorrect maxDebt");
        assertEq(creditFacade.lastBlockBorrowedInt(), block.number, "incorrect lastBlockBorrowed");
        assertEq(creditFacade.totalBorrowedInBlockInt(), type(uint128).max, "incorrect totalBorrowedInBlock");
    }

    /// @dev U:[FA-51]: setForbiddenTokensMask works properly
    function test_U_FA_51_setForbiddenTokensMask_works_properly() public notExpirableCase {
        assertEq(creditFacade.forbiddenTokenMask(), 0, "SETUP: incorrect forbiddenTokenMask");

        uint256 newForbiddenTokensMask = 123;
        vm.prank(CONFIGURATOR);
        creditFacade.setForbiddenTokensMask(newForbiddenTokensMask);

        assertEq(creditFacade.forbiddenTokenMask(), newForbiddenTokensMask, "incorrect forbiddenTokenMask");
    }

    /// @dev U:[FA-52]: `setLossLiquidator` works properly
    function test_U_FA_52_setLossLiquidator_works_properly() public notExpirableCase {
        assertEq(creditFacade.lossLiquidator(), address(0), "SETUP: incorrect loss liquidator");

        vm.prank(CONFIGURATOR);
        creditFacade.setLossLiquidator(LIQUIDATOR);

        assertEq(creditFacade.lossLiquidator(), LIQUIDATOR, "Loss liquidator not set");
        assertTrue(creditFacade.canLiquidateWhilePaused(LIQUIDATOR), "Loss liquidator can't liquidate on pause");

        vm.prank(CONFIGURATOR);
        creditFacade.setLossLiquidator(address(0));

        assertEq(creditFacade.lossLiquidator(), address(0), "Loss liquidator not unset");
        assertFalse(creditFacade.canLiquidateWhilePaused(LIQUIDATOR), "Loss liquidator still can liquidate on pause");
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
