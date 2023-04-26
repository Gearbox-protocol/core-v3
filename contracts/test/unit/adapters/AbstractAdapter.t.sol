// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";
import {CreditFacadeV3} from "../../../credit/CreditFacadeV3.sol";

import {IAddressProvider} from "@gearbox-protocol/core-v2/contracts/interfaces/IAddressProvider.sol";
import {ICreditAccount} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditAccount.sol";
import {ICreditFacade, MultiCall} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditFacade.sol";
import {ICreditManagerV3, ICreditManagerV3Events} from "../../../interfaces/ICreditManagerV3.sol";
import {ICreditFacadeEvents} from "../../../interfaces/ICreditFacade.sol";
import {IPool4626} from "../../../interfaces/IPool4626.sol";

import "../../lib/constants.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";
import {CreditFacadeTestHelper} from "../../helpers/CreditFacadeTestHelper.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// MOCKS
import {AdapterMock} from "../../mocks/adapters/AdapterMock.sol";
import {TargetContractMock} from "@gearbox-protocol/core-v2/contracts/test/mocks/adapters/TargetContractMock.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";
import {CreditFacadeTestSuite} from "../../suites/CreditFacadeTestSuite.sol";
import {CreditConfig} from "../../config/CreditConfig.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

uint256 constant WETH_TEST_AMOUNT = 5 * WAD;
uint16 constant REFERRAL_CODE = 23;

