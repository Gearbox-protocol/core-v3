// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";

import {CreditFacadeV3} from "../../../credit/CreditFacadeV3.sol";
import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";

import {BotList} from "../../../support/BotList.sol";
import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";

import {ICreditAccountBase} from "../../../interfaces/ICreditAccountV3.sol";
import "../../../interfaces/ICreditFacade.sol";
import {
    ICreditManagerV3,
    ICreditManagerV3Events,
    ClosureAction,
    ManageDebtAction,
    BOT_PERMISSIONS_SET_FLAG
} from "../../../interfaces/ICreditManagerV3.sol";
import {AllowanceAction} from "../../../interfaces/ICreditConfiguratorV3.sol";
import "../../../interfaces/ICreditFacade.sol";
import {IDegenNFT, IDegenNFTExceptions} from "@gearbox-protocol/core-v2/contracts/interfaces/IDegenNFT.sol";
import {IWithdrawalManager} from "../../../interfaces/IWithdrawalManager.sol";
import {MultiCallBuilder} from "../../lib/MultiCallBuilder.sol";

// DATA
import {MultiCall, MultiCallOps} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {Balance} from "../../../libraries/BalancesLogic.sol";

import {CreditFacadeMulticaller, CreditFacadeCalls} from "../../../multicall/CreditFacadeCalls.sol";

// CONSTANTS

import {LEVERAGE_DECIMALS} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// TESTS

import "../../lib/constants.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";
import {CreditFacadeTestHelper} from "../../helpers/CreditFacadeTestHelper.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// MOCKS
import {AdapterMock} from "../../mocks//adapters/AdapterMock.sol";
import {TargetContractMock} from "@gearbox-protocol/core-v2/contracts/test/mocks/adapters/TargetContractMock.sol";
import {ERC20BlacklistableMock} from "../../mocks//token/ERC20Blacklistable.sol";
import {GeneralMock} from "../../mocks//GeneralMock.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";
import {CreditFacadeTestSuite} from "../../suites/CreditFacadeTestSuite.sol";
import {CreditConfig} from "../../config/CreditConfig.sol";

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

uint256 constant WETH_TEST_AMOUNT = 5 * WAD;
uint16 constant REFERRAL_CODE = 23;

