// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {ICreditAccountBase} from "../../../interfaces/ICreditAccountV3.sol";

import {
    ICreditManagerV3,
    ICreditManagerV3Events,
    ManageDebtAction,
    BOT_PERMISSIONS_SET_FLAG
} from "../../../interfaces/ICreditManagerV3.sol";
import {AllowanceAction} from "../../../interfaces/ICreditConfiguratorV3.sol";
import "../../../interfaces/ICreditFacadeV3.sol";

import {MultiCallBuilder} from "../../lib/MultiCallBuilder.sol";

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
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

/// @title CreditFacadeTest
/// @notice Designed for unit test purposes only
contract MultiCallIntegrationTest is
    Test,
    BalanceHelper,
    IntegrationTestHelper,
    ICreditManagerV3Events,
    ICreditFacadeV3Events
{
    /// @dev I:[MC-1]: multicall reverts if borrower has no account
    function test_I_MC_01_multicall_reverts_if_credit_account_not_exists() public creditTest {
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
    }

    /// @dev I:[MC-2]: multicall correctly executes addCollateral
    function test_I_MC_02_multicall_correctly_wraps_ETH() public creditTest {
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

    /// @dev I:[MC-3]: multicall reverts for unknown methods
    function test_I_MC_03_multicall_reverts_for_unknown_methods() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");

        vm.expectRevert(UnknownMethodException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount, MultiCallBuilder.build(MultiCall({target: address(creditFacade), callData: DUMB_CALLDATA}))
        );
    }

    /// @dev I:[MC-4]: multicall reverts on non-whilisted adapters
    function test_I_MC_04_multicall_reverts_for_non_whilisted_adapters() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");
        vm.expectRevert(TargetContractNotAllowedException.selector);

        vm.prank(USER);
        creditFacade.multicall(
            creditAccount, MultiCallBuilder.build(MultiCall({target: DUMB_ADDRESS, callData: DUMB_CALLDATA}))
        );
    }

    /// @dev I:[MC-5]: addCollateral executes function as expected
    function test_I_MC_05_addCollateral_executes_actions_as_expected() public creditTest {
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

    /// @dev I:[MC-6]: multicall addCollateral and oncreaseDebt works with creditFacade calls as expected
    function test_I_MC_06_multicall_addCollateral_and_increase_debt_works_with_creditFacade_calls_as_expected()
        public
        creditTest
    {
        (address creditAccount,) = _openTestCreditAccount();
        vm.roll(block.number + 1);

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
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 3, new uint256[](0), PERCENTAGE_FACTOR, false)
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

    /// @dev I:[MC-7]: multicall addCollateral and decreaseDebt works with creditFacade calls as expected
    function test_I_MC_07_multicall_addCollateral_and_decreaseDebt_works_with_creditFacade_calls_as_expected()
        public
        creditTest
    {
        (address creditAccount,) = _openTestCreditAccount();
        vm.roll(block.number + 1);

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
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 3, new uint256[](0), PERCENTAGE_FACTOR, false)
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

    /// @dev I:[MC-8]: multicall reverts for decrease opeartion after increase one
    function test_I_MC_08_multicall_reverts_for_decrease_opeartion_after_increase_one() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        vm.expectRevert(DebtUpdatedTwiceInOneBlockException.selector);

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

    /// @dev I:[MC-9]: multicall works with adapters calls as expected
    function test_I_MC_09_multicall_works_with_adapters_calls_as_expected() public withAdapterMock creditTest {
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
                ICreditManagerV3.fullCollateralCheck, (creditAccount, 1, new uint256[](0), PERCENTAGE_FACTOR, false)
            )
        );

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);
    }

    //
    // ENABLE TOKEN
    //

    /// @dev I:[MC-10]: enable token works as expected
    function test_I_MC_10_enable_token_is_correct() public creditTest {
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

    /// @dev I:[MC-11]: slippage check works correctly
    function test_I_MC_11_slippage_check_works_correctly() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        uint256 expectedDAI = 1000;
        uint256 expectedLINK = 2000;

        address tokenLINK = tokenTestSuite.addressOf(Tokens.LINK);

        BalanceDelta[] memory expectedBalances = new BalanceDelta[](2);
        expectedBalances[0] = BalanceDelta({token: underlying, amount: int256(expectedDAI)});

        expectedBalances[1] = BalanceDelta({token: tokenLINK, amount: int256(expectedLINK)});

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
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.storeExpectedBalances, (expectedBalances))
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
            vm.expectRevert(BalanceLessThanExpectedException.selector);

            creditFacade.multicall(
                creditAccount,
                MultiCallBuilder.build(
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.storeExpectedBalances, (expectedBalances))
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

    /// @dev I:[MC-12]: slippage check reverts if called incorrectly
    function test_I_MC_12_slippage_check_reverts_if_called_incorrectly() public creditTest {
        uint256 expectedDAI = 1000;

        BalanceDelta[] memory expectedBalances = new BalanceDelta[](1);
        expectedBalances[0] = BalanceDelta({token: underlying, amount: int256(expectedDAI)});

        (address creditAccount,) = _openTestCreditAccount();

        vm.expectRevert(ExpectedBalancesAlreadySetException.selector);
        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.storeExpectedBalances, (expectedBalances))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.storeExpectedBalances, (expectedBalances))
                })
            )
        );

        vm.expectRevert(ExpectedBalancesNotSetException.selector);
        vm.prank(USER);
        creditFacade.multicall(
            creditAccount,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.compareBalances, ())
                })
            )
        );
    }

    ///
    /// ENABLE TOKEN
    ///

    /// @dev I:[MC-13]: enableToken works as expected
    function test_I_MC_13_enableToken_works_as_expected() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        address token = tokenTestSuite.addressOf(Tokens.USDC);

        expectTokenIsEnabled(creditAccount, Tokens.USDC, false);

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

    /// @dev I:[MC-14]: disableToken works as expected in a multicall
    function test_I_MC_14_disableToken_works_as_expected_multicall() public creditTest {
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

    //
    // FULL CHECK PARAMS
    //

    /// @dev I:[MC-15]: setFullCheckParams performs correct full check after multicall
    function test_I_MC_15_setFullCheckParams_correctly_passes_params_to_fullCollateralCheck() public creditTest {
        (address creditAccount,) = _openTestCreditAccount();

        uint256[] memory collateralHints = new uint256[](1);
        collateralHints[0] = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDC));

        uint256 enabledTokensMap = creditManager.enabledTokensMaskOf(creditAccount);

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck, (creditAccount, enabledTokensMap, collateralHints, 10001, false)
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
}
