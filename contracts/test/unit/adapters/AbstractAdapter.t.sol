// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {
    CallerNotCreditFacadeException,
    ExternalCallCreditAccountNotSetException,
    TokenNotAllowedException,
    ZeroAddressException
} from "../../../interfaces/IExceptions.sol";
import {IPool4626} from "../../../interfaces/IPool4626.sol";

import {CreditConfig} from "../../config/CreditConfig.sol";
import {Tokens} from "../../config/Tokens.sol";

import {BalanceHelper} from "../../helpers/BalanceHelper.sol";
import {CreditFacadeTestHelper} from "../../helpers/CreditFacadeTestHelper.sol";

import {CONFIGURATOR, USER} from "../../lib/constants.sol";
import {DSTest} from "../../lib/test.sol";

import {AdapterMock} from "../../mocks/adapters/AdapterMock.sol";
import {TargetContractMock} from "@gearbox-protocol/core-v2/contracts/test/mocks/adapters/TargetContractMock.sol";

import {CreditFacadeTestSuite} from "../../suites/CreditFacadeTestSuite.sol";
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";

/// @title AbstractAdapterTest
/// @notice Designed for unit test purposes only
contract AbstractAdapterTest is DSTest, BalanceHelper, CreditFacadeTestHelper {
    TargetContractMock targetMock;
    AdapterMock adapterMock;

    address usdc;
    address dai;

    function setUp() public {
        tokenTestSuite = new TokensTestSuite();

        CreditConfig creditConfig = new CreditConfig(
            tokenTestSuite,
            Tokens.DAI
        );

        cft = new CreditFacadeTestSuite(creditConfig);

        underlying = tokenTestSuite.addressOf(Tokens.DAI);
        creditManager = cft.creditManager();
        creditFacade = cft.creditFacade();
        creditConfigurator = cft.creditConfigurator();

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

    /// ----- ///
    /// TESTS ///
    /// ----- ///

    /// @notice [AA-1]: Constructor reverts when passed zero-address as credit manager or target contract
    function test_AA_01_constructor_reverts_on_zero_address() public {
        evm.expectRevert();
        new AdapterMock(address(0), address(0));

        evm.expectRevert(ZeroAddressException.selector);
        new AdapterMock(address(creditManager), address(0));
    }

    /// @notice [AA-2]: Constructor sets correct values
    function test_AA_02_constructor_sets_correct_values() public {
        assertEq(address(adapterMock.creditManager()), address(creditManager), "Incorrect credit manager");

        assertEq(
            address(adapterMock.addressProvider()),
            address(IPool4626(creditManager.pool()).addressProvider()),
            "Incorrect address provider"
        );

        assertEq(adapterMock.targetContract(), address(targetMock), "Incorrect target contract");
    }

    /// @notice [AA-3]: `creditFacadeOnly` functions revert if called not by the credit facade
    function test_AA_03_creditFacadeOnly_function_reverts_if_called_not_by_credit_facade() public {
        evm.expectRevert(CallerNotCreditFacadeException.selector);
        evm.prank(USER);
        adapterMock.dumbCall(0, 0);
    }

    /// @notice [AA-4]: AbstractAdapter uses correct credit account
    function test_AA_04_adapter_uses_correct_credit_account() public {
        evm.expectRevert(ExternalCallCreditAccountNotSetException.selector);
        evm.prank(address(creditFacade));
        adapterMock.creditAccount();

        address creditAccount = _openExternalCallCreditAccount();
        assertEq(adapterMock.creditAccount(), creditAccount);
    }

    /// @notice [AA-5]: `_getMaskOrRevert` works correctly
    function test_AA_05_getMaskOrRevert_works_correctly() public {
        evm.expectRevert(TokenNotAllowedException.selector);
        adapterMock.getMaskOrRevert(address(0xdead));

        assertEq(
            adapterMock.getMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI)),
            creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI))
        );
    }

    /// @notice [AA-6]: `_approveToken` correctly passes parameters to the credit manager
    function test_AA_06_approveToken_correctly_passes_to_credit_manager() public {
        _openExternalCallCreditAccount();

        evm.expectCall(address(creditManager), abi.encodeCall(creditManager.approveCreditAccount, (usdc, 10)));
        evm.prank(USER);
        adapterMock.approveToken(usdc, 10);
    }

    /// @notice [AA-7]: `_execute` correctly passes parameters to the credit manager
    function test_AA_07_execute_correctly_passes_to_credit_manager() public {
        _openExternalCallCreditAccount();

        bytes memory callData = adapterMock.dumbCallData();

        evm.expectCall(address(creditManager), abi.encodeCall(creditManager.executeOrder, (callData)));
        evm.prank(USER);
        adapterMock.execute(callData);
    }

    /// @notice [AA-8]: `_executeSwapNoApprove` works correctly
    function test_AA_08_executeSwapNoApprove_works_correctly() public {
        address creditAccount = _openExternalCallCreditAccount();

        bytes memory callData = adapterMock.dumbCallData();
        for (uint256 dt = 0; dt < 2; ++dt) {
            bool disableTokenIn = dt == 1;

            evm.expectCall(address(creditManager), abi.encodeCall(creditManager.executeOrder, (callData)));

            evm.prank(USER);
            (uint256 tokensToEnable, uint256 tokensToDisable,) =
                adapterMock.executeSwapNoApprove(usdc, dai, callData, disableTokenIn);

            expectAllowance(usdc, creditAccount, address(targetMock), 0);
            assertEq(tokensToEnable, creditManager.getTokenMaskOrRevert(dai), "Incorrect tokensToEnable");
            if (disableTokenIn) {
                assertEq(tokensToDisable, creditManager.getTokenMaskOrRevert(usdc), "Incorrect tokensToDisable");
            }
        }
    }

    /// @notice [AA-9]: `_executeSwapSafeApprove` works correctly
    function test_AA_09_executeSwapSafeApprove_works_correctly() public {
        address creditAccount = _openExternalCallCreditAccount();

        bytes memory callData = adapterMock.dumbCallData();
        for (uint256 dt = 0; dt < 2; ++dt) {
            bool disableTokenIn = dt == 1;

            evm.expectCall(
                address(creditManager), abi.encodeCall(creditManager.approveCreditAccount, (usdc, type(uint256).max))
            );
            evm.expectCall(address(creditManager), abi.encodeCall(creditManager.executeOrder, (callData)));
            evm.expectCall(address(creditManager), abi.encodeCall(creditManager.approveCreditAccount, (usdc, 1)));

            evm.prank(USER);
            (uint256 tokensToEnable, uint256 tokensToDisable,) =
                adapterMock.executeSwapSafeApprove(usdc, dai, callData, disableTokenIn);

            expectAllowance(usdc, creditAccount, address(targetMock), 1);
            assertEq(tokensToEnable, creditManager.getTokenMaskOrRevert(dai), "Incorrect tokensToEnable");
            if (disableTokenIn) {
                assertEq(tokensToDisable, creditManager.getTokenMaskOrRevert(usdc), "Incorrect tokensToDisable");
            }
        }
    }

    /// @notice [AA-10]: `_executeSwap{No|Safe}Approve` reverts if `tokenIn` or `tokenOut` are not collateral tokens
    function test_AA_10_executeSwap_reverts_if_tokenIn_or_tokenOut_are_not_collateral_tokens() public {
        _openExternalCallCreditAccount();

        address token = address(0xdead);
        bytes memory callData = adapterMock.dumbCallData();
        for (uint256 ti; ti < 2; ++ti) {
            (address tokenIn, address tokenOut) = (ti == 1 ? token : dai, ti == 1 ? dai : token);
            for (uint256 dt; dt < 2; ++dt) {
                bool disableTokenIn = dt == 1;
                for (uint256 sa; sa < 2; ++sa) {
                    evm.expectRevert(TokenNotAllowedException.selector);
                    evm.prank(USER);
                    if (sa == 1) {
                        adapterMock.executeSwapSafeApprove(tokenIn, tokenOut, callData, disableTokenIn);
                    } else {
                        adapterMock.executeSwapNoApprove(tokenIn, tokenOut, callData, disableTokenIn);
                    }
                }
            }
        }
    }

    /// ------- ///
    /// HELPERS ///
    /// ------- ///

    function _openExternalCallCreditAccount() internal returns (address creditAccount) {
        (creditAccount,) = _openTestCreditAccount();
        evm.prank(address(creditFacade));
        creditManager.setCaForExternalCall(creditAccount);
    }
}
