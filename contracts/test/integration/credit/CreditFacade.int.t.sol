// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {ICreditAccountBase} from "../../../interfaces/ICreditAccountV3.sol";

import {
    ICreditManagerV3,
    ICreditManagerV3Events,
    ClosureAction,
    ManageDebtAction,
    BOT_PERMISSIONS_SET_FLAG
} from "../../../interfaces/ICreditManagerV3.sol";
import {AllowanceAction} from "../../../interfaces/ICreditConfiguratorV3.sol";
import "../../../interfaces/ICreditFacadeV3.sol";

import {MultiCallBuilder} from "../../lib/MultiCallBuilder.sol";

// DATA

// CONSTANTS

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// TESTS

import "../../lib/constants.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";
import {IntegrationTestHelper} from "../../helpers/IntegrationTestHelper.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// MOCKS
import {AdapterMock} from "../../mocks//core/AdapterMock.sol";

// SUITES

import {Tokens} from "../../config/Tokens.sol";

uint256 constant WETH_TEST_AMOUNT = 5 * WAD;
uint16 constant REFERRAL_CODE = 23;

/// @title CreditFacadeTest
/// @notice Designed for unit test purposes only
contract CreditFacadeIntegrationTest is
    Test,
    BalanceHelper,
    IntegrationTestHelper,
    ICreditManagerV3Events,
    ICreditFacadeV3Events
{
    ///
    ///
    ///  HELPERS
    ///
    ///

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

    /// @dev I:[FA-1A]: constructor sets correct values
    function test_I_FA_01A_constructor_sets_correct_values() public allExpirableCases allDegenNftCases creditTest {
        assertEq(address(creditFacade.creditManager()), address(creditManager), "Incorrect creditManager");
        // assertEq(creditFacade.underlying(), underlying, "Incorrect underlying token");

        assertEq(creditFacade.weth(), creditManager.weth(), "Incorrect weth token");

        if (whitelisted) {
            assertEq(creditFacade.degenNFT(), address(degenNFT), "Incorrect degenNFT");
        } else {
            assertEq(creditFacade.degenNFT(), address(0), "Incorrect degenNFT");
        }
    }

    //
    // ALL FUNCTIONS REVERTS IF USER HAS NO ACCOUNT
    //

    /// @dev I:[FA-2]: functions reverts if borrower has no account
    function test_I_FA_02_functions_reverts_if_credit_account_not_exists() public {
        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.closeCreditAccount(DUMB_ADDRESS, FRIEND, 0, false, MultiCallBuilder.build());

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.closeCreditAccount(
            DUMB_ADDRESS,
            FRIEND,
            0,
            false,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            )
        );

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.liquidateCreditAccount(DUMB_ADDRESS, DUMB_ADDRESS, 0, false, MultiCallBuilder.build());

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        vm.prank(USER);
        creditFacade.multicall(
            DUMB_ADDRESS,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            )
        );

        // vm.prank(CONFIGURATOR);
        // creditConfigurator.allowContract(address(targetMock), address(adapterMock));
    }

    //
    // ETH => WETH TESTS
    //
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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            )
        );
        _checkForWETHTest();
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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (512))
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
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.increaseDebt, (maxDebt * maxDebtPerBlockMultiplier + 1)
                        )
                })
            )
        );
    }

    /// @dev I:[FA-18B]: increaseDebt revets if more than maxDebt
    function test_I_FA_18B_increaseDebt_revets_if_more_than_block_limit() public {
        (address creditAccount,) = _openTestCreditAccount();

        (, uint128 maxDebt) = creditFacade.debtLimits();

        uint256 amount = maxDebt - DAI_ACCOUNT_AMOUNT + 1;

        tokenTestSuite.mint(Tokens.DAI, address(pool), amount);

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (amount))
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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (1))
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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.enableToken, (link))
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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (1))
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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (512))
                })
            )
        );
    }

    /// @dev I:[FA-20]:decreaseDebt revets if less than minDebt
    function test_I_FA_20_decreaseDebt_revets_if_less_than_minDebt() public {
        (address creditAccount,) = _openTestCreditAccount();

        (uint128 minDebt,) = creditFacade.debtLimits();

        uint256 amount = DAI_ACCOUNT_AMOUNT - minDebt + 1;

        tokenTestSuite.mint(Tokens.DAI, address(pool), amount);

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (amount))
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
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (usdcToken, 512))
            })
        );

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        expectBalance(Tokens.USDC, creditAccount, 512);
        expectTokenIsEnabled(creditAccount, Tokens.USDC, true);
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
        emit StartMultiCall({creditAccount: creditAccount, caller: USER});

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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (usdcToken, USDC_EXCHANGE_AMOUNT))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (256))
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
        emit StartMultiCall({creditAccount: creditAccount, caller: USER});

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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (usdcToken, USDC_EXCHANGE_AMOUNT))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, 256)
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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, 256)
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, 256)
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
        emit StartMultiCall({creditAccount: creditAccount, caller: USER});

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.execute, (DUMB_CALLDATA)));

        vm.expectEmit(true, false, false, true);
        emit Execute(creditAccount, address(targetMock));

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

    /// @dev I:[FA-36]: checkAndUpdateBorrowedBlockLimit doesn't change block limit if maxDebtPerBlock = type(uint128).max
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

    /// @dev I:[FA-37]: checkAndUpdateBorrowedBlockLimit doesn't change block limit if maxDebtPerBlock = type(uint128).max
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
        //             callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_EXCHANGE_AMOUNT))
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
        //             callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_EXCHANGE_AMOUNT))
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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.enableToken, (usdcToken))
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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.enableToken, (usdcToken))
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
        // (address creditAccount,) = _openTestCreditAccount();

        // // AFTER OPENING CREDIT ACCOUNT

        // uint256 expectedTV = DAI_ACCOUNT_AMOUNT * 2;
        // uint256 expectedTWV = (DAI_ACCOUNT_AMOUNT * 2 * DEFAULT_UNDERLYING_LT) / PERCENTAGE_FACTOR;

        // uint256 expectedHF = (expectedTWV * PERCENTAGE_FACTOR) / DAI_ACCOUNT_AMOUNT;

        // // assertEq(creditFacade.calcCreditAccountHealthFactor(creditAccount), expectedHF, "Incorrect health factor");

        // // ADDING USDC AS COLLATERAL

        // addCollateral(Tokens.USDC, 10 * 10 ** 6);

        // expectedTV += 10 * WAD;
        // expectedTWV += (10 * WAD * 9000) / PERCENTAGE_FACTOR;

        // expectedHF = (expectedTWV * PERCENTAGE_FACTOR) / DAI_ACCOUNT_AMOUNT;

        // // assertEq(creditFacade.calcCreditAccountHealthFactor(creditAccount), expectedHF, "Incorrect health factor");

        // // 3 ASSET: 10 DAI + 10 USDC + 0.01 WETH (3200 $/ETH)
        // addCollateral(Tokens.WETH, WAD / 100);

        // expectedTV += (WAD / 100) * DAI_WETH_RATE;
        // expectedTWV += ((WAD / 100) * DAI_WETH_RATE * 8300) / PERCENTAGE_FACTOR;

        // expectedHF = (expectedTWV * PERCENTAGE_FACTOR) / DAI_ACCOUNT_AMOUNT;

        // // assertEq(creditFacade.calcCreditAccountHealthFactor(creditAccount), expectedHF, "Incorrect health factor");
    }

    /// CHECK IS ACCOUNT LIQUIDATABLE

    /// CHECK SLIPPAGE PROTECTION

    /// [TODO]: add new test

    /// @dev I:[FA-45]: revertIfGetLessThan during multicalls works correctly
    function test_I_FA_45_revertIfGetLessThan_works_correctly() public {
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

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.revertIfReceivedLessThan, (expectedBalances))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, expectedDAI))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (tokenLINK, expectedLINK))
                })
            )
        );

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(USER);
            vm.expectRevert(BalanceLessThanMinimumDesiredException.selector);

            creditFacade.multicall(
                creditAccount,
                MultiCallBuilder.build(
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.revertIfReceivedLessThan, (expectedBalances))
                    }),
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(
                            ICreditFacadeV3Multicall.addCollateral, (underlying, (i == 0) ? expectedDAI - 1 : expectedDAI)
                            )
                    }),
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(
                            ICreditFacadeV3Multicall.addCollateral, (tokenLINK, (i == 0) ? expectedLINK : expectedLINK - 1)
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
        expectedBalances[0] = Balance({token: underlying, balance: expectedDAI});

        (address creditAccount,) = _openTestCreditAccount();
        vm.prank(USER);
        vm.expectRevert(ExpectedBalancesAlreadySetException.selector);

        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.revertIfReceivedLessThan, (expectedBalances))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.revertIfReceivedLessThan, (expectedBalances))
                })
            )
        );
    }

    /// CREDIT FACADE WITH EXPIRATION

    /// @dev I:[FA-47]: liquidateExpiredCreditAccount should not work before the CreditFacadeV3 is expired
    function test_I_FA_47_liquidateExpiredCreditAccount_reverts_before_expiration() public expirableCase creditTest {
        // _setUp({
        //     _underlying: Tokens.DAI,
        //     withDegenNFT: false,
        //     withExpiration: true,
        //     supportQuotas: false,
        //     accountFactoryVer: 1
        // });

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
        // _setUp({
        //     _underlying: Tokens.DAI,
        //     withDegenNFT: false,
        //     withExpiration: true,
        //     supportQuotas: false,
        //     accountFactoryVer: 1
        // });
        // (address creditAccount, uint256 balance) = _openTestCreditAccount();

        // bytes memory DUMB_CALLDATA = adapterMock.dumbCallData();

        // MultiCall[] memory calls = MultiCallBuilder.build(
        //     MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.dumbCall, (0, 0))})
        // );

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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.enableToken, (token))
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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.enableToken, (token))
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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.disableToken, (token))
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

    //     vm.expectCall(blacklistHelper, abi.encodeCall(IWithdrawalManagerV3.isBlacklisted, (usdc, USER)));

    //     vm.expectCall(
    //         address(creditManager), abi.encodeCall(ICreditManagerV3.transferAccountOwnership, (USER, blacklistHelper))
    //     );

    //     vm.expectCall(blacklistHelper, abi.encodeCall(IWithdrawalManagerV3.addWithdrawal, (usdc, USER, expectedAmount)));

    //     vm.expectEmit(true, false, false, true);
    //     emit UnderlyingSentToBlacklistHelper(USER, expectedAmount);

    //     vm.prank(LIQUIDATOR);
    //     creditFacade.liquidateCreditAccount(USER, FRIEND, 0, true, MultiCallBuilder.build());

    //     assertEq(IWithdrawalManagerV3(blacklistHelper).claimable(usdc, USER), expectedAmount, "Incorrect claimable amount");

    //     vm.prank(USER);
    //     IWithdrawalManagerV3(blacklistHelper).claim(usdc, FRIEND2);

    //     assertEq(tokenTestSuite.balanceOf(Tokens.USDC, FRIEND2), expectedAmount, "Transferred amount incorrect");
    // }

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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.setFullCheckParams, (collateralHints, 10001))
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