/// @title AbstractAdapterTest
/// @notice Designed for unit test purposes only
contract AbstractAdapterTest is
    DSTest,
    BalanceHelper,
    CreditFacadeTestHelper,
    ICreditManagerV3Events,
    ICreditFacadeEvents
{
    AccountFactory accountFactory;

    TargetContractMock targetMock;
    AdapterMock adapterMock;

    address usdc;
    address dai;

    function setUp() public {
        tokenTestSuite = new TokensTestSuite();
        tokenTestSuite.topUpWETH{value: 100 * WAD}();

        CreditConfig creditConfig = new CreditConfig(
            tokenTestSuite,
            Tokens.DAI
        );

        cft = new CreditFacadeTestSuite(creditConfig);

        underlying = tokenTestSuite.addressOf(Tokens.DAI);
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

        usdc = tokenTestSuite.addressOf(Tokens.USDC);
        dai = tokenTestSuite.addressOf(Tokens.DAI);
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev [AA-1]: AbstractAdapter constructor sets correct values
    function test_AA_01_constructor_sets_correct_values() public {
        assertEq(address(adapterMock.creditManager()), address(creditManager), "Incorrect credit manager");

        assertEq(
            address(adapterMock.addressProvider()),
            address(IPool4626(creditManager.pool()).addressProvider()),
            "Incorrect address provider"
        );

        assertEq(adapterMock.targetContract(), address(targetMock), "Incorrect target contract");
    }

    /// @dev [AA-2]: AbstractAdapter constructor reverts when passed zero-address as target contract
    function test_AA_02_constructor_reverts_on_zero_address() public {
        evm.expectRevert();
        new AdapterMock(address(0), address(0));

        evm.expectRevert(ZeroAddressException.selector);
        new AdapterMock(address(creditManager), address(0));
    }

    /// @dev [AA-4]: AbstractAdapter uses correct credit account
    function test_AA_04_adapter_uses_correct_credit_account() public {
        (address creditAccount,) = _openTestCreditAccount();

        evm.prank(address(creditFacade));
        creditManager.transferAccountOwnership(USER, address(creditFacade));
        assertEq(adapterMock.creditAccount(), creditAccount);
    }

    /// @dev [AA-5]: AbstractAdapter creditFacadeOnly functions revert if called not from credit facade
    function test_AA_05_creditFacadeOnly_function_reverts_if_called_not_from_credit_facade() public {
        bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");

        evm.prank(USER);
        evm.expectRevert(CallerNotCreditFacadeException.selector);
        adapterMock.execute(DUMB_CALLDATA);
    }

    /// @dev [AA-6]: AbstractAdapter _getMaskOrRevert works correctly
    function test_AA_06_getMaskOrRevert_works_correctly() public {
        assertEq(
            adapterMock.getMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI)),
            creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI))
        );

        evm.expectRevert(TokenNotAllowedException.selector);
        adapterMock.getMaskOrRevert(address(0xdead));
    }

    /// @dev [AA-7]: AbstractAdapter functions revert if user has no credit account
    function test_AA_07_adapter_reverts_if_user_has_no_credit_account() public {
        evm.expectRevert(HasNoOpenedAccountException.selector);
        adapterMock.creditAccount();

        bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");
        evm.prank(USER);
        evm.expectRevert(HasNoOpenedAccountException.selector);
        creditFacade.multicall(
            multicallBuilder(
                MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.execute, (DUMB_CALLDATA))})
            )
        );

        evm.prank(USER);
        evm.expectRevert(HasNoOpenedAccountException.selector);
        creditFacade.multicall(
            multicallBuilder(
                MultiCall({target: address(adapterMock), callData: abi.encodeCall(AdapterMock.approveToken, (usdc, 1))})
            )
        );

        // evm.prank(USER);
        // evm.expectRevert(HasNoOpenedAccountException.selector);
        // creditFacade.multicall(
        //     multicallBuilder(
        //         MultiCall({
        //             target: address(adapterMock),
        //             callData: abi.encodeCall(AdapterMock.changeEnabledTokens, (0, 0))
        //         })
        //     )
        // );

        for (uint256 dt; dt < 2; ++dt) {
            evm.prank(USER);
            evm.expectRevert(HasNoOpenedAccountException.selector);
            creditFacade.multicall(
                multicallBuilder(
                    MultiCall({
                        target: address(adapterMock),
                        callData: abi.encodeCall(AdapterMock.executeSwapNoApprove, (usdc, dai, DUMB_CALLDATA, dt == 1))
                    })
                )
            );

            evm.prank(USER);
            evm.expectRevert(HasNoOpenedAccountException.selector);
            creditFacade.multicall(
                multicallBuilder(
                    MultiCall({
                        target: address(adapterMock),
                        callData: abi.encodeCall(AdapterMock.executeSwapSafeApprove, (usdc, dai, DUMB_CALLDATA, dt == 1))
                    })
                )
            );
        }
    }

    /// @dev [AA-8]: _approveToken correctly passes parameters to CreditManagerV3
    function test_AA_08_approveToken_correctly_passes_to_credit_manager() public {
        _openTestCreditAccount();

        evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.approveCreditAccount, (usdc, 10)));

        evm.prank(USER);
        creditFacade.multicall(
            multicallBuilder(
                MultiCall({target: address(adapterMock), callData: abi.encodeCall(adapterMock.approveToken, (usdc, 10))})
            )
        );
    }

    /// @dev [AA-12]: _execute correctly passes parameters to CreditManagerV3
    function test_AA_12_execute_correctly_passes_to_credit_manager() public {
        _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");

        evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.executeOrder, (DUMB_CALLDATA)));

        evm.prank(USER);
        creditFacade.multicall(
            multicallBuilder(
                MultiCall({target: address(adapterMock), callData: abi.encodeCall(adapterMock.execute, DUMB_CALLDATA)})
            )
        );
    }

    /// @dev [AA-13]: _executeSwapNoApprove correctly passes parameters to CreditManagerV3
    function test_AA_13_executeSwapNoApprove_correctly_passes_to_credit_manager() public {
        _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");

        for (uint256 dt = 0; dt < 2; ++dt) {
            evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.executeOrder, (DUMB_CALLDATA)));

            // if (dt == 1) {
            //     evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.disableToken, (usdc)));
            // }

            // evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.checkAndEnableToken, (dai)));

            evm.prank(USER);
            creditFacade.multicall(
                multicallBuilder(
                    MultiCall({
                        target: address(adapterMock),
                        callData: abi.encodeCall(adapterMock.executeSwapNoApprove, (usdc, dai, DUMB_CALLDATA, dt == 1))
                    })
                )
            );
        }
    }

    /// @dev [AA-14]: _executeSwapSafeApprove correctly passes parameters to CreditManagerV3 and sets allowance
    function test_AA_14_executeSwapSafeApprove_correctly_passes_to_credit_manager() public {
        (address ca,) = _openTestCreditAccount();

        bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");

        for (uint256 dt = 0; dt < 2; ++dt) {
            evm.expectCall(
                address(creditManager), abi.encodeCall(ICreditManagerV3.approveCreditAccount, (usdc, type(uint256).max))
            );

            evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.executeOrder, (DUMB_CALLDATA)));

            evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.approveCreditAccount, (usdc, 1)));

            // if (dt == 1) {
            //     evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.disableToken, (usdc)));
            // }

            // evm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.checkAndEnableToken, (dai)));

            evm.prank(USER);
            creditFacade.multicall(
                multicallBuilder(
                    MultiCall({
                        target: address(adapterMock),
                        callData: abi.encodeCall(adapterMock.executeSwapSafeApprove, (usdc, dai, DUMB_CALLDATA, dt == 1))
                    })
                )
            );

            assertEq(IERC20(usdc).allowance(ca, address(targetMock)), 1, "Incorrect allowance set");
        }
    }

    /// TODO: UPDATE IF NEEDED
    // /// @dev [AA-15]: _executeSwapNoApprove reverts if tokenIn or tokenOut are not allowed
    // function test_AA_15_executeSwap_reverts_if_tokenIn_or_tokenOut_are_not_allowed() public {
    //     _openTestCreditAccount();

    //     address TOKEN = address(0xdead);
    //     bytes memory DUMB_CALLDATA = abi.encodeWithSignature("hello(string)", "world");

    //     // ti == 0 => bad tokenOut, ti == 1 => bad tokenIn
    //     // sa == 0 => no approve, sa == 1 => safe approve
    //     for (uint256 ti; ti < 2; ++ti) {
    //         for (uint256 sa; sa < 2; ++sa) {
    //             bytes memory callData;
    //             if (sa == 1) {
    //                 callData = abi.encodeCall(
    //                     adapterMock.executeSwapSafeApprove,
    //                     (ti == 1 ? TOKEN : dai, ti == 1 ? dai : TOKEN, DUMB_CALLDATA, false)
    //                 );
    //             } else {
    //                 callData = abi.encodeCall(
    //                     adapterMock.executeSwapNoApprove,
    //                     (ti == 1 ? TOKEN : dai, ti == 1 ? dai : TOKEN, DUMB_CALLDATA, false)
    //                 );
    //             }

    //             evm.prank(USER);
    //             evm.expectRevert(TokenNotAllowedException.selector);
    //             creditFacade.multicall(multicallBuilder(MultiCall({target: address(adapterMock), callData: callData})));
    //         }
    //     }
    // }
}