/// @title CreditFacadeTest
/// @notice Designed for unit test purposes only
contract CreditFacadeIntegrationTest is
    Test,
    BalanceHelper,
    CreditFacadeTestHelper,
    ICreditManagerV3Events,
    ICreditFacadeEvents
{
    using CreditFacadeCalls for CreditFacadeMulticaller;

    AccountFactory accountFactory;

    TargetContractMock targetMock;
    AdapterMock adapterMock;

    BotList botList;

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
         supportQuotas: supportQuotas,
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
    ///
    ///  HELPERS
    ///
    ///

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

    function _checkForWETHTest() internal {
        _checkForWETHTest(USER);
    }

    function _checkForWETHTest(address tester) internal {
        expectBalance(Tokens.WETH, tester, WETH_TEST_AMOUNT);

        expectEthBalance(tester, 0);
    }

    function _prepareMockCall() internal returns (bytes memory callData) {
        vm.prank(CONFIGURATOR);
        creditConfigurator.allowAdapter(address(adapterMock));

        callData = abi.encodeWithSignature("hello(string)", "world");
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    // TODO: ideas how to revert with ZA?

    // /// @dev I:[FA-1]: constructor reverts for zero address
    // function test_I_FA_01_constructor_reverts_for_zero_address() public {
    //     vm.expectRevert(ZeroAddressException.selector);
    //     new CreditFacadeV3(address(0), address(0), address(0), false);
    // }

    /// @dev I:[FA-1A]: constructor sets correct values
    function test_I_FA_01A_constructor_sets_correct_values() public {
        assertEq(address(creditFacade.creditManager()), address(creditManager), "Incorrect creditManager");
        // assertEq(creditFacade.underlying(), underlying, "Incorrect underlying token");

        assertEq(creditFacade.weth(), creditManager.weth(), "Incorrect weth token");

        assertEq(creditFacade.degenNFT(), address(0), "Incorrect degenNFT");

        // assertTrue(creditFacade.whitelisted() == false, "Incorrect whitelisted");

        _setUp({
            _underlying: Tokens.DAI,
            withDegenNFT: true,
            withExpiration: false,
            supportQuotas: false,
            accountFactoryVer: 1
        });
        creditFacade = cft.creditFacade();

        assertEq(creditFacade.degenNFT(), address(cft.degenNFT()), "Incorrect degenNFT");

        // assertTrue(creditFacade.whitelisted() == true, "Incorrect whitelisted");
    }

    //
    // ALL FUNCTIONS REVERTS IF USER HAS NO ACCOUNT
    //

    /// @dev I:[FA-2]: functions reverts if borrower has no account
    function test_I_FA_02_functions_reverts_if_credit_account_not_exists() public {
        vm.expectRevert(CreditAccountNotExistsException.selector);
        vm.prank(USER);
        creditFacade.closeCreditAccount(DUMB_ADDRESS, FRIEND, 0, false, MultiCallBuilder.build());

        vm.expectRevert(CreditAccountNotExistsException.selector);
        vm.prank(USER);
        creditFacade.closeCreditAccount(
            DUMB_ADDRESS,
            FRIEND,
            0,
            false,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            )
        );

        vm.expectRevert(CreditAccountNotExistsException.selector);
        vm.prank(USER);
        creditFacade.liquidateCreditAccount(DUMB_ADDRESS, DUMB_ADDRESS, 0, false, MultiCallBuilder.build());

        vm.expectRevert(CreditAccountNotExistsException.selector);
        vm.prank(USER);
        creditFacade.multicall(
            DUMB_ADDRESS,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            )
        );

        // vm.prank(CONFIGURATOR);
        // creditConfigurator.allowContract(address(targetMock), address(adapterMock));
    }

    //
    // ETH => WETH TESTS
    //
    function test_I_FA_03B_openCreditAccountMulticall_correctly_wraps_ETH() public {
        /// - openCreditAccount

        _prepareForWETHTest();

        vm.prank(USER);
        creditFacade.openCreditAccount{value: WETH_TEST_AMOUNT}(
            DAI_ACCOUNT_AMOUNT,
            USER,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            ),
            0
        );
        _checkForWETHTest();
    }

    function test_I_FA_03C_closeCreditAccount_correctly_wraps_ETH() public {
        (address creditAccount,) = _openTestCreditAccount();

        vm.roll(block.number + 1);

        _prepareForWETHTest();
        vm.prank(USER);
        creditFacade.closeCreditAccount{value: WETH_TEST_AMOUNT}(
            creditAccount, USER, 0, false, MultiCallBuilder.build()
        );
        _checkForWETHTest();
    }

    function test_I_FA_03F_multicall_correctly_wraps_ETH() public {
        (address creditAccount,) = _openTestCreditAccount();

        // MULTICALL
        _prepareForWETHTest();

        vm.prank(USER);
        creditFacade.multicall{value: WETH_TEST_AMOUNT}(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            )
        );
        _checkForWETHTest();
    }

    //
    // OPEN CREDIT ACCOUNT
    //

    /// @dev I:[FA-4B]: openCreditAccount reverts if user has no NFT for degen mode
    function test_I_FA_04B_openCreditAccount_reverts_for_non_whitelisted_account() public {
        _setUp({
            _underlying: Tokens.DAI,
            withDegenNFT: true,
            withExpiration: false,
            supportQuotas: false,
            accountFactoryVer: 1
        });

        (uint256 minBorrowedAmount,) = creditFacade.debtLimits();

        vm.expectRevert(IDegenNFTExceptions.InsufficientBalanceException.selector);

        vm.prank(FRIEND);
        creditFacade.openCreditAccount(
            minBorrowedAmount,
            FRIEND,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            ),
            0
        );
    }

    /// @dev I:[FA-4C]: openCreditAccount opens account and burns token
    function test_I_FA_04C_openCreditAccount_burns_token_in_whitelisted_mode() public {
        _setUp({
            _underlying: Tokens.DAI,
            withDegenNFT: true,
            withExpiration: false,
            supportQuotas: false,
            accountFactoryVer: 1
        });

        IDegenNFT degenNFT = IDegenNFT(creditFacade.degenNFT());

        vm.prank(CONFIGURATOR);
        degenNFT.mint(USER, 2);

        expectBalance(address(degenNFT), USER, 2);

        (address creditAccount,) = _openTestCreditAccount();

        expectBalance(address(degenNFT), USER, 1);
    }

    // /// @dev I:[FA-5]: openCreditAccount sets correct values
    // function test_I_FA_05_openCreditAccount_sets_correct_values() public {
    //     uint16 LEVERAGE = 300; // x3

    //     address expectedCreditAccountAddress = accountFactory.head();

    //     vm.prank(FRIEND);
    //     creditFacade.approveAccountTransfer(USER, true);

    //     vm.expectCall(
    //         address(creditManager),
    //         abi.encodeCall(
    //             "openCreditAccount(uint256,address)", (DAI_ACCOUNT_AMOUNT * LEVERAGE) / LEVERAGE_DECIMALS, FRIEND
    //         )
    //     );

    //     vm.expectEmit(true, true, false, true);
    //     emit OpenCreditAccount(
    //         FRIEND, expectedCreditAccountAddress, (DAI_ACCOUNT_AMOUNT * LEVERAGE) / LEVERAGE_DECIMALS, REFERRAL_CODE
    //     );

    //     vm.expectCall(
    //         address(creditManager),
    //         abi.encodeCall(
    //             "addCollateral(address,address,address,uint256)",
    //             USER,
    //             expectedCreditAccountAddress,
    //             underlying,
    //             DAI_ACCOUNT_AMOUNT
    //         )
    //     );

    //     vm.expectEmit(true, true, false, true);
    //     emit AddCollateral(creditAccount, FRIEND, underlying, DAI_ACCOUNT_AMOUNT);

    //     vm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, FRIEND, LEVERAGE, REFERRAL_CODE);
    // }

    /// @dev I:[FA-7]: openCreditAccount and openCreditAccount reverts when debt increase is forbidden
    function test_I_FA_07_openCreditAccountMulticall_reverts_if_borrowing_forbidden() public {
        (uint256 minBorrowedAmount,) = creditFacade.debtLimits();

        vm.prank(CONFIGURATOR);
        creditConfigurator.forbidBorrowing();

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
            })
        );

        vm.expectRevert(BorrowedBlockLimitException.selector);
        vm.prank(USER);
        creditFacade.openCreditAccount(minBorrowedAmount, USER, calls, 0);
    }

    /// @dev I:[FA-8]: openCreditAccount runs operations in correct order
    function test_I_FA_08_openCreditAccountMulticall_runs_operations_in_correct_order() public {
        RevocationPair[] memory revocations = new RevocationPair[](1);

        revocations[0] = RevocationPair({spender: address(this), token: underlying});

        // tokenTestSuite.mint(Tokens.DAI, USER, WAD);
        // tokenTestSuite.approve(Tokens.DAI, USER, address(creditManager));

        address expectedCreditAccountAddress = accountFactory.head();

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeMulticall.revokeAdapterAllowances, (revocations))
            })
        );

        // EXPECTED STACK TRACE & EVENTS

        vm.expectCall(
            address(creditManager), abi.encodeCall(ICreditManagerV3.openCreditAccount, (DAI_ACCOUNT_AMOUNT, FRIEND))
        );

        vm.expectEmit(true, true, false, true);
        emit OpenCreditAccount(expectedCreditAccountAddress, FRIEND, USER, DAI_ACCOUNT_AMOUNT, REFERRAL_CODE);

        vm.expectEmit(true, false, false, false);
        emit StartMultiCall(expectedCreditAccountAddress);

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.addCollateral, (USER, expectedCreditAccountAddress, underlying, DAI_ACCOUNT_AMOUNT)
            )
        );

        vm.expectEmit(true, true, false, true);
        emit AddCollateral(expectedCreditAccountAddress, underlying, DAI_ACCOUNT_AMOUNT);

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.revokeAdapterAllowances, (expectedCreditAccountAddress, revocations))
        );

        vm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck,
                (expectedCreditAccountAddress, 1, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        vm.prank(USER);
        creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, FRIEND, calls, REFERRAL_CODE);
    }

    /// @dev I:[FA-9]: openCreditAccount cant open credit account with hf <1;
    function test_I_FA_09_openCreditAccountMulticall_cant_open_credit_account_with_hf_less_one(
        uint256 amount,
        uint8 token1
    ) public {
        vm.assume(amount > 10000 && amount < DAI_ACCOUNT_AMOUNT);
        vm.assume(token1 > 0 && token1 < creditManager.collateralTokensCount());

        tokenTestSuite.mint(Tokens.DAI, address(creditManager.poolService()), type(uint96).max);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxDebtPerBlockMultiplier(type(uint8).max);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setLimits(1, type(uint96).max);

        (address collateral,) = creditManager.collateralTokenByMask(1 << token1);

        tokenTestSuite.mint(collateral, USER, type(uint96).max);

        tokenTestSuite.approve(collateral, USER, address(creditManager));

        uint256 lt = creditManager.liquidationThresholds(collateral);

        uint256 twvUSD = cft.priceOracle().convertToUSD(amount * lt, collateral)
            + cft.priceOracle().convertToUSD(DAI_ACCOUNT_AMOUNT * DEFAULT_UNDERLYING_LT, underlying);

        uint256 borrowedAmountUSD = cft.priceOracle().convertToUSD(DAI_ACCOUNT_AMOUNT * PERCENTAGE_FACTOR, underlying);

        console.log("T:", twvUSD);
        console.log("T:", borrowedAmountUSD);

        bool shouldRevert = twvUSD < borrowedAmountUSD;

        if (shouldRevert) {
            vm.expectRevert(NotEnoughCollateralException.selector);
        }

        vm.prank(USER);
        creditFacade.openCreditAccount(
            DAI_ACCOUNT_AMOUNT,
            USER,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (collateral, amount))
                })
            ),
            REFERRAL_CODE
        );
    }

    /// @dev I:[FA-10]: decrease debt during openCreditAccount
    function test_I_FA_10_decrease_debt_forbidden_during_openCreditAccount() public {
        vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, DECREASE_DEBT_PERMISSION));

        vm.prank(USER);

        creditFacade.openCreditAccount(
            DAI_ACCOUNT_AMOUNT,
            USER,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.decreaseDebt, 812)
                })
            ),
            REFERRAL_CODE
        );
    }

    /// @dev I:[FA-11A]: openCreditAccount reverts if met borrowed limit per block
    function test_I_FA_11A_openCreditAccount_reverts_if_met_borrowed_limit_per_block() public {
        (uint128 _minDebt, uint128 _maxDebt) = creditFacade.debtLimits();

        tokenTestSuite.mint(Tokens.DAI, address(cft.poolMock()), _maxDebt * 2);

        tokenTestSuite.mint(Tokens.DAI, USER, DAI_ACCOUNT_AMOUNT);
        tokenTestSuite.mint(Tokens.DAI, FRIEND, DAI_ACCOUNT_AMOUNT);

        tokenTestSuite.approve(Tokens.DAI, USER, address(creditManager));
        tokenTestSuite.approve(Tokens.DAI, FRIEND, address(creditManager));

        vm.roll(2);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxDebtPerBlockMultiplier(1);

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT))
            })
        );

        vm.prank(FRIEND);
        creditFacade.openCreditAccount(_maxDebt - _minDebt, FRIEND, calls, 0);

        vm.expectRevert(BorrowedBlockLimitException.selector);

        vm.prank(USER);
        creditFacade.openCreditAccount(_minDebt + 1, USER, calls, 0);
    }

    /// @dev I:[FA-11B]: openCreditAccount reverts if amount < minAmount or amount > maxAmount
    function test_I_FA_11B_openCreditAccount_reverts_if_amount_less_minBorrowedAmount_or_bigger_than_maxBorrowedAmount()
        public
    {
        (uint128 minBorrowedAmount, uint128 maxBorrowedAmount) = creditFacade.debtLimits();

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
            })
        );

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        vm.prank(USER);
        creditFacade.openCreditAccount(minBorrowedAmount - 1, USER, calls, 0);

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        vm.prank(USER);
        creditFacade.openCreditAccount(maxBorrowedAmount + 1, USER, calls, 0);
    }

    //
    // CLOSE CREDIT ACCOUNT
    //

    /// @dev I:[FA-12]: closeCreditAccount runs multicall operations in correct order
    function test_I_FA_12_closeCreditAccount_runs_operations_in_correct_order() public {
        (address creditAccount, uint256 balance) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        address bot = address(new GeneralMock());

        vm.prank(USER);
        creditFacade.setBotPermissions({
            creditAccount: creditAccount,
            bot: bot,
            permissions: uint192(ADD_COLLATERAL_PERMISSION),
            fundingAmount: 0,
            weeklyFundingAllowance: 0
        });

        // LIST OF EXPECTED CALLS

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (creditAccount)));

        vm.expectEmit(true, false, false, false);
        emit StartMultiCall(creditAccount);

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.execute, (DUMB_CALLDATA)));

        vm.expectEmit(true, false, false, true);
        emit Execute(address(targetMock));

        vm.expectCall(creditAccount, abi.encodeCall(ICreditAccountBase.execute, (address(targetMock), DUMB_CALLDATA)));

        vm.expectCall(address(targetMock), DUMB_CALLDATA);

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (address(1))));

        vm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        vm.expectCall(address(botList), abi.encodeCall(BotList.eraseAllBotPermissions, (creditAccount)));

        // todo: add withdrawal manager call

        // vm.expectCall(
        //     address(creditManager),
        //     abi.encodeCall(
        //         ICreditManagerV3.closeCreditAccount,
        //         (creditAccount, ClosureAction.CLOSE_ACCOUNT, 0, USER, FRIEND, 1, 10, DAI_ACCOUNT_AMOUNT, true)
        //     )
        // );

        vm.expectEmit(true, true, false, false);
        emit CloseCreditAccount(creditAccount, USER, FRIEND);

        // increase block number, cause it's forbidden to close ca in the same block
        vm.roll(block.number + 1);

        vm.prank(USER);
        creditFacade.closeCreditAccount(creditAccount, FRIEND, 10, true, calls);

        assertEq0(targetMock.callData(), DUMB_CALLDATA, "Incorrect calldata");
    }

    /// @dev I:[FA-13]: closeCreditAccount reverts on internal calls in multicall
    function test_I_FA_13_closeCreditAccount_reverts_on_internal_call_in_multicall_on_closure() public {
        /// TODO: CHANGE TEST
        // bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");

        // _openTestCreditAccount();

        // vm.roll(block.number + 1);

        // vm.expectRevert(ForbiddenDuringClosureException.selector);

        // // It's used dumb calldata, cause all calls to creditFacade are forbidden

        // vm.prank(USER);
        // creditFacade.closeCreditAccount(
        //     FRIEND, 0, true, MultiCallBuilder.build(MultiCall({target: address(creditFacade), callData: DUMB_CALLDATA}))
        // );
    }

    //
    // LIQUIDATE CREDIT ACCOUNT
    //

    /// @dev I:[FA-14]: liquidateCreditAccount reverts if hf > 1
    function test_I_FA_14_liquidateCreditAccount_reverts_if_hf_is_greater_than_1() public {
        (address creditAccount,) = _openTestCreditAccount();

        vm.expectRevert(CreditAccountNotLiquidatableException.selector);

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, LIQUIDATOR, 0, true, MultiCallBuilder.build());
    }

    /// @dev I:[FA-15]: liquidateCreditAccount executes needed calls and emits events
    function test_I_FA_15_liquidateCreditAccount_executes_needed_calls_and_emits_events() public {
        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        vm.prank(USER);
        creditFacade.setBotPermissions({
            creditAccount: creditAccount,
            bot: address(adapterMock),
            permissions: uint192(ADD_COLLATERAL_PERMISSION),
            fundingAmount: 0,
            weeklyFundingAllowance: 0
        });

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        _makeAccountsLiquitable();

        // EXPECTED STACK TRACE & EVENTS

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (creditAccount)));

        vm.expectEmit(true, false, false, false);
        emit StartMultiCall(creditAccount);

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.execute, (DUMB_CALLDATA)));

        vm.expectEmit(true, false, false, false);
        emit Execute(address(targetMock));

        vm.expectCall(creditAccount, abi.encodeCall(ICreditAccountBase.execute, (address(targetMock), DUMB_CALLDATA)));

        vm.expectCall(address(targetMock), DUMB_CALLDATA);

        vm.expectEmit(false, false, false, false);
        emit FinishMultiCall();

        vm.expectCall(address(botList), abi.encodeCall(BotList.eraseAllBotPermissions, (creditAccount)));

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (address(1))));

        // Total value = 2 * DAI_ACCOUNT_AMOUNT, cause we have x2 leverage
        uint256 totalValue = 2 * DAI_ACCOUNT_AMOUNT;
        uint256 debtWithInterest = DAI_ACCOUNT_AMOUNT;

        // vm.expectCall(
        //     address(creditManager),
        //     abi.encodeCall(
        //         ICreditManagerV3.closeCreditAccount,
        //         (
        //             creditAccount,
        //             ClosureAction.LIQUIDATE_ACCOUNT,
        //             totalValue,
        //             LIQUIDATOR,
        //             FRIEND,
        //             1,
        //             10,
        //             debtWithInterest,
        //             true
        //         )
        //     )
        // );

        vm.expectEmit(true, true, true, true);
        emit LiquidateCreditAccount(creditAccount, USER, LIQUIDATOR, FRIEND, ClosureAction.LIQUIDATE_ACCOUNT, 0);

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 10, true, calls);
    }

    /// @dev I:[FA-15A]: Borrowing is prohibited after a liquidation with loss
    function test_I_FA_15A_liquidateCreditAccount_prohibits_borrowing_on_loss() public {
        (address creditAccount,) = _openTestCreditAccount();

        uint8 maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();

        assertGt(maxDebtPerBlockMultiplier, 0, "SETUP: Increase debt is already enabled");

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        _makeAccountsLiquitable();

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 10, true, calls);

        maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();

        assertEq(maxDebtPerBlockMultiplier, 0, "Increase debt wasn't forbidden after loss");
    }

    /// @dev I:[FA-15B]: CreditFacade is paused after too much cumulative loss from liquidations
    function test_I_FA_15B_liquidateCreditAccount_pauses_CreditFacade_on_too_much_loss() public {
        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxCumulativeLoss(1);

        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        _makeAccountsLiquitable();

        vm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 10, true, calls);

        assertTrue(creditFacade.paused(), "Credit manager was not paused");
    }

    function test_I_FA_16_liquidateCreditAccount_reverts_on_internal_call_in_multicall_on_closure() public {
        /// TODO: Add all cases with different permissions!

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
            })
        );

        (address creditAccount,) = _openTestCreditAccount();

        _makeAccountsLiquitable();
        vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, ADD_COLLATERAL_PERMISSION));

        vm.prank(LIQUIDATOR);

        // It's used dumb calldata, cause all calls to creditFacade are forbidden
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 10, true, calls);
    }

    //
    // INCREASE & DECREASE DEBT
    //

    /// @dev I:[FA-17]: increaseDebt executes function as expected
    function test_I_FA_17_increaseDebt_executes_actions_as_expected() public {
        (address creditAccount,) = _openTestCreditAccount();

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.manageDebt, (creditAccount, 512, 1, ManageDebtAction.INCREASE_DEBT))
        );

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 1, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        vm.expectEmit(true, false, false, true);
        emit IncreaseDebt(creditAccount, 512);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, (512))
                })
            )
        );
    }

    /// @dev I:[FA-18A]: increaseDebt revets if more than block limit
    function test_I_FA_18A_increaseDebt_revets_if_more_than_block_limit() public {
        (address creditAccount,) = _openTestCreditAccount();

        uint8 maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();
        (, uint128 maxDebt) = creditFacade.debtLimits();

        vm.expectRevert(BorrowedBlockLimitException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, (maxDebt * maxDebtPerBlockMultiplier + 1))
                })
            )
        );
    }

    /// @dev I:[FA-18B]: increaseDebt revets if more than maxBorrowedAmount
    function test_I_FA_18B_increaseDebt_revets_if_more_than_block_limit() public {
        (address creditAccount,) = _openTestCreditAccount();

        (, uint128 maxBorrowedAmount) = creditFacade.debtLimits();

        uint256 amount = maxBorrowedAmount - DAI_ACCOUNT_AMOUNT + 1;

        tokenTestSuite.mint(Tokens.DAI, address(cft.poolMock()), amount);

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, (amount))
                })
            )
        );
    }

    /// @dev I:[FA-18C]: increaseDebt revets isIncreaseDebtForbidden is enabled
    function test_I_FA_18C_increaseDebt_revets_isIncreaseDebtForbidden_is_enabled() public {
        (address creditAccount,) = _openTestCreditAccount();

        vm.prank(CONFIGURATOR);
        creditConfigurator.forbidBorrowing();

        vm.expectRevert(BorrowedBlockLimitException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, (1))
                })
            )
        );
    }

    /// @dev I:[FA-18D]: increaseDebt reverts if there is a forbidden token on account
    function test_I_FA_18D_increaseDebt_reverts_with_forbidden_tokens() public {
        (address creditAccount,) = _openTestCreditAccount();

        address link = tokenTestSuite.addressOf(Tokens.LINK);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.enableToken, (link))
                })
            )
        );

        vm.prank(CONFIGURATOR);
        creditConfigurator.forbidToken(link);

        vm.expectRevert(ForbiddenTokensException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, (1))
                })
            )
        );
    }

    /// @dev I:[FA-19]: decreaseDebt executes function as expected
    function test_I_FA_19_decreaseDebt_executes_actions_as_expected() public {
        (address creditAccount,) = _openTestCreditAccount();

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.manageDebt, (creditAccount, 512, 1, ManageDebtAction.DECREASE_DEBT))
        );

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 1, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        vm.expectEmit(true, false, false, true);
        emit DecreaseDebt(creditAccount, 512);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.decreaseDebt, (512))
                })
            )
        );
    }

    /// @dev I:[FA-20]:decreaseDebt revets if less than minBorrowedAmount
    function test_I_FA_20_decreaseDebt_revets_if_less_than_minBorrowedAmount() public {
        (address creditAccount,) = _openTestCreditAccount();

        (uint128 minBorrowedAmount,) = creditFacade.debtLimits();

        uint256 amount = DAI_ACCOUNT_AMOUNT - minBorrowedAmount + 1;

        tokenTestSuite.mint(Tokens.DAI, address(cft.poolMock()), amount);

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.decreaseDebt, (amount))
                })
            )
        );
    }

    //
    // ADD COLLATERAL
    //

    /// @dev I:[FA-21]: addCollateral executes function as expected
    function test_I_FA_21_addCollateral_executes_actions_as_expected() public {
        (address creditAccount,) = _openTestCreditAccount();

        expectTokenIsEnabled(creditAccount, Tokens.USDC, false);

        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);

        tokenTestSuite.mint(Tokens.USDC, USER, 512);
        tokenTestSuite.approve(Tokens.USDC, USER, address(creditManager));

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.addCollateral, (USER, creditAccount, usdcToken, 512))
        );

        vm.expectEmit(true, true, false, true);
        emit AddCollateral(creditAccount, usdcToken, 512);

        // TODO: change test

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (usdcToken, 512))
            })
        );

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        expectBalance(Tokens.USDC, creditAccount, 512);
        expectTokenIsEnabled(creditAccount, Tokens.USDC, true);
    }

    /// @dev I:[FA-21C]: addCollateral calls checkEnabledTokensLength
    function test_I_FA_21C_addCollateral_optimizes_enabled_tokens() public {
        (address creditAccount,) = _openTestCreditAccount();

        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);

        tokenTestSuite.mint(Tokens.USDC, FRIEND, 512);
        tokenTestSuite.approve(Tokens.USDC, FRIEND, address(creditManager));

        // vm.expectCall(
        //     address(creditManager),
        //     abi.encodeCall(ICreditManagerV3.checkEnabledTokensLength.selector, creditAccount)
        // );

        // vm.prank(FRIEND);
        // creditFacade.addCollateral(USER, usdcToken, 512);
    }

    //
    // MULTICALL
    //

    /// @dev I:[FA-23]: multicall reverts for unknown methods
    function test_I_FA_23_multicall_reverts_for_unknown_methods() public {
        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");

        vm.expectRevert(UnknownMethodException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount, MultiCallBuilder.build(MultiCall({target: address(creditFacade), callData: DUMB_CALLDATA}))
        );
    }

    /// @dev I:[FA-24]: multicall reverts for creditManager address
    function test_I_FA_24_multicall_reverts_for_creditManager_address() public {
        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");

        vm.expectRevert(TargetContractNotAllowedException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount, MultiCallBuilder.build(MultiCall({target: address(creditManager), callData: DUMB_CALLDATA}))
        );
    }

    /// @dev I:[FA-25]: multicall reverts on non-adapter targets
    function test_I_FA_25_multicall_reverts_for_non_adapters() public {
        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");
        vm.expectRevert(TargetContractNotAllowedException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount, MultiCallBuilder.build(MultiCall({target: DUMB_ADDRESS, callData: DUMB_CALLDATA}))
        );
    }

    /// @dev I:[FA-26]: multicall addCollateral and oncreaseDebt works with creditFacade calls as expected
    function test_I_FA_26_multicall_addCollateral_and_increase_debt_works_with_creditFacade_calls_as_expected()
        public
    {
        (address creditAccount,) = _openTestCreditAccount();

        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
        tokenTestSuite.mint(Tokens.USDC, USER, USDC_EXCHANGE_AMOUNT);
        tokenTestSuite.approve(Tokens.USDC, USER, address(creditManager));

        uint256 usdcMask = creditManager.getTokenMaskOrRevert(usdcToken);

        vm.expectEmit(true, true, false, true);
        emit StartMultiCall(creditAccount);

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.addCollateral, (USER, creditAccount, usdcToken, USDC_EXCHANGE_AMOUNT))
        );

        vm.expectEmit(true, true, false, true);
        emit AddCollateral(creditAccount, usdcToken, USDC_EXCHANGE_AMOUNT);

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.manageDebt, (creditAccount, 256, usdcMask | 1, ManageDebtAction.INCREASE_DEBT)
            )
        );

        vm.expectEmit(true, false, false, true);
        emit IncreaseDebt(creditAccount, 256);

        vm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 3, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (usdcToken, USDC_EXCHANGE_AMOUNT))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, (256))
                })
            )
        );
    }

    /// @dev I:[FA-27]: multicall addCollateral and decreaseDebt works with creditFacade calls as expected
    function test_I_FA_27_multicall_addCollateral_and_decreaseDebt_works_with_creditFacade_calls_as_expected() public {
        (address creditAccount,) = _openTestCreditAccount();

        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
        tokenTestSuite.mint(Tokens.USDC, USER, USDC_EXCHANGE_AMOUNT);
        tokenTestSuite.approve(Tokens.USDC, USER, address(creditManager));

        uint256 usdcMask = creditManager.getTokenMaskOrRevert(usdcToken);

        vm.expectEmit(true, true, false, true);
        emit StartMultiCall(creditAccount);

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.addCollateral, (USER, creditAccount, usdcToken, USDC_EXCHANGE_AMOUNT))
        );

        vm.expectEmit(true, true, false, true);
        emit AddCollateral(creditAccount, usdcToken, USDC_EXCHANGE_AMOUNT);

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.manageDebt, (creditAccount, 256, usdcMask | 1, ManageDebtAction.DECREASE_DEBT)
            )
        );

        vm.expectEmit(true, false, false, true);
        emit DecreaseDebt(creditAccount, 256);

        vm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 3, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (usdcToken, USDC_EXCHANGE_AMOUNT))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.decreaseDebt, 256)
                })
            )
        );
    }

    /// @dev I:[FA-28]: multicall reverts for decrease opeartion after increase one
    function test_I_FA_28_multicall_reverts_for_decrease_opeartion_after_increase_one() public {
        (address creditAccount,) = _openTestCreditAccount();

        vm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, DECREASE_DEBT_PERMISSION));

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, 256)
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.decreaseDebt, 256)
                })
            )
        );
    }

    /// @dev I:[FA-29]: multicall works with adapters calls as expected
    function test_I_FA_29_multicall_works_with_adapters_calls_as_expected() public {
        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        // TODO: add enable / disable cases

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (creditAccount)));

        vm.expectEmit(true, true, false, true);
        emit StartMultiCall(creditAccount);

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.execute, (DUMB_CALLDATA)));

        vm.expectEmit(true, false, false, true);
        emit Execute(address(targetMock));

        vm.expectCall(creditAccount, abi.encodeCall(ICreditAccountBase.execute, (address(targetMock), DUMB_CALLDATA)));

        vm.expectCall(address(targetMock), DUMB_CALLDATA);

        vm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (address(1))));

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 1, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);
    }

    /// @dev I:[FA-36]: checkAndUpdateBorrowedBlockLimit doesn't change block limit if maxBorrowedAmountPerBlock = type(uint128).max
    function test_I_FA_36_checkAndUpdateBorrowedBlockLimit_doesnt_change_block_limit_if_set_to_max() public {
        // vm.prank(CONFIGURATOR);
        // creditConfigurator.setMaxDebtLimitPerBlock(type(uint128).max);

        // (uint64 blockLastUpdate, uint128 borrowedInBlock) = creditFacade.getTotalBorrowedInBlock();
        // assertEq(blockLastUpdate, 0, "Incorrect currentBlockLimit");
        // assertEq(borrowedInBlock, 0, "Incorrect currentBlockLimit");

        // _openTestCreditAccount();

        // (blockLastUpdate, borrowedInBlock) = creditFacade.getTotalBorrowedInBlock();
        // assertEq(blockLastUpdate, 0, "Incorrect currentBlockLimit");
        // assertEq(borrowedInBlock, 0, "Incorrect currentBlockLimit");
    }

    /// @dev I:[FA-37]: checkAndUpdateBorrowedBlockLimit doesn't change block limit if maxBorrowedAmountPerBlock = type(uint128).max
    function test_I_FA_37_checkAndUpdateBorrowedBlockLimit_updates_block_limit_properly() public {
        // (uint64 blockLastUpdate, uint128 borrowedInBlock) = creditFacade.getTotalBorrowedInBlock();

        // assertEq(blockLastUpdate, 0, "Incorrect blockLastUpdate");
        // assertEq(borrowedInBlock, 0, "Incorrect borrowedInBlock");

        // _openTestCreditAccount();

        // (blockLastUpdate, borrowedInBlock) = creditFacade.getTotalBorrowedInBlock();

        // assertEq(blockLastUpdate, block.number, "blockLastUpdate");
        // assertEq(borrowedInBlock, DAI_ACCOUNT_AMOUNT, "Incorrect borrowedInBlock");

        // vm.prank(USER);
        // creditFacade.multicall(
        //     MultiCallBuilder.build(
        //         MultiCall({
        //             target: address(creditFacade),
        //             callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, (DAI_EXCHANGE_AMOUNT))
        //         })
        //     )
        // );

        // (blockLastUpdate, borrowedInBlock) = creditFacade.getTotalBorrowedInBlock();

        // assertEq(blockLastUpdate, block.number, "blockLastUpdate");
        // assertEq(borrowedInBlock, DAI_ACCOUNT_AMOUNT + DAI_EXCHANGE_AMOUNT, "Incorrect borrowedInBlock");

        // // switch to new block
        // vm.roll(block.number + 1);

        // vm.prank(USER);
        // creditFacade.multicall(
        //     MultiCallBuilder.build(
        //         MultiCall({
        //             target: address(creditFacade),
        //             callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, (DAI_EXCHANGE_AMOUNT))
        //         })
        //     )
        // );

        // (blockLastUpdate, borrowedInBlock) = creditFacade.getTotalBorrowedInBlock();

        // assertEq(blockLastUpdate, block.number, "blockLastUpdate");
        // assertEq(borrowedInBlock, DAI_EXCHANGE_AMOUNT, "Incorrect borrowedInBlock");
    }

    //
    // ENABLE TOKEN
    //

    /// @dev I:[FA-39]: enable token works as expected
    function test_I_FA_39_enable_token_is_correct() public {
        (address creditAccount,) = _openTestCreditAccount();

        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
        expectTokenIsEnabled(creditAccount, Tokens.USDC, false);

        tokenTestSuite.mint(Tokens.USDC, creditAccount, 100);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.enableToken, (usdcToken))
                })
            )
        );

        expectTokenIsEnabled(creditAccount, Tokens.USDC, true);
    }

    //
    // GETTERS
    //

    /// @dev I:[FA-41]: calcTotalValue computes correctly
    function test_I_FA_41_calcTotalValue_computes_correctly() public {
        (address creditAccount,) = _openTestCreditAccount();

        // AFTER OPENING CREDIT ACCOUNT
        uint256 expectedTV = DAI_ACCOUNT_AMOUNT * 2;
        uint256 expectedTWV = (DAI_ACCOUNT_AMOUNT * 2 * DEFAULT_UNDERLYING_LT) / PERCENTAGE_FACTOR;

        // (uint256 tv, uint256 tvw) = creditFacade.calcTotalValue(creditAccount);

        // assertEq(tv, expectedTV, "Incorrect total value for 1 asset");

        // assertEq(tvw, expectedTWV, "Incorrect Threshold weighthed value for 1 asset");

        // ADDS USDC BUT NOT ENABLES IT
        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
        tokenTestSuite.mint(Tokens.USDC, creditAccount, 10 * 10 ** 6);

        // (tv, tvw) = creditFacade.calcTotalValue(creditAccount);

        // // tv and tvw shoul be the same until we deliberately enable USDC token
        // assertEq(tv, expectedTV, "Incorrect total value for 1 asset");

        // assertEq(tvw, expectedTWV, "Incorrect Threshold weighthed value for 1 asset");

        // ENABLES USDC

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.enableToken, (usdcToken))
                })
            )
        );

        expectedTV += 10 * WAD;
        expectedTWV += (10 * WAD * 9000) / PERCENTAGE_FACTOR;

        // (tv, tvw) = creditFacade.calcTotalValue(creditAccount);

        // assertEq(tv, expectedTV, "Incorrect total value for 2 asset");

        // assertEq(tvw, expectedTWV, "Incorrect Threshold weighthed value for 2 asset");

        // 3 ASSET TEST: 10 DAI + 10 USDC + 0.01 WETH (3200 $/ETH)
        addCollateral(Tokens.WETH, WAD / 100);

        expectedTV += (WAD / 100) * DAI_WETH_RATE;
        expectedTWV += ((WAD / 100) * DAI_WETH_RATE * 8300) / PERCENTAGE_FACTOR;

        // (tv, tvw) = creditFacade.calcTotalValue(creditAccount);

        // assertEq(tv, expectedTV, "Incorrect total value for 3 asset");

        // assertEq(tvw, expectedTWV, "Incorrect Threshold weighthed value for 3 asset");
    }

    /// @dev I:[FA-42]: calcCreditAccountHealthFactor computes correctly
    function test_I_FA_42_calcCreditAccountHealthFactor_computes_correctly() public {
        (address creditAccount,) = _openTestCreditAccount();

        // AFTER OPENING CREDIT ACCOUNT

        uint256 expectedTV = DAI_ACCOUNT_AMOUNT * 2;
        uint256 expectedTWV = (DAI_ACCOUNT_AMOUNT * 2 * DEFAULT_UNDERLYING_LT) / PERCENTAGE_FACTOR;

        uint256 expectedHF = (expectedTWV * PERCENTAGE_FACTOR) / DAI_ACCOUNT_AMOUNT;

        // assertEq(creditFacade.calcCreditAccountHealthFactor(creditAccount), expectedHF, "Incorrect health factor");

        // ADDING USDC AS COLLATERAL

        addCollateral(Tokens.USDC, 10 * 10 ** 6);

        expectedTV += 10 * WAD;
        expectedTWV += (10 * WAD * 9000) / PERCENTAGE_FACTOR;

        expectedHF = (expectedTWV * PERCENTAGE_FACTOR) / DAI_ACCOUNT_AMOUNT;

        // assertEq(creditFacade.calcCreditAccountHealthFactor(creditAccount), expectedHF, "Incorrect health factor");

        // 3 ASSET: 10 DAI + 10 USDC + 0.01 WETH (3200 $/ETH)
        addCollateral(Tokens.WETH, WAD / 100);

        expectedTV += (WAD / 100) * DAI_WETH_RATE;
        expectedTWV += ((WAD / 100) * DAI_WETH_RATE * 8300) / PERCENTAGE_FACTOR;

        expectedHF = (expectedTWV * PERCENTAGE_FACTOR) / DAI_ACCOUNT_AMOUNT;

        // assertEq(creditFacade.calcCreditAccountHealthFactor(creditAccount), expectedHF, "Incorrect health factor");
    }

    /// CHECK IS ACCOUNT LIQUIDATABLE

    /// @dev I:[FA-44]: setContractToAdapter reverts if called non-configurator
    function test_I_FA_44_config_functions_revert_if_called_non_configurator() public {
        vm.expectRevert(CallerNotConfiguratorException.selector);
        vm.prank(USER);
        creditFacade.setDebtLimits(100, 100, 100);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        vm.prank(USER);
        creditFacade.setBotList(FRIEND);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        vm.prank(USER);
        creditFacade.setEmergencyLiquidator(DUMB_ADDRESS, AllowanceAction.ALLOW);
    }

    /// CHECK SLIPPAGE PROTECTION

    /// [TODO]: add new test

    /// @dev I:[FA-45]: rrevertIfGetLessThan during multicalls works correctly
    function test_I_FA_45_revertIfGetLessThan_works_correctly() public {
        (address creditAccount,) = _openTestCreditAccount();

        uint256 expectedDAI = 1000;
        uint256 expectedLINK = 2000;

        address tokenLINK = tokenTestSuite.addressOf(Tokens.LINK);

        Balance[] memory expectedBalances = new Balance[](2);
        expectedBalances[0] = Balance({token: underlying, balance: expectedDAI, tokenMask: 0});

        expectedBalances[1] = Balance({token: tokenLINK, balance: expectedLINK, tokenMask: 0});

        // TOKEN PREPARATION
        tokenTestSuite.mint(Tokens.DAI, USER, expectedDAI * 3);
        tokenTestSuite.mint(Tokens.LINK, USER, expectedLINK * 3);

        tokenTestSuite.approve(Tokens.DAI, USER, address(creditManager));
        tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                CreditFacadeMulticaller(address(creditFacade)).revertIfReceivedLessThan(expectedBalances),
                CreditFacadeMulticaller(address(creditFacade)).addCollateral(underlying, expectedDAI),
                CreditFacadeMulticaller(address(creditFacade)).addCollateral(tokenLINK, expectedLINK)
            )
        );

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(USER);
            vm.expectRevert(
                abi.encodeWithSelector(
                    BalanceLessThanMinimumDesiredException.selector, ((i == 0) ? underlying : tokenLINK)
                )
            );

            creditFacade.multicall(
                creditAccount,
                MultiCallBuilder.build(
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeMulticall.revertIfReceivedLessThan, (expectedBalances))
                    }),
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(
                            ICreditFacadeMulticall.addCollateral, (underlying, (i == 0) ? expectedDAI - 1 : expectedDAI)
                            )
                    }),
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(
                            ICreditFacadeMulticall.addCollateral, (tokenLINK, (i == 0) ? expectedLINK : expectedLINK - 1)
                            )
                    })
                )
            );
        }
    }

    /// @dev I:[FA-45A]: rrevertIfGetLessThan everts if called twice
    function test_I_FA_45A_revertIfGetLessThan_reverts_if_called_twice() public {
        uint256 expectedDAI = 1000;

        Balance[] memory expectedBalances = new Balance[](1);
        expectedBalances[0] = Balance({token: underlying, balance: expectedDAI, tokenMask: 0});

        (address creditAccount,) = _openTestCreditAccount();
        vm.prank(USER);
        vm.expectRevert(ExpectedBalancesAlreadySetException.selector);

        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.revertIfReceivedLessThan, (expectedBalances))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.revertIfReceivedLessThan, (expectedBalances))
                })
            )
        );
    }

    /// CREDIT FACADE WITH EXPIRATION

    /// @dev I:[FA-46]: openCreditAccount and openCreditAccount no longer work if the CreditFacadeV3 is expired
    function test_I_FA_46_openCreditAccount_reverts_on_expired_CreditFacade() public {
        _setUp({
            _underlying: Tokens.DAI,
            withDegenNFT: false,
            withExpiration: true,
            supportQuotas: false,
            accountFactoryVer: 1
        });

        vm.warp(block.timestamp + 1);

        vm.expectRevert(NotAllowedAfterExpirationException.selector);

        vm.prank(USER);
        creditFacade.openCreditAccount(
            DAI_ACCOUNT_AMOUNT,
            USER,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            ),
            0
        );
    }

    /// @dev I:[FA-47]: liquidateExpiredCreditAccount should not work before the CreditFacadeV3 is expired
    function test_I_FA_47_liquidateExpiredCreditAccount_reverts_before_expiration() public {
        _setUp({
            _underlying: Tokens.DAI,
            withDegenNFT: false,
            withExpiration: true,
            supportQuotas: false,
            accountFactoryVer: 1
        });

        _openTestCreditAccount();

        // vm.expectRevert(CantLiquidateNonExpiredException.selector);

        // vm.prank(LIQUIDATOR);
        // creditFacade.liquidateExpiredCreditAccount(USER, LIQUIDATOR, 0, false, MultiCallBuilder.build());
    }

    /// @dev I:[FA-48]: liquidateExpiredCreditAccount should not work when expiration is set to zero (i.e. CreditFacadeV3 is non-expiring)
    function test_I_FA_48_liquidateExpiredCreditAccount_reverts_on_CreditFacade_with_no_expiration() public {
        _openTestCreditAccount();

        // vm.expectRevert(CantLiquidateNonExpiredException.selector);

        // vm.prank(LIQUIDATOR);
        // creditFacade.liquidateExpiredCreditAccount(USER, LIQUIDATOR, 0, false, MultiCallBuilder.build());
    }

    /// @dev I:[FA-49]: liquidateExpiredCreditAccount works correctly and emits events
    function test_I_FA_49_liquidateExpiredCreditAccount_works_correctly_after_expiration() public {
        _setUp({
            _underlying: Tokens.DAI,
            withDegenNFT: false,
            withExpiration: true,
            supportQuotas: false,
            accountFactoryVer: 1
        });
        (address creditAccount, uint256 balance) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // (uint256 borrowedAmount, uint256 borrowedAmountWithInterest,) =
        //     creditManager.calcAccruedInterestAndFees(creditAccount);

        // (, uint256 remainingFunds,,) = creditManager.calcClosePayments(
        //     balance, ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT, borrowedAmount, borrowedAmountWithInterest
        // );

        // // EXPECTED STACK TRACE & EVENTS

        // vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (creditAccount)));

        // vm.expectEmit(true, false, false, false);
        // emit StartMultiCall(creditAccount);

        // vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.execute, (DUMB_CALLDATA)));

        // vm.expectEmit(true, false, false, false);
        // emit Execute(address(targetMock));

        // vm.expectCall(creditAccount, abi.encodeCall(ICreditAccountBase.execute, (address(targetMock), DUMB_CALLDATA)));

        // vm.expectCall(address(targetMock), DUMB_CALLDATA);

        // vm.expectEmit(false, false, false, false);
        // emit FinishMultiCall();

        // vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (address(1))));
        // // Total value = 2 * DAI_ACCOUNT_AMOUNT, cause we have x2 leverage
        // uint256 totalValue = balance;

        // // vm.expectCall(
        // //     address(creditManager),
        // //     abi.encodeCall(
        // //         ICreditManagerV3.closeCreditAccount,
        // //         (
        // //             creditAccount,
        // //             ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT,
        // //             totalValue,
        // //             LIQUIDATOR,
        // //             FRIEND,
        // //             1,
        // //             10,
        // //             DAI_ACCOUNT_AMOUNT,
        // //             true
        // //         )
        // //     )
        // // );

        // vm.expectEmit(true, true, false, true);
        // emit LiquidateCreditAccount(
        //     creditAccount, USER, LIQUIDATOR, FRIEND, ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT, remainingFunds
        // );

        // vm.prank(LIQUIDATOR);
        // creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 10, true, calls);
    }

    ///
    /// ENABLE TOKEN
    ///

    /// @dev I:[FA-53]: enableToken works as expected in a multicall
    function test_I_FA_53_enableToken_works_as_expected_multicall() public {
        (address creditAccount,) = _openTestCreditAccount();

        address token = tokenTestSuite.addressOf(Tokens.USDC);

        // vm.expectCall(
        //     address(creditManager), abi.encodeCall(ICreditManagerV3.checkAndEnableToken.selector, token)
        // );

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.enableToken, (token))
                })
            )
        );

        expectTokenIsEnabled(creditAccount, Tokens.USDC, true);
    }

    /// @dev I:[FA-54]: disableToken works as expected in a multicall
    function test_I_FA_54_disableToken_works_as_expected_multicall() public {
        (address creditAccount,) = _openTestCreditAccount();

        address token = tokenTestSuite.addressOf(Tokens.USDC);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.enableToken, (token))
                })
            )
        );

        // vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.disableToken.selector, token));

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.disableToken, (token))
                })
            )
        );

        expectTokenIsEnabled(creditAccount, Tokens.USDC, false);
    }

    // /// @dev I:[FA-56]: liquidateCreditAccount correctly uses BlacklistHelper during liquidations
    // function test_I_FA_56_liquidateCreditAccount_correctly_handles_blacklisted_borrowers() public {
    //     _setUp(Tokens.USDC);

    //     cft.testFacadeWithBlacklistHelper();

    //     creditFacade = cft.creditFacade();

    //     address usdc = tokenTestSuite.addressOf(Tokens.USDC);

    //     address blacklistHelper = creditFacade.blacklistHelper();

    //     _openTestCreditAccount();

    //     uint256 expectedAmount = (
    //         2 * USDC_ACCOUNT_AMOUNT * (PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM - DEFAULT_FEE_LIQUIDATION)
    //     ) / PERCENTAGE_FACTOR - USDC_ACCOUNT_AMOUNT - 1 - 1; // second -1 because we add 1 to helper balance

    //     vm.roll(block.number + 1);

    //     vm.prank(address(creditConfigurator));
    //     CreditManagerV3(address(creditManager)).setLiquidationThreshold(usdc, 1);

    //     ERC20BlacklistableMock(usdc).setBlacklisted(USER, true);

    //     vm.expectCall(blacklistHelper, abi.encodeCall(IWithdrawalManager.isBlacklisted, (usdc, USER)));

    //     vm.expectCall(
    //         address(creditManager), abi.encodeCall(ICreditManagerV3.transferAccountOwnership, (USER, blacklistHelper))
    //     );

    //     vm.expectCall(blacklistHelper, abi.encodeCall(IWithdrawalManager.addWithdrawal, (usdc, USER, expectedAmount)));

    //     vm.expectEmit(true, false, false, true);
    //     emit UnderlyingSentToBlacklistHelper(USER, expectedAmount);

    //     vm.prank(LIQUIDATOR);
    //     creditFacade.liquidateCreditAccount(USER, FRIEND, 0, true, MultiCallBuilder.build());

    //     assertEq(IWithdrawalManager(blacklistHelper).claimable(usdc, USER), expectedAmount, "Incorrect claimable amount");

    //     vm.prank(USER);
    //     IWithdrawalManager(blacklistHelper).claim(usdc, FRIEND2);

    //     assertEq(tokenTestSuite.balanceOf(Tokens.USDC, FRIEND2), expectedAmount, "Transferred amount incorrect");
    // }

    // /// @dev I:[FA-57]: openCreditAccount reverts when the borrower is blacklisted on a blacklistable underlying
    // function test_I_FA_57_openCreditAccount_reverts_on_blacklisted_borrower() public {
    //     _setUp(Tokens.USDC);

    //     cft.testFacadeWithBlacklistHelper();

    //     creditFacade = cft.creditFacade();

    //     address usdc = tokenTestSuite.addressOf(Tokens.USDC);

    //     ERC20BlacklistableMock(usdc).setBlacklisted(USER, true);

    //     vm.expectRevert(NotAllowedForBlacklistedAddressException.selector);

    //     vm.prank(USER);
    //     creditFacade.openCreditAccount(
    //         USDC_ACCOUNT_AMOUNT,
    //         USER,
    //         MultiCallBuilder.build(
    //             MultiCall({
    //                 target: address(creditFacade),
    //                 callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
    //             })
    //         ),
    //         0
    //     );
    // }

    //
    // BOT LIST INTEGRATION
    //

    /// @dev I:[FA-58]: botMulticall works correctly
    function test_I_FA_58_botMulticall_works_correctly() public {
        (address creditAccount,) = _openTestCreditAccount();

        address bot = address(new GeneralMock());

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        vm.expectRevert(NotApprovedBotException.selector);
        creditFacade.botMulticall(
            creditAccount, MultiCallBuilder.build(MultiCall({target: address(adapterMock), callData: DUMB_CALLDATA}))
        );

        vm.prank(USER);
        creditFacade.setBotPermissions(creditAccount, bot, type(uint192).max, uint72(1 ether), uint72(1 ether / 10));

        botList.getBotStatus({bot: bot, creditAccount: creditAccount});

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        vm.expectEmit(true, true, false, true);
        emit StartMultiCall(creditAccount);

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (creditAccount)));

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.execute, (DUMB_CALLDATA)));

        vm.expectEmit(true, false, false, true);
        emit Execute(address(targetMock));

        vm.expectCall(creditAccount, abi.encodeCall(ICreditAccountBase.execute, (address(targetMock), DUMB_CALLDATA)));

        vm.expectCall(address(targetMock), DUMB_CALLDATA);

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setActiveCreditAccount, (address(1))));

        vm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 1, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        vm.prank(bot);
        creditFacade.botMulticall(creditAccount, calls);

        vm.prank(CONFIGURATOR);
        botList.setBotForbiddenStatus(bot, true);

        vm.expectRevert(NotApprovedBotException.selector);
        vm.prank(bot);
        creditFacade.botMulticall(creditAccount, calls);
    }

    /// @dev I:[FA-58A]: setBotPermissions works correctly in CF
    function test_I_FA_58A_setBotPermissions_works_correctly() public {
        (address creditAccount,) = _openTestCreditAccount();

        address bot = address(new GeneralMock());

        vm.expectRevert(CallerNotCreditAccountOwnerException.selector);
        vm.prank(FRIEND);
        creditFacade.setBotPermissions(creditAccount, bot, type(uint192).max, uint72(1 ether), uint72(1 ether / 10));

        vm.expectCall(address(botList), abi.encodeCall(BotList.eraseAllBotPermissions, (creditAccount)));

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(CreditManagerV3.setFlagFor, (creditAccount, BOT_PERMISSIONS_SET_FLAG, true))
        );

        vm.prank(USER);
        creditFacade.setBotPermissions(creditAccount, bot, type(uint192).max, uint72(1 ether), uint72(1 ether / 10));

        assertTrue(creditManager.flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG > 0, "Flag was not set");

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(CreditManagerV3.setFlagFor, (creditAccount, BOT_PERMISSIONS_SET_FLAG, false))
        );

        vm.prank(USER);
        creditFacade.setBotPermissions(creditAccount, bot, 0, 0, 0);

        assertTrue(creditManager.flagsOf(creditAccount) & BOT_PERMISSIONS_SET_FLAG == 0, "Flag was not set");
    }

    //
    // FULL CHECK PARAMS
    //

    /// @dev I:[FA-59]: setFullCheckParams performs correct full check after multicall
    function test_I_FA_59_setFullCheckParams_correctly_passes_params_to_fullCollateralCheck() public {
        (address creditAccount,) = _openTestCreditAccount();

        uint256[] memory collateralHints = new uint256[](1);
        collateralHints[0] = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDC));

        uint256 enabledTokensMap = creditManager.enabledTokensMaskOf(creditAccount);

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, enabledTokensMap, collateralHints, 10001)
            )
        );

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.setFullCheckParams, (collateralHints, 10001))
                })
            )
        );
    }

    //
    // EMERGENCY LIQUIDATIONS
    //

    /// @dev I:[FA-62]: addEmergencyLiquidator correctly sets value
    function test_I_FA_62_setEmergencyLiquidator_works_correctly() public {
        vm.prank(address(creditConfigurator));
        creditFacade.setEmergencyLiquidator(DUMB_ADDRESS, AllowanceAction.ALLOW);

        assertTrue(creditFacade.canLiquidateWhilePaused(DUMB_ADDRESS), "Value was not set");

        vm.prank(address(creditConfigurator));
        creditFacade.setEmergencyLiquidator(DUMB_ADDRESS, AllowanceAction.FORBID);

        assertTrue(!creditFacade.canLiquidateWhilePaused(DUMB_ADDRESS), "Value was is still set");
    }
}
