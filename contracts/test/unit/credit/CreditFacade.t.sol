// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";

import {CreditFacadeV3} from "../../../credit/CreditFacadeV3.sol";
import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";

import {CreditAccount} from "@gearbox-protocol/core-v2/contracts/credit/CreditAccount.sol";
import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";

import {BotList} from "../../../support/BotList.sol";

import "../../../interfaces/ICreditFacade.sol";
import {
    ICreditManagerV3,
    ICreditManagerV3Events,
    ClosureAction,
    ManageDebtAction
} from "../../../interfaces/ICreditManagerV3.sol";
import {AllowanceAction} from "../../../interfaces/ICreditConfiguratorV3.sol";
import {ICreditFacadeEvents} from "../../../interfaces/ICreditFacade.sol";
import {IDegenNFT, IDegenNFTExceptions} from "@gearbox-protocol/core-v2/contracts/interfaces/IDegenNFT.sol";
import {IWithdrawManager} from "../../../interfaces/IWithdrawManager.sol";

// DATA
import {MultiCall, MultiCallOps} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {Balance} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";

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
import {AdapterMock} from "../../mocks/adapters/AdapterMock.sol";
import {TargetContractMock} from "@gearbox-protocol/core-v2/contracts/test/mocks/adapters/TargetContractMock.sol";
import {ERC20BlacklistableMock} from "../../mocks/token/ERC20Blacklistable.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";
import {CreditFacadeTestSuite} from "../../suites/CreditFacadeTestSuite.sol";
import {CreditConfig} from "../../config/CreditConfig.sol";

import "forge-std/console.sol";

uint256 constant WETH_TEST_AMOUNT = 5 * WAD;
uint16 constant REFERRAL_CODE = 23;

/// @title CreditFacadeTest
/// @notice Designed for unit test purposes only
contract CreditFacadeTest is
    DSTest,
    BalanceHelper,
    CreditFacadeTestHelper,
    ICreditManagerV3Events,
    ICreditFacadeEvents
{
    using CreditFacadeCalls for CreditFacadeMulticaller;

    AccountFactory accountFactory;

    TargetContractMock targetMock;
    AdapterMock adapterMock;

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

        targetMock = new TargetContractMock();
        adapterMock = new AdapterMock(
            address(creditManager),
            address(targetMock)
        );

        evm.prank(CONFIGURATOR);
        creditConfigurator.allowContract(address(targetMock), address(adapterMock));

        evm.label(address(adapterMock), "AdapterMock");
        evm.label(address(targetMock), "TargetContractMock");
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

        evm.startPrank(tester);
        if (tester.balance > 0) {
            IWETH(weth).deposit{value: tester.balance}();
        }

        IERC20(weth).transfer(address(this), tokenTestSuite.balanceOf(Tokens.WETH, tester));

        evm.stopPrank();
        expectBalance(Tokens.WETH, tester, 0);

        evm.deal(tester, WETH_TEST_AMOUNT);
    }

    function _checkForWETHTest() internal {
        _checkForWETHTest(USER);
    }

    function _checkForWETHTest(address tester) internal {
        expectBalance(Tokens.WETH, tester, WETH_TEST_AMOUNT);

        expectEthBalance(tester, 0);
    }

    function _prepareMockCall() internal returns (bytes memory callData) {
        evm.prank(CONFIGURATOR);
        creditConfigurator.allowContract(address(targetMock), address(adapterMock));

        callData = abi.encodeWithSignature("hello(string)", "world");
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    // TODO: ideas how to revert with ZA?

    // /// @dev [FA-1]: constructor reverts for zero address
    // function test_FA_01_constructor_reverts_for_zero_address() public {
    //     evm.expectRevert(ZeroAddressException.selector);
    //     new CreditFacadeV3(address(0), address(0), address(0), false);
    // }

    /// @dev [FA-1A]: constructor sets correct values
    function test_FA_01A_constructor_sets_correct_values() public {
        assertEq(address(creditFacade.creditManager()), address(creditManager), "Incorrect creditManager");
        assertEq(creditFacade.underlying(), underlying, "Incorrect underlying token");

        assertEq(creditFacade.wethAddress(), creditManager.wethAddress(), "Incorrect wethAddress token");

        assertEq(creditFacade.degenNFT(), address(0), "Incorrect degenNFT");

        assertTrue(creditFacade.whitelisted() == false, "Incorrect whitelisted");

        _setUp({
            _underlying: Tokens.DAI,
            withDegenNFT: true,
            withExpiration: false,
            supportQuotas: false,
            accountFactoryVer: 1
        });
        creditFacade = cft.creditFacade();

        assertEq(creditFacade.degenNFT(), address(cft.degenNFT()), "Incorrect degenNFT");

        assertTrue(creditFacade.whitelisted() == true, "Incorrect whitelisted");
    }

    //
    // ALL FUNCTIONS REVERTS IF USER HAS NO ACCOUNT
    //

    /// @dev [FA-2]: functions reverts if borrower has no account
    function test_FA_02_functions_reverts_if_borrower_has_no_account() public {
        evm.expectRevert(CreditAccountNotExistsException.selector);
        evm.prank(USER);
        creditFacade.closeCreditAccount(DUMB_ADDRESS, FRIEND, 0, false, multicallBuilder());

        evm.expectRevert(CreditAccountNotExistsException.selector);
        evm.prank(USER);
        creditFacade.closeCreditAccount(
            DUMB_ADDRESS,
            FRIEND,
            0,
            false,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            )
        );

        evm.expectRevert(CreditAccountNotExistsException.selector);
        evm.prank(USER);
        creditFacade.liquidateCreditAccount(DUMB_ADDRESS, DUMB_ADDRESS, 0, false, multicallBuilder());

        evm.expectRevert(CreditAccountNotExistsException.selector);
        evm.prank(USER);
        creditFacade.multicall(
            DUMB_ADDRESS,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            )
        );

        // evm.prank(CONFIGURATOR);
        // creditConfigurator.allowContract(address(targetMock), address(adapterMock));

        evm.expectRevert(CreditAccountNotExistsException.selector);
        evm.prank(USER);
        creditFacade.transferAccountOwnership(DUMB_ADDRESS, FRIEND);
    }

    //
    // ETH => WETH TESTS
    //
    function test_FA_03B_openCreditAccountMulticall_correctly_wraps_ETH() public {
        /// - openCreditAccount

        _prepareForWETHTest();

        evm.prank(USER);
        creditFacade.openCreditAccount{value: WETH_TEST_AMOUNT}(
            DAI_ACCOUNT_AMOUNT,
            USER,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            ),
            0
        );
        _checkForWETHTest();
    }

    function test_FA_03C_closeCreditAccount_correctly_wraps_ETH() public {
        (address creditAccount,) = _openTestCreditAccount();

        evm.roll(block.number + 1);

        _prepareForWETHTest();
        evm.prank(USER);
        creditFacade.closeCreditAccount{value: WETH_TEST_AMOUNT}(creditAccount, USER, 0, false, multicallBuilder());
        _checkForWETHTest();
    }

    function test_FA_03D_liquidate_correctly_wraps_ETH() public {
        (address creditAccount,) = _openTestCreditAccount();

        evm.roll(block.number + 1);

        tokenTestSuite.burn(Tokens.DAI, creditAccount, tokenTestSuite.balanceOf(Tokens.DAI, creditAccount));

        _prepareForWETHTest(LIQUIDATOR);

        tokenTestSuite.approve(Tokens.DAI, LIQUIDATOR, address(creditManager));

        tokenTestSuite.mint(Tokens.DAI, LIQUIDATOR, DAI_ACCOUNT_AMOUNT);

        evm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount{value: WETH_TEST_AMOUNT}(
            creditAccount, LIQUIDATOR, 0, false, multicallBuilder()
        );
        _checkForWETHTest(LIQUIDATOR);
    }

    function test_FA_03F_multicall_correctly_wraps_ETH() public {
        (address creditAccount,) = _openTestCreditAccount();

        // MULTICALL
        _prepareForWETHTest();

        evm.prank(USER);
        creditFacade.multicall{value: WETH_TEST_AMOUNT}(
            creditAccount,
            multicallBuilder(
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

    /// @dev [FA-4A]: openCreditAccount reverts for using addresses which is not allowed by transfer allowance
    function test_FA_04A_openCreditAccount_reverts_for_using_addresses_which_is_not_allowed_by_transfer_allowance()
        public
    {
        (uint256 minBorrowedAmount,) = creditFacade.debtLimits();

        evm.startPrank(USER);

        MultiCall[] memory calls = multicallBuilder(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
            })
        );
        evm.expectRevert(AccountTransferNotAllowedException.selector);
        creditFacade.openCreditAccount(minBorrowedAmount, FRIEND, calls, 0);

        evm.stopPrank();
    }

    /// @dev [FA-4B]: openCreditAccount reverts if user has no NFT for degen mode
    function test_FA_04B_openCreditAccount_reverts_for_non_whitelisted_account() public {
        _setUp({
            _underlying: Tokens.DAI,
            withDegenNFT: true,
            withExpiration: false,
            supportQuotas: false,
            accountFactoryVer: 1
        });

        (uint256 minBorrowedAmount,) = creditFacade.debtLimits();

        evm.expectRevert(IDegenNFTExceptions.InsufficientBalanceException.selector);

        evm.prank(FRIEND);
        creditFacade.openCreditAccount(
            minBorrowedAmount,
            FRIEND,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            ),
            0
        );
    }

    /// @dev [FA-4C]: openCreditAccount opens account and burns token
    function test_FA_04C_openCreditAccount_burns_token_in_whitelisted_mode() public {
        _setUp({
            _underlying: Tokens.DAI,
            withDegenNFT: true,
            withExpiration: false,
            supportQuotas: false,
            accountFactoryVer: 1
        });

        IDegenNFT degenNFT = IDegenNFT(creditFacade.degenNFT());

        evm.prank(CONFIGURATOR);
        degenNFT.mint(USER, 2);

        expectBalance(address(degenNFT), USER, 2);

        (address creditAccount,) = _openTestCreditAccount();

        expectBalance(address(degenNFT), USER, 1);

        _closeTestCreditAccount(creditAccount);

        tokenTestSuite.mint(Tokens.DAI, USER, DAI_ACCOUNT_AMOUNT);

        evm.prank(USER);
        creditFacade.openCreditAccount(
            DAI_ACCOUNT_AMOUNT,
            USER,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT))
                })
            ),
            0
        );

        expectBalance(address(degenNFT), USER, 0);
    }

    // /// @dev [FA-5]: openCreditAccount sets correct values
    // function test_FA_05_openCreditAccount_sets_correct_values() public {
    //     uint16 LEVERAGE = 300; // x3

    //     address expectedCreditAccountAddress = accountFactory.head();

    //     evm.prank(FRIEND);
    //     creditFacade.approveAccountTransfer(USER, true);

    //     evm.expectCall(
    //         address(creditManager),
    //         abi.encodeCall(
    //             "openCreditAccount(uint256,address)", (DAI_ACCOUNT_AMOUNT * LEVERAGE) / LEVERAGE_DECIMALS, FRIEND
    //         )
    //     );

    //     evm.expectEmit(true, true, false, true);
    //     emit OpenCreditAccount(
    //         FRIEND, expectedCreditAccountAddress, (DAI_ACCOUNT_AMOUNT * LEVERAGE) / LEVERAGE_DECIMALS, REFERRAL_CODE
    //     );

    //     evm.expectCall(
    //         address(creditManager),
    //         abi.encodeCall(
    //             "addCollateral(address,address,address,uint256)",
    //             USER,
    //             expectedCreditAccountAddress,
    //             underlying,
    //             DAI_ACCOUNT_AMOUNT
    //         )
    //     );

    //     evm.expectEmit(true, true, false, true);
    //     emit AddCollateral(creditAccount, FRIEND, underlying, DAI_ACCOUNT_AMOUNT);

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, FRIEND, LEVERAGE, REFERRAL_CODE);
    // }

    /// @dev [FA-7]: openCreditAccount and openCreditAccount reverts when debt increase is forbidden
    function test_FA_07_openCreditAccountMulticall_reverts_if_borrowing_forbidden() public {
        (uint256 minBorrowedAmount,) = creditFacade.debtLimits();

        evm.prank(CONFIGURATOR);
        creditConfigurator.forbidBorrowing();

        MultiCall[] memory calls = multicallBuilder(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
            })
        );

        evm.expectRevert(BorrowedBlockLimitException.selector);
        evm.prank(USER);
        creditFacade.openCreditAccount(minBorrowedAmount, USER, calls, 0);
    }

    /// @dev [FA-8]: openCreditAccount runs operations in correct order
    function test_FA_08_openCreditAccountMulticall_runs_operations_in_correct_order() public {
        evm.prank(FRIEND);
        creditFacade.approveAccountTransfer(USER, true);

        RevocationPair[] memory revocations = new RevocationPair[](1);

        revocations[0] = RevocationPair({spender: address(this), token: underlying});

        // tokenTestSuite.mint(Tokens.DAI, USER, WAD);
        // tokenTestSuite.approve(Tokens.DAI, USER, address(creditManager));

        address expectedCreditAccountAddress = accountFactory.head();

        MultiCall[] memory calls = multicallBuilder(
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

        evm.expectCall(
            address(creditManager), abi.encodeCall(ICreditManagerV3.openCreditAccount, (DAI_ACCOUNT_AMOUNT, FRIEND))
        );

        evm.expectEmit(true, true, false, true);
        emit OpenCreditAccount(expectedCreditAccountAddress, FRIEND, USER, DAI_ACCOUNT_AMOUNT, REFERRAL_CODE);

        evm.expectEmit(true, false, false, false);
        emit StartMultiCall(expectedCreditAccountAddress);

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.addCollateral, (USER, expectedCreditAccountAddress, underlying, DAI_ACCOUNT_AMOUNT)
            )
        );

        evm.expectEmit(true, true, false, true);
        emit AddCollateral(expectedCreditAccountAddress, underlying, DAI_ACCOUNT_AMOUNT);

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.revokeAdapterAllowances, (expectedCreditAccountAddress, revocations))
        );

        evm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck,
                (expectedCreditAccountAddress, 1, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        evm.prank(USER);
        creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, FRIEND, calls, REFERRAL_CODE);
    }

    /// @dev [FA-9]: openCreditAccount cant open credit account with hf <1;
    function test_FA_09_openCreditAccountMulticall_cant_open_credit_account_with_hf_less_one(
        uint256 amount,
        uint8 token1
    ) public {
        evm.assume(amount > 10000 && amount < DAI_ACCOUNT_AMOUNT);
        evm.assume(token1 > 0 && token1 < creditManager.collateralTokensCount());

        tokenTestSuite.mint(Tokens.DAI, address(creditManager.poolService()), type(uint96).max);

        evm.prank(CONFIGURATOR);
        creditConfigurator.setMaxDebtPerBlockMultiplier(type(uint8).max);

        evm.prank(CONFIGURATOR);
        creditConfigurator.setLimits(1, type(uint96).max);

        (address collateral,) = creditManager.collateralTokens(token1);

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
            evm.expectRevert(NotEnoughCollateralException.selector);
        }

        evm.prank(USER);
        creditFacade.openCreditAccount(
            DAI_ACCOUNT_AMOUNT,
            USER,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (collateral, amount))
                })
            ),
            REFERRAL_CODE
        );
    }

    /// @dev [FA-10]: decrease debt during openCreditAccount
    function test_FA_10_decrease_debt_forbidden_during_openCreditAccount() public {
        evm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, DECREASE_DEBT_PERMISSION));

        evm.prank(USER);

        creditFacade.openCreditAccount(
            DAI_ACCOUNT_AMOUNT,
            USER,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.decreaseDebt, 812)
                })
            ),
            REFERRAL_CODE
        );
    }

    /// @dev [FA-11A]: openCreditAccount reverts if met borrowed limit per block
    function test_FA_11A_openCreditAccount_reverts_if_met_borrowed_limit_per_block() public {
        (uint128 _minDebt, uint128 _maxDebt) = creditFacade.debtLimits();

        tokenTestSuite.mint(Tokens.DAI, address(cft.poolMock()), _maxDebt * 2);

        tokenTestSuite.mint(Tokens.DAI, USER, DAI_ACCOUNT_AMOUNT);
        tokenTestSuite.mint(Tokens.DAI, FRIEND, DAI_ACCOUNT_AMOUNT);

        tokenTestSuite.approve(Tokens.DAI, USER, address(creditManager));
        tokenTestSuite.approve(Tokens.DAI, FRIEND, address(creditManager));

        evm.roll(2);

        evm.prank(CONFIGURATOR);
        creditConfigurator.setMaxDebtPerBlockMultiplier(1);

        MultiCall[] memory calls = multicallBuilder(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT))
            })
        );

        evm.prank(FRIEND);
        creditFacade.openCreditAccount(_maxDebt - _minDebt, FRIEND, calls, 0);

        evm.expectRevert(BorrowedBlockLimitException.selector);

        evm.prank(USER);
        creditFacade.openCreditAccount(_minDebt + 1, USER, calls, 0);
    }

    /// @dev [FA-11B]: openCreditAccount reverts if amount < minAmount or amount > maxAmount
    function test_FA_11B_openCreditAccount_reverts_if_amount_less_minBorrowedAmount_or_bigger_than_maxBorrowedAmount()
        public
    {
        (uint128 minBorrowedAmount, uint128 maxBorrowedAmount) = creditFacade.debtLimits();

        MultiCall[] memory calls = multicallBuilder(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
            })
        );

        evm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        evm.prank(USER);
        creditFacade.openCreditAccount(minBorrowedAmount - 1, USER, calls, 0);

        evm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        evm.prank(USER);
        creditFacade.openCreditAccount(maxBorrowedAmount + 1, USER, calls, 0);
    }

    //
    // CLOSE CREDIT ACCOUNT
    //

    /// @dev [FA-12]: closeCreditAccount runs multicall operations in correct order
    function test_FA_12_closeCreditAccount_runs_operations_in_correct_order() public {
        (address creditAccount, uint256 balance) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        MultiCall[] memory calls = multicallBuilder(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setCaForExternalCall, (creditAccount)));

        evm.expectEmit(true, false, false, false);
        emit StartMultiCall(creditAccount);

        evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.executeOrder, (DUMB_CALLDATA)));

        evm.expectEmit(true, false, false, true);
        emit ExecuteOrder(address(targetMock));

        evm.expectCall(creditAccount, abi.encodeCall(CreditAccount.execute, (address(targetMock), DUMB_CALLDATA)));

        evm.expectCall(address(targetMock), DUMB_CALLDATA);

        evm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setCaForExternalCall, (address(1))));

        // evm.expectCall(
        //     address(creditManager),
        //     abi.encodeCall(
        //         ICreditManagerV3.closeCreditAccount,
        //         (creditAccount, ClosureAction.CLOSE_ACCOUNT, 0, USER, FRIEND, 1, 10, DAI_ACCOUNT_AMOUNT, true)
        //     )
        // );

        evm.expectEmit(true, true, false, false);
        emit CloseCreditAccount(creditAccount, USER, FRIEND);

        // increase block number, cause it's forbidden to close ca in the same block
        evm.roll(block.number + 1);

        evm.prank(USER);
        creditFacade.closeCreditAccount(creditAccount, FRIEND, 10, true, calls);

        assertEq0(targetMock.callData(), DUMB_CALLDATA, "Incorrect calldata");
    }

    /// @dev [FA-13]: closeCreditAccount reverts on internal calls in multicall
    function test_FA_13_closeCreditAccount_reverts_on_internal_call_in_multicall_on_closure() public {
        /// TODO: CHANGE TEST
        // bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");

        // _openTestCreditAccount();

        // evm.roll(block.number + 1);

        // evm.expectRevert(ForbiddenDuringClosureException.selector);

        // // It's used dumb calldata, cause all calls to creditFacade are forbidden

        // evm.prank(USER);
        // creditFacade.closeCreditAccount(
        //     FRIEND, 0, true, multicallBuilder(MultiCall({target: address(creditFacade), callData: DUMB_CALLDATA}))
        // );
    }

    //
    // LIQUIDATE CREDIT ACCOUNT
    //

    /// @dev [FA-14]: liquidateCreditAccount reverts if hf > 1
    function test_FA_14_liquidateCreditAccount_reverts_if_hf_is_greater_than_1() public {
        (address creditAccount,) = _openTestCreditAccount();

        evm.expectRevert(CreditAccountNotLiquidatableException.selector);

        evm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, LIQUIDATOR, 0, true, multicallBuilder());
    }

    /// @dev [FA-15]: liquidateCreditAccount executes needed calls and emits events
    function test_FA_15_liquidateCreditAccount_executes_needed_calls_and_emits_events() public {
        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        MultiCall[] memory calls = multicallBuilder(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        _makeAccountsLiquitable();

        // EXPECTED STACK TRACE & EVENTS

        evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setCaForExternalCall, (creditAccount)));

        evm.expectEmit(true, false, false, false);
        emit StartMultiCall(creditAccount);

        evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.executeOrder, (DUMB_CALLDATA)));

        evm.expectEmit(true, false, false, false);
        emit ExecuteOrder(address(targetMock));

        evm.expectCall(creditAccount, abi.encodeCall(CreditAccount.execute, (address(targetMock), DUMB_CALLDATA)));

        evm.expectCall(address(targetMock), DUMB_CALLDATA);

        evm.expectEmit(false, false, false, false);
        emit FinishMultiCall();

        evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setCaForExternalCall, (address(1))));

        // Total value = 2 * DAI_ACCOUNT_AMOUNT, cause we have x2 leverage
        uint256 totalValue = 2 * DAI_ACCOUNT_AMOUNT;
        uint256 debtWithInterest = DAI_ACCOUNT_AMOUNT;

        // evm.expectCall(
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

        evm.expectEmit(true, true, true, true);
        emit LiquidateCreditAccount(creditAccount, USER, LIQUIDATOR, FRIEND, ClosureAction.LIQUIDATE_ACCOUNT, 0);

        evm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 10, true, calls);
    }

    /// @dev [FA-15A]: Borrowing is prohibited after a liquidation with loss
    function test_FA_15A_liquidateCreditAccount_prohibits_borrowing_on_loss() public {
        (address creditAccount,) = _openTestCreditAccount();

        uint8 maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();

        assertGt(maxDebtPerBlockMultiplier, 0, "SETUP: Increase debt is already enabled");

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        MultiCall[] memory calls = multicallBuilder(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        _makeAccountsLiquitable();

        evm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 10, true, calls);

        maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();

        assertEq(maxDebtPerBlockMultiplier, 0, "Increase debt wasn't forbidden after loss");
    }

    /// @dev [FA-15B]: CreditFacade is paused after too much cumulative loss from liquidations
    function test_FA_15B_liquidateCreditAccount_pauses_CreditFacade_on_too_much_loss() public {
        evm.prank(CONFIGURATOR);
        creditConfigurator.setMaxCumulativeLoss(1);

        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        MultiCall[] memory calls = multicallBuilder(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        _makeAccountsLiquitable();

        evm.prank(LIQUIDATOR);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 10, true, calls);

        assertTrue(creditFacade.paused(), "Credit manager was not paused");
    }

    function test_FA_16_liquidateCreditAccount_reverts_on_internal_call_in_multicall_on_closure() public {
        /// TODO: Add all cases with different permissions!

        MultiCall[] memory calls = multicallBuilder(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
            })
        );

        (address creditAccount,) = _openTestCreditAccount();

        _makeAccountsLiquitable();
        evm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, ADD_COLLATERAL_PERMISSION));

        evm.prank(LIQUIDATOR);

        // It's used dumb calldata, cause all calls to creditFacade are forbidden
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 10, true, calls);
    }

    // [FA-16A]: liquidateCreditAccount reverts when zero address is passed as to
    function test_FA_16A_liquidateCreditAccount_reverts_on_zero_to_address() public {
        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        MultiCall[] memory calls = multicallBuilder(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );
        _openTestCreditAccount();

        _makeAccountsLiquitable();
        evm.expectRevert(ZeroAddressException.selector);

        evm.prank(LIQUIDATOR);

        // It's used dumb calldata, cause all calls to creditFacade are forbidden
        creditFacade.liquidateCreditAccount(USER, address(0), 10, true, calls);
    }

    //
    // INCREASE & DECREASE DEBT
    //

    /// @dev [FA-17]: increaseDebt executes function as expected
    function test_FA_17_increaseDebt_executes_actions_as_expected() public {
        (address creditAccount,) = _openTestCreditAccount();

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.manageDebt, (creditAccount, 512, 1, ManageDebtAction.INCREASE_DEBT))
        );

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 1, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        evm.expectEmit(true, false, false, true);
        emit IncreaseDebt(creditAccount, 512);

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, (512))
                })
            )
        );
    }

    /// @dev [FA-18A]: increaseDebt revets if more than block limit
    function test_FA_18A_increaseDebt_revets_if_more_than_block_limit() public {
        (address creditAccount,) = _openTestCreditAccount();

        uint8 maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();
        (, uint128 maxDebt) = creditFacade.debtLimits();

        evm.expectRevert(BorrowedBlockLimitException.selector);

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, (maxDebt * maxDebtPerBlockMultiplier + 1))
                })
            )
        );
    }

    /// @dev [FA-18B]: increaseDebt revets if more than maxBorrowedAmount
    function test_FA_18B_increaseDebt_revets_if_more_than_block_limit() public {
        (address creditAccount,) = _openTestCreditAccount();

        (, uint128 maxBorrowedAmount) = creditFacade.debtLimits();

        uint256 amount = maxBorrowedAmount - DAI_ACCOUNT_AMOUNT + 1;

        tokenTestSuite.mint(Tokens.DAI, address(cft.poolMock()), amount);

        evm.expectRevert(BorrowAmountOutOfLimitsException.selector);

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, (amount))
                })
            )
        );
    }

    /// @dev [FA-18C]: increaseDebt revets isIncreaseDebtForbidden is enabled
    function test_FA_18C_increaseDebt_revets_isIncreaseDebtForbidden_is_enabled() public {
        (address creditAccount,) = _openTestCreditAccount();

        evm.prank(CONFIGURATOR);
        creditConfigurator.forbidBorrowing();

        evm.expectRevert(BorrowedBlockLimitException.selector);

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, (1))
                })
            )
        );
    }

    /// @dev [FA-18D]: increaseDebt reverts if there is a forbidden token on account
    function test_FA_18D_increaseDebt_reverts_with_forbidden_tokens() public {
        (address creditAccount,) = _openTestCreditAccount();

        address link = tokenTestSuite.addressOf(Tokens.LINK);

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.enableToken, (link))
                })
            )
        );

        evm.prank(CONFIGURATOR);
        creditConfigurator.forbidToken(link);

        evm.expectRevert(ForbiddenTokensException.selector);

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, (1))
                })
            )
        );
    }

    /// @dev [FA-19]: decreaseDebt executes function as expected
    function test_FA_19_decreaseDebt_executes_actions_as_expected() public {
        (address creditAccount,) = _openTestCreditAccount();

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.manageDebt, (creditAccount, 512, 1, ManageDebtAction.DECREASE_DEBT))
        );

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 1, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        evm.expectEmit(true, false, false, true);
        emit DecreaseDebt(creditAccount, 512);

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.decreaseDebt, (512))
                })
            )
        );
    }

    /// @dev [FA-20]:decreaseDebt revets if less than minBorrowedAmount
    function test_FA_20_decreaseDebt_revets_if_less_than_minBorrowedAmount() public {
        (address creditAccount,) = _openTestCreditAccount();

        (uint128 minBorrowedAmount,) = creditFacade.debtLimits();

        uint256 amount = DAI_ACCOUNT_AMOUNT - minBorrowedAmount + 1;

        tokenTestSuite.mint(Tokens.DAI, address(cft.poolMock()), amount);

        evm.expectRevert(BorrowAmountOutOfLimitsException.selector);

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
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

    /// @dev [FA-21]: addCollateral executes function as expected
    function test_FA_21_addCollateral_executes_actions_as_expected() public {
        (address creditAccount,) = _openTestCreditAccount();

        expectTokenIsEnabled(creditAccount, Tokens.USDC, false);

        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);

        tokenTestSuite.mint(Tokens.USDC, USER, 512);
        tokenTestSuite.approve(Tokens.USDC, USER, address(creditManager));

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.addCollateral, (USER, creditAccount, usdcToken, 512))
        );

        evm.expectEmit(true, true, false, true);
        emit AddCollateral(creditAccount, usdcToken, 512);

        // TODO: change test

        MultiCall[] memory calls = multicallBuilder(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (usdcToken, 512))
            })
        );

        evm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        expectBalance(Tokens.USDC, creditAccount, 512);
        expectTokenIsEnabled(creditAccount, Tokens.USDC, true);
    }

    /// @dev [FA-21C]: addCollateral calls checkEnabledTokensLength
    function test_FA_21C_addCollateral_optimizes_enabled_tokens() public {
        (address creditAccount,) = _openTestCreditAccount();

        evm.prank(USER);
        creditFacade.approveAccountTransfer(FRIEND, true);

        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);

        tokenTestSuite.mint(Tokens.USDC, FRIEND, 512);
        tokenTestSuite.approve(Tokens.USDC, FRIEND, address(creditManager));

        // evm.expectCall(
        //     address(creditManager),
        //     abi.encodeCall(ICreditManagerV3.checkEnabledTokensLength.selector, creditAccount)
        // );

        // evm.prank(FRIEND);
        // creditFacade.addCollateral(USER, usdcToken, 512);
    }

    //
    // MULTICALL
    //

    /// @dev [FA-22]: multicall reverts if calldata length is less than 4 bytes
    function test_FA_22_multicall_reverts_if_calldata_length_is_less_than_4_bytes() public {
        (address creditAccount,) = _openTestCreditAccount();

        evm.expectRevert(IncorrectCallDataException.selector);

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount, multicallBuilder(MultiCall({target: address(creditFacade), callData: bytes("123")}))
        );
    }

    /// @dev [FA-23]: multicall reverts for unknown methods
    function test_FA_23_multicall_reverts_for_unknown_methods() public {
        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");

        evm.expectRevert(UnknownMethodException.selector);

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount, multicallBuilder(MultiCall({target: address(creditFacade), callData: DUMB_CALLDATA}))
        );
    }

    /// @dev [FA-24]: multicall reverts for creditManager address
    function test_FA_24_multicall_reverts_for_creditManager_address() public {
        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");

        evm.expectRevert(TargetContractNotAllowedException.selector);

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount, multicallBuilder(MultiCall({target: address(creditManager), callData: DUMB_CALLDATA}))
        );
    }

    /// @dev [FA-25]: multicall reverts on non-adapter targets
    function test_FA_25_multicall_reverts_for_non_adapters() public {
        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");
        evm.expectRevert(TargetContractNotAllowedException.selector);

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount, multicallBuilder(MultiCall({target: DUMB_ADDRESS, callData: DUMB_CALLDATA}))
        );
    }

    /// @dev [FA-26]: multicall addCollateral and oncreaseDebt works with creditFacade calls as expected
    function test_FA_26_multicall_addCollateral_and_increase_debt_works_with_creditFacade_calls_as_expected() public {
        (address creditAccount,) = _openTestCreditAccount();

        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
        tokenTestSuite.mint(Tokens.USDC, USER, USDC_EXCHANGE_AMOUNT);
        tokenTestSuite.approve(Tokens.USDC, USER, address(creditManager));

        uint256 usdcMask = creditManager.getTokenMaskOrRevert(usdcToken);

        evm.expectEmit(true, true, false, true);
        emit StartMultiCall(creditAccount);

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.addCollateral, (USER, creditAccount, usdcToken, USDC_EXCHANGE_AMOUNT))
        );

        evm.expectEmit(true, true, false, true);
        emit AddCollateral(creditAccount, usdcToken, USDC_EXCHANGE_AMOUNT);

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.manageDebt, (creditAccount, 256, usdcMask | 1, ManageDebtAction.INCREASE_DEBT)
            )
        );

        evm.expectEmit(true, false, false, true);
        emit IncreaseDebt(creditAccount, 256);

        evm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 3, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
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

    /// @dev [FA-27]: multicall addCollateral and decreaseDebt works with creditFacade calls as expected
    function test_FA_27_multicall_addCollateral_and_decreaseDebt_works_with_creditFacade_calls_as_expected() public {
        (address creditAccount,) = _openTestCreditAccount();

        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
        tokenTestSuite.mint(Tokens.USDC, USER, USDC_EXCHANGE_AMOUNT);
        tokenTestSuite.approve(Tokens.USDC, USER, address(creditManager));

        uint256 usdcMask = creditManager.getTokenMaskOrRevert(usdcToken);

        evm.expectEmit(true, true, false, true);
        emit StartMultiCall(creditAccount);

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.addCollateral, (USER, creditAccount, usdcToken, USDC_EXCHANGE_AMOUNT))
        );

        evm.expectEmit(true, true, false, true);
        emit AddCollateral(creditAccount, usdcToken, USDC_EXCHANGE_AMOUNT);

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.manageDebt, (creditAccount, 256, usdcMask | 1, ManageDebtAction.DECREASE_DEBT)
            )
        );

        evm.expectEmit(true, false, false, true);
        emit DecreaseDebt(creditAccount, 256);

        evm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 3, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
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

    /// @dev [FA-28]: multicall reverts for decrease opeartion after increase one
    function test_FA_28_multicall_reverts_for_decrease_opeartion_after_increase_one() public {
        (address creditAccount,) = _openTestCreditAccount();

        evm.expectRevert(abi.encodeWithSelector(NoPermissionException.selector, DECREASE_DEBT_PERMISSION));

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
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

    /// @dev [FA-29]: multicall works with adapters calls as expected
    function test_FA_29_multicall_works_with_adapters_calls_as_expected() public {
        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        // TODO: add enable / disable cases

        MultiCall[] memory calls = multicallBuilder(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setCaForExternalCall, (creditAccount)));

        evm.expectEmit(true, true, false, true);
        emit StartMultiCall(creditAccount);

        evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.executeOrder, (DUMB_CALLDATA)));

        evm.expectEmit(true, false, false, true);
        emit ExecuteOrder(address(targetMock));

        evm.expectCall(creditAccount, abi.encodeCall(CreditAccount.execute, (address(targetMock), DUMB_CALLDATA)));

        evm.expectCall(address(targetMock), DUMB_CALLDATA);

        evm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setCaForExternalCall, (address(1))));

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 1, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        evm.prank(USER);
        creditFacade.multicall(creditAccount, calls);
    }

    //
    // TRANSFER ACCOUNT OWNERSHIP
    //

    // /// @dev [FA-32]: transferAccountOwnership reverts if "to" user doesn't provide allowance
    /// TODO: CHANGE TO ALLOWANCE METHOD
    // function test_FA_32_transferAccountOwnership_reverts_if_whitelisted_enabled() public {
    //     cft.testFacadeWithDegenNFT();
    //     creditFacade = cft.creditFacade();

    //     evm.expectRevert(AccountTransferNotAllowedException.selector);
    //     evm.prank(USER);
    //     creditFacade.transferAccountOwnership(DUMB_ADDRESS);
    // }

    /// @dev [FA-33]: transferAccountOwnership reverts if "to" user doesn't provide allowance
    function test_FA_33_transferAccountOwnership_reverts_if_to_user_doesnt_provide_allowance() public {
        (address creditAccount,) = _openTestCreditAccount();
        evm.expectRevert(AccountTransferNotAllowedException.selector);

        evm.prank(USER);
        creditFacade.transferAccountOwnership(creditAccount, DUMB_ADDRESS);
    }

    /// @dev [FA-34]: transferAccountOwnership reverts if hf less 1
    function test_FA_34_transferAccountOwnership_reverts_if_hf_less_1() public {
        (address creditAccount,) = _openTestCreditAccount();

        evm.prank(FRIEND);
        creditFacade.approveAccountTransfer(USER, true);

        _makeAccountsLiquitable();

        evm.expectRevert(CantTransferLiquidatableAccountException.selector);

        evm.prank(USER);
        creditFacade.transferAccountOwnership(creditAccount, FRIEND);
    }

    /// @dev [FA-35]: transferAccountOwnership transfers account if it's allowed
    function test_FA_35_transferAccountOwnership_transfers_account_if_its_allowed() public {
        (address creditAccount,) = _openTestCreditAccount();

        evm.prank(FRIEND);
        creditFacade.approveAccountTransfer(USER, true);

        evm.expectCall(
            address(creditManager), abi.encodeCall(ICreditManagerV3.transferAccountOwnership, (creditAccount, FRIEND))
        );

        evm.expectEmit(true, true, false, false);
        emit TransferAccount(creditAccount, USER, FRIEND);

        evm.prank(USER);
        creditFacade.transferAccountOwnership(creditAccount, FRIEND);

        // assertEq(
        //     creditManager.getCreditAccountOrRevert(FRIEND), creditAccount, "Credit account was not properly transferred"
        // );
    }

    /// @dev [FA-36]: checkAndUpdateBorrowedBlockLimit doesn't change block limit if maxBorrowedAmountPerBlock = type(uint128).max
    function test_FA_36_checkAndUpdateBorrowedBlockLimit_doesnt_change_block_limit_if_set_to_max() public {
        // evm.prank(CONFIGURATOR);
        // creditConfigurator.setMaxDebtLimitPerBlock(type(uint128).max);

        // (uint64 blockLastUpdate, uint128 borrowedInBlock) = creditFacade.getTotalBorrowedInBlock();
        // assertEq(blockLastUpdate, 0, "Incorrect currentBlockLimit");
        // assertEq(borrowedInBlock, 0, "Incorrect currentBlockLimit");

        // _openTestCreditAccount();

        // (blockLastUpdate, borrowedInBlock) = creditFacade.getTotalBorrowedInBlock();
        // assertEq(blockLastUpdate, 0, "Incorrect currentBlockLimit");
        // assertEq(borrowedInBlock, 0, "Incorrect currentBlockLimit");
    }

    /// @dev [FA-37]: checkAndUpdateBorrowedBlockLimit doesn't change block limit if maxBorrowedAmountPerBlock = type(uint128).max
    function test_FA_37_checkAndUpdateBorrowedBlockLimit_updates_block_limit_properly() public {
        // (uint64 blockLastUpdate, uint128 borrowedInBlock) = creditFacade.getTotalBorrowedInBlock();

        // assertEq(blockLastUpdate, 0, "Incorrect blockLastUpdate");
        // assertEq(borrowedInBlock, 0, "Incorrect borrowedInBlock");

        // _openTestCreditAccount();

        // (blockLastUpdate, borrowedInBlock) = creditFacade.getTotalBorrowedInBlock();

        // assertEq(blockLastUpdate, block.number, "blockLastUpdate");
        // assertEq(borrowedInBlock, DAI_ACCOUNT_AMOUNT, "Incorrect borrowedInBlock");

        // evm.prank(USER);
        // creditFacade.multicall(
        //     multicallBuilder(
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
        // evm.roll(block.number + 1);

        // evm.prank(USER);
        // creditFacade.multicall(
        //     multicallBuilder(
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
    // APPROVE ACCOUNT TRANSFER
    //

    /// @dev [FA-38]: approveAccountTransfer changes transfersAllowed
    function test_FA_38_transferAccountOwnership_with_allowed_to_transfers_account() public {
        assertTrue(creditFacade.transfersAllowed(USER, FRIEND) == false, "Transfer is unexpectedly allowed ");

        evm.expectEmit(true, true, false, true);
        emit AllowAccountTransfer(USER, FRIEND, true);

        evm.prank(FRIEND);
        creditFacade.approveAccountTransfer(USER, true);

        assertTrue(creditFacade.transfersAllowed(USER, FRIEND) == true, "Transfer is unexpectedly not allowed ");

        evm.expectEmit(true, true, false, true);
        emit AllowAccountTransfer(USER, FRIEND, false);

        evm.prank(FRIEND);
        creditFacade.approveAccountTransfer(USER, false);
        assertTrue(creditFacade.transfersAllowed(USER, FRIEND) == false, "Transfer is unexpectedly allowed ");
    }

    //
    // ENABLE TOKEN
    //

    /// @dev [FA-39]: enable token works as expected
    function test_FA_39_enable_token_is_correct() public {
        (address creditAccount,) = _openTestCreditAccount();

        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
        expectTokenIsEnabled(creditAccount, Tokens.USDC, false);

        tokenTestSuite.mint(Tokens.USDC, creditAccount, 100);

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
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

    /// @dev [FA-41]: calcTotalValue computes correctly
    function test_FA_41_calcTotalValue_computes_correctly() public {
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

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
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

    /// @dev [FA-42]: calcCreditAccountHealthFactor computes correctly
    function test_FA_42_calcCreditAccountHealthFactor_computes_correctly() public {
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

    /// @dev [FA-44]: setContractToAdapter reverts if called non-configurator
    function test_FA_44_config_functions_revert_if_called_non_configurator() public {
        evm.expectRevert(CallerNotConfiguratorException.selector);
        evm.prank(USER);
        creditFacade.setDebtLimits(100, 100, 100);

        evm.expectRevert(CallerNotConfiguratorException.selector);
        evm.prank(USER);
        creditFacade.setBotList(FRIEND);

        evm.expectRevert(CallerNotConfiguratorException.selector);
        evm.prank(USER);
        creditFacade.addEmergencyLiquidator(DUMB_ADDRESS);

        evm.expectRevert(CallerNotConfiguratorException.selector);
        evm.prank(USER);
        creditFacade.removeEmergencyLiquidator(DUMB_ADDRESS);
    }

    /// CHECK SLIPPAGE PROTECTION

    /// [TODO]: add new test

    /// @dev [FA-45]: rrevertIfGetLessThan during multicalls works correctly
    function test_FA_45_revertIfGetLessThan_works_correctly() public {
        (address creditAccount,) = _openTestCreditAccount();

        uint256 expectedDAI = 1000;
        uint256 expectedLINK = 2000;

        address tokenLINK = tokenTestSuite.addressOf(Tokens.LINK);

        Balance[] memory expectedBalances = new Balance[](2);
        expectedBalances[0] = Balance({token: underlying, balance: expectedDAI});

        expectedBalances[1] = Balance({token: tokenLINK, balance: expectedLINK});

        // TOKEN PREPARATION
        tokenTestSuite.mint(Tokens.DAI, USER, expectedDAI * 3);
        tokenTestSuite.mint(Tokens.LINK, USER, expectedLINK * 3);

        tokenTestSuite.approve(Tokens.DAI, USER, address(creditManager));
        tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
                CreditFacadeMulticaller(address(creditFacade)).revertIfReceivedLessThan(expectedBalances),
                CreditFacadeMulticaller(address(creditFacade)).addCollateral(underlying, expectedDAI),
                CreditFacadeMulticaller(address(creditFacade)).addCollateral(tokenLINK, expectedLINK)
            )
        );

        for (uint256 i = 0; i < 2; i++) {
            evm.prank(USER);
            evm.expectRevert(
                abi.encodeWithSelector(
                    BalanceLessThanMinimumDesiredException.selector, ((i == 0) ? underlying : tokenLINK)
                )
            );

            creditFacade.multicall(
                creditAccount,
                multicallBuilder(
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

    /// @dev [FA-45A]: rrevertIfGetLessThan everts if called twice
    function test_FA_45A_revertIfGetLessThan_reverts_if_called_twice() public {
        uint256 expectedDAI = 1000;

        Balance[] memory expectedBalances = new Balance[](1);
        expectedBalances[0] = Balance({token: underlying, balance: expectedDAI});

        (address creditAccount,) = _openTestCreditAccount();
        evm.prank(USER);
        evm.expectRevert(ExpectedBalancesAlreadySetException.selector);

        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
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

    /// @dev [FA-46]: openCreditAccount and openCreditAccount no longer work if the CreditFacadeV3 is expired
    function test_FA_46_openCreditAccount_reverts_on_expired_CreditFacade() public {
        _setUp({
            _underlying: Tokens.DAI,
            withDegenNFT: false,
            withExpiration: true,
            supportQuotas: false,
            accountFactoryVer: 1
        });

        evm.warp(block.timestamp + 1);

        evm.expectRevert(NotAllowedAfterExpirationException.selector);

        evm.prank(USER);
        creditFacade.openCreditAccount(
            DAI_ACCOUNT_AMOUNT,
            USER,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            ),
            0
        );
    }

    /// @dev [FA-47]: liquidateExpiredCreditAccount should not work before the CreditFacadeV3 is expired
    function test_FA_47_liquidateExpiredCreditAccount_reverts_before_expiration() public {
        _setUp({
            _underlying: Tokens.DAI,
            withDegenNFT: false,
            withExpiration: true,
            supportQuotas: false,
            accountFactoryVer: 1
        });

        _openTestCreditAccount();

        // evm.expectRevert(CantLiquidateNonExpiredException.selector);

        // evm.prank(LIQUIDATOR);
        // creditFacade.liquidateExpiredCreditAccount(USER, LIQUIDATOR, 0, false, multicallBuilder());
    }

    /// @dev [FA-48]: liquidateExpiredCreditAccount should not work when expiration is set to zero (i.e. CreditFacadeV3 is non-expiring)
    function test_FA_48_liquidateExpiredCreditAccount_reverts_on_CreditFacade_with_no_expiration() public {
        _openTestCreditAccount();

        // evm.expectRevert(CantLiquidateNonExpiredException.selector);

        // evm.prank(LIQUIDATOR);
        // creditFacade.liquidateExpiredCreditAccount(USER, LIQUIDATOR, 0, false, multicallBuilder());
    }

    /// @dev [FA-49]: liquidateExpiredCreditAccount works correctly and emits events
    function test_FA_49_liquidateExpiredCreditAccount_works_correctly_after_expiration() public {
        _setUp({
            _underlying: Tokens.DAI,
            withDegenNFT: false,
            withExpiration: true,
            supportQuotas: false,
            accountFactoryVer: 1
        });
        (address creditAccount, uint256 balance) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        MultiCall[] memory calls = multicallBuilder(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        evm.warp(block.timestamp + 1);
        evm.roll(block.number + 1);

        // (uint256 borrowedAmount, uint256 borrowedAmountWithInterest,) =
        //     creditManager.calcCreditAccountAccruedInterest(creditAccount);

        // (, uint256 remainingFunds,,) = creditManager.calcClosePayments(
        //     balance, ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT, borrowedAmount, borrowedAmountWithInterest
        // );

        // // EXPECTED STACK TRACE & EVENTS

        // evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setCaForExternalCall, (creditAccount)));

        // evm.expectEmit(true, false, false, false);
        // emit StartMultiCall(creditAccount);

        // evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.executeOrder, (DUMB_CALLDATA)));

        // evm.expectEmit(true, false, false, false);
        // emit ExecuteOrder(address(targetMock));

        // evm.expectCall(creditAccount, abi.encodeCall(CreditAccount.execute, (address(targetMock), DUMB_CALLDATA)));

        // evm.expectCall(address(targetMock), DUMB_CALLDATA);

        // evm.expectEmit(false, false, false, false);
        // emit FinishMultiCall();

        // evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setCaForExternalCall, (address(1))));
        // // Total value = 2 * DAI_ACCOUNT_AMOUNT, cause we have x2 leverage
        // uint256 totalValue = balance;

        // // evm.expectCall(
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

        // evm.expectEmit(true, true, false, true);
        // emit LiquidateCreditAccount(
        //     creditAccount, USER, LIQUIDATOR, FRIEND, ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT, remainingFunds
        // );

        // evm.prank(LIQUIDATOR);
        // creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 10, true, calls);
    }

    ///
    /// ENABLE TOKEN
    ///

    /// @dev [FA-53]: enableToken works as expected in a multicall
    function test_FA_53_enableToken_works_as_expected_multicall() public {
        (address creditAccount,) = _openTestCreditAccount();

        address token = tokenTestSuite.addressOf(Tokens.USDC);

        // evm.expectCall(
        //     address(creditManager), abi.encodeCall(ICreditManagerV3.checkAndEnableToken.selector, token)
        // );

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.enableToken, (token))
                })
            )
        );

        expectTokenIsEnabled(creditAccount, Tokens.USDC, true);
    }

    /// @dev [FA-54]: disableToken works as expected in a multicall
    function test_FA_54_disableToken_works_as_expected_multicall() public {
        (address creditAccount,) = _openTestCreditAccount();

        address token = tokenTestSuite.addressOf(Tokens.USDC);

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.enableToken, (token))
                })
            )
        );

        // evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.disableToken.selector, token));

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeMulticall.disableToken, (token))
                })
            )
        );

        expectTokenIsEnabled(creditAccount, Tokens.USDC, false);
    }

    // /// @dev [FA-56]: liquidateCreditAccount correctly uses BlacklistHelper during liquidations
    // function test_FA_56_liquidateCreditAccount_correctly_handles_blacklisted_borrowers() public {
    //     _setUp(Tokens.USDC);

    //     cft.testFacadeWithBlacklistHelper();

    //     creditFacade = cft.creditFacade();

    //     address usdc = tokenTestSuite.addressOf(Tokens.USDC);

    //     address blacklistHelper = creditFacade.blacklistHelper();

    //     _openTestCreditAccount();

    //     uint256 expectedAmount = (
    //         2 * USDC_ACCOUNT_AMOUNT * (PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM - DEFAULT_FEE_LIQUIDATION)
    //     ) / PERCENTAGE_FACTOR - USDC_ACCOUNT_AMOUNT - 1 - 1; // second -1 because we add 1 to helper balance

    //     evm.roll(block.number + 1);

    //     evm.prank(address(creditConfigurator));
    //     CreditManagerV3(address(creditManager)).setLiquidationThreshold(usdc, 1);

    //     ERC20BlacklistableMock(usdc).setBlacklisted(USER, true);

    //     evm.expectCall(blacklistHelper, abi.encodeCall(IWithdrawManager.isBlacklisted, (usdc, USER)));

    //     evm.expectCall(
    //         address(creditManager), abi.encodeCall(ICreditManagerV3.transferAccountOwnership, (USER, blacklistHelper))
    //     );

    //     evm.expectCall(blacklistHelper, abi.encodeCall(IWithdrawManager.addWithdrawal, (usdc, USER, expectedAmount)));

    //     evm.expectEmit(true, false, false, true);
    //     emit UnderlyingSentToBlacklistHelper(USER, expectedAmount);

    //     evm.prank(LIQUIDATOR);
    //     creditFacade.liquidateCreditAccount(USER, FRIEND, 0, true, multicallBuilder());

    //     assertEq(IWithdrawManager(blacklistHelper).claimable(usdc, USER), expectedAmount, "Incorrect claimable amount");

    //     evm.prank(USER);
    //     IWithdrawManager(blacklistHelper).claim(usdc, FRIEND2);

    //     assertEq(tokenTestSuite.balanceOf(Tokens.USDC, FRIEND2), expectedAmount, "Transferred amount incorrect");
    // }

    // /// @dev [FA-57]: openCreditAccount reverts when the borrower is blacklisted on a blacklistable underlying
    // function test_FA_57_openCreditAccount_reverts_on_blacklisted_borrower() public {
    //     _setUp(Tokens.USDC);

    //     cft.testFacadeWithBlacklistHelper();

    //     creditFacade = cft.creditFacade();

    //     address usdc = tokenTestSuite.addressOf(Tokens.USDC);

    //     ERC20BlacklistableMock(usdc).setBlacklisted(USER, true);

    //     evm.expectRevert(NotAllowedForBlacklistedAddressException.selector);

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(
    //         USDC_ACCOUNT_AMOUNT,
    //         USER,
    //         multicallBuilder(
    //             MultiCall({
    //                 target: address(creditFacade),
    //                 callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
    //             })
    //         ),
    //         0
    //     );
    // }

    /// @dev [FA-58]: botMulticall works correctly
    function test_FA_58_botMulticall_works_correctly() public {
        (address creditAccount,) = _openTestCreditAccount();

        BotList botList = new BotList(address(cft.addressProvider()));

        evm.prank(CONFIGURATOR);
        creditConfigurator.setBotList(address(botList));

        /// ????
        address bot = address(new TargetContractMock());

        evm.prank(USER);
        botList.setBotPermissions(bot, type(uint192).max);

        bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        MultiCall[] memory calls = multicallBuilder(
            MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        );

        evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setCaForExternalCall, (creditAccount)));

        evm.expectEmit(true, true, false, true);
        emit StartMultiCall(creditAccount);

        evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.executeOrder, (DUMB_CALLDATA)));

        evm.expectEmit(true, false, false, true);
        emit ExecuteOrder(address(targetMock));

        evm.expectCall(creditAccount, abi.encodeCall(CreditAccount.execute, (address(targetMock), DUMB_CALLDATA)));

        evm.expectCall(address(targetMock), DUMB_CALLDATA);

        evm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.setCaForExternalCall, (address(1))));

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 1, new uint256[](0), PERCENTAGE_FACTOR)
            )
        );

        evm.prank(bot);
        creditFacade.botMulticall(creditAccount, calls);

        evm.expectRevert(NotApprovedBotException.selector);
        creditFacade.botMulticall(
            creditAccount, multicallBuilder(MultiCall({target: address(adapterMock), callData: DUMB_CALLDATA}))
        );

        evm.prank(CONFIGURATOR);
        botList.setBotForbiddenStatus(bot, true);

        evm.expectRevert(NotApprovedBotException.selector);
        evm.prank(bot);
        creditFacade.botMulticall(creditAccount, calls);
    }

    /// @dev [FA-59]: setFullCheckParams performs correct full check after multicall
    function test_FA_59_setFullCheckParams_correctly_passes_params_to_fullCollateralCheck() public {
        (address creditAccount,) = _openTestCreditAccount();

        uint256[] memory collateralHints = new uint256[](1);
        collateralHints[0] = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDC));

        uint256 enabledTokensMap = creditManager.enabledTokensMap(creditAccount);

        evm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, enabledTokensMap, collateralHints, 10001)
            )
        );

        evm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            multicallBuilder(
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

    /// @dev [FA-62]: addEmergencyLiquidator correctly sets value
    function test_FA_62_addEmergencyLiquidator_works_correctly() public {
        evm.prank(address(creditConfigurator));
        creditFacade.addEmergencyLiquidator(DUMB_ADDRESS);

        assertTrue(creditFacade.canLiquidateWhilePaused(DUMB_ADDRESS), "Value was not set");
    }

    /// @dev [FA-63]: removeEmergencyLiquidator correctly sets value
    function test_FA_63_removeEmergencyLiquidator_works_correctly() public {
        evm.prank(address(creditConfigurator));
        creditFacade.addEmergencyLiquidator(DUMB_ADDRESS);

        evm.prank(address(creditConfigurator));
        creditFacade.removeEmergencyLiquidator(DUMB_ADDRESS);

        assertTrue(!creditFacade.canLiquidateWhilePaused(DUMB_ADDRESS), "Value was is still set");
    }
}
