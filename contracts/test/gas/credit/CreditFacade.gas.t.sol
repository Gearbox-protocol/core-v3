// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";

import {
    ICreditFacadeV3, ICreditFacadeV3Multicall, ICreditFacadeV3Events
} from "../../../interfaces/ICreditFacadeV3.sol";
import {ICreditManagerV3, ICreditManagerV3Events, ClosureAction} from "../../../interfaces/ICreditManagerV3.sol";
import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";

// DATA
import {MultiCall, MultiCallOps} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";

// CONSTANTS

// TESTS

import "../../lib/constants.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";
import {CreditFacadeTestHelper} from "../../helpers/CreditFacadeTestHelper.sol";

// EXCEPTIONS

// MOCKS
import {AdapterMock} from "../../mocks/core/AdapterMock.sol";
import {TargetContractMock} from "../../mocks/core/TargetContractMock.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";
import {CreditFacadeTestSuite} from "../../suites/CreditFacadeTestSuite.sol";
import {CreditConfig} from "../../config/CreditConfig.sol";

uint256 constant WETH_TEST_AMOUNT = 5 * WAD;
uint16 constant REFERRAL_CODE = 23;

/// @title CreditFacadeTest
/// @notice Designed for unit test purposes only
contract CreditFacadeGasTest is
    Test,
    BalanceHelper,
    CreditFacadeTestHelper,
    ICreditManagerV3Events,
    ICreditFacadeV3Events
{
    // function setUp() public {
    //     _setUp(Tokens.DAI, true, false, false);
    // }

    // function _setUp(Tokens _underlying, bool supportQuotas, bool withDegenNFT, bool withExpiration) internal {
    //     tokenTestSuite = new TokensTestSuite();
    //     tokenTestSuite.topUpWETH{value: 100 * WAD}();

    //     CreditConfig creditConfig = new CreditConfig(
    //         tokenTestSuite,
    //         _underlying
    //     );

    //     cft = new CreditFacadeTestSuite({ _creditConfig: creditConfig,
    //      _supportQuotas: supportQuotas,
    //      withDegenNFT: withDegenNFT,
    //      withExpiration:  withExpiration,
    //      accountFactoryVer: 1});

    //     // cft.testFacadeWithQuotas();

    //     underlying = tokenTestSuite.addressOf(_underlying);
    //     creditManager = cft.creditManager();
    //     creditFacade = cft.creditFacade();
    //     creditConfigurator = cft.creditConfigurator();

    //     accountFactory = cft.af();

    //     targetMock = new TargetContractMock();
    //     adapterMock = new AdapterMock(
    //         address(creditManager),
    //         address(targetMock)
    //     );

    //     vm.prank(CONFIGURATOR);
    //     creditConfigurator.allowAdapter(address(adapterMock));

    //     vm.label(address(adapterMock), "AdapterMock");
    //     vm.label(address(targetMock), "TargetContractMock");
    // }

    function _zeroAllLTs() internal {
        uint256 collateralTokensCount = creditManager.collateralTokensCount();

        for (uint256 i = 0; i < collateralTokensCount; ++i) {
            (address token,) = creditManager.collateralTokenByMask(1 << i);

            vm.prank(address(creditConfigurator));
            CreditManagerV3(address(creditManager)).setCollateralTokenData(token, 0, 0, type(uint40).max, 0);
        }
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev G:[FA-2]: openCreditAccount with just adding collateral
    function test_G_FA_02_openCreditAccountMulticall_gas_estimate_1() public {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = new MultiCall[](1);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
                )
        });

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - opening an account with just adding collateral: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-3]: openCreditAccount with adding collateral and single swap
    function test_G_FA_03_openCreditAccountMulticall_gas_estimate_2() public {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = new MultiCall[](2);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
                )
        });

        calls[1] = MultiCall({
            target: address(adapterMock),
            callData: abi.encodeCall(
                AdapterMock.executeSwapSafeApprove,
                (tokenTestSuite.addressOf(Tokens.DAI), tokenTestSuite.addressOf(Tokens.USDC), "", false)
                )
        });

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(
            string(abi.encodePacked("Gas spent - opening an account with adding collateral and executing one swap: "))
        );
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-4]: openCreditAccount with adding collateral and two swaps
    function test_G_FA_04_openCreditAccountMulticall_gas_estimate_3() public {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = new MultiCall[](3);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
                )
        });

        calls[1] = MultiCall({
            target: address(adapterMock),
            callData: abi.encodeCall(
                AdapterMock.executeSwapSafeApprove,
                (tokenTestSuite.addressOf(Tokens.DAI), tokenTestSuite.addressOf(Tokens.USDC), "", false)
                )
        });

        calls[2] = MultiCall({
            target: address(adapterMock),
            callData: abi.encodeCall(
                AdapterMock.executeSwapSafeApprove,
                (tokenTestSuite.addressOf(Tokens.USDC), tokenTestSuite.addressOf(Tokens.LINK), "", false)
                )
        });

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(
            string(abi.encodePacked("Gas spent - opening an account with adding collateral and executing two swaps: "))
        );
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-5]: openCreditAccount with adding quoted collateral and updating quota
    function test_G_FA_05_openCreditAccountMulticall_gas_estimate_4() public {
        vm.startPrank(CONFIGURATOR);
        cft.gauge().addQuotaToken(tokenTestSuite.addressOf(Tokens.LINK), 500, 500);
        cft.poolQuotaKeeper().setTokenLimit(tokenTestSuite.addressOf(Tokens.LINK), type(uint96).max);
        cft.gauge().updateEpoch();
        creditConfigurator.makeTokenQuoted(tokenTestSuite.addressOf(Tokens.LINK));

        cft.gauge().addQuotaToken(tokenTestSuite.addressOf(Tokens.USDC), 500, 500);
        cft.poolQuotaKeeper().setTokenLimit(tokenTestSuite.addressOf(Tokens.USDC), type(uint96).max);
        cft.gauge().updateEpoch();
        creditConfigurator.makeTokenQuoted(tokenTestSuite.addressOf(Tokens.USDC));

        cft.gauge().addQuotaToken(tokenTestSuite.addressOf(Tokens.WETH), 500, 500);
        cft.poolQuotaKeeper().setTokenLimit(tokenTestSuite.addressOf(Tokens.WETH), type(uint96).max);
        cft.gauge().updateEpoch();
        creditConfigurator.makeTokenQuoted(tokenTestSuite.addressOf(Tokens.WETH));
        vm.stopPrank();

        tokenTestSuite.mint(Tokens.LINK, USER, LINK_ACCOUNT_AMOUNT);
        tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

        MultiCall[] memory calls = new MultiCall[](4);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), LINK_ACCOUNT_AMOUNT)
                )
        });

        calls[1] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.updateQuota,
                (tokenTestSuite.addressOf(Tokens.LINK), int96(int256(LINK_ACCOUNT_AMOUNT)), 0)
                )
        });

        calls[2] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.updateQuota,
                (tokenTestSuite.addressOf(Tokens.WETH), int96(int256(LINK_ACCOUNT_AMOUNT)), 0)
                )
        });

        calls[3] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.updateQuota,
                (tokenTestSuite.addressOf(Tokens.LINK), int96(int256(LINK_ACCOUNT_AMOUNT)), 0)
                )
        });

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent array: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-6]: openCreditAccount with swapping and updating quota
    function test_G_FA_06_openCreditAccountMulticall_gas_estimate_5() public {
        vm.startPrank(CONFIGURATOR);
        cft.gauge().addQuotaToken(tokenTestSuite.addressOf(Tokens.LINK), 500, 500);
        cft.poolQuotaKeeper().setTokenLimit(tokenTestSuite.addressOf(Tokens.LINK), type(uint96).max);
        cft.gauge().updateEpoch();
        creditConfigurator.makeTokenQuoted(tokenTestSuite.addressOf(Tokens.LINK));
        vm.stopPrank();

        tokenTestSuite.mint(Tokens.LINK, USER, LINK_ACCOUNT_AMOUNT);
        tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

        MultiCall[] memory calls = new MultiCall[](3);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), LINK_ACCOUNT_AMOUNT)
                )
        });

        calls[1] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.updateQuota,
                (tokenTestSuite.addressOf(Tokens.LINK), int96(int256(LINK_ACCOUNT_AMOUNT)), 0)
                )
        });

        calls[2] = MultiCall({
            target: address(adapterMock),
            callData: abi.encodeCall(
                AdapterMock.executeSwapSafeApprove,
                (tokenTestSuite.addressOf(Tokens.DAI), tokenTestSuite.addressOf(Tokens.LINK), "", false)
                )
        });

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(
            string(abi.encodePacked("Gas spent - opening an account with swapping into quoted collateral: "))
        );
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-7]: multicall with increaseDebt
    function test_G_FA_07_increaseDebt_gas_estimate_1() public {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = new MultiCall[](1);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
                )
        });

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
        });

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - multicall with increaseDebt: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-8]: multicall with decreaseDebt
    function test_G_FA_08_decreaseDebt_gas_estimate_1() public {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = new MultiCall[](1);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
                )
        });

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (DAI_ACCOUNT_AMOUNT / 2))
        });

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - multicall with decreaseDebt: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-9]: multicall with decreaseDebt and active quota interest
    function test_G_FA_09_decreaseDebt_gas_estimate_2() public {
        vm.startPrank(CONFIGURATOR);
        cft.gauge().addQuotaToken(tokenTestSuite.addressOf(Tokens.LINK), 500, 500);
        cft.poolQuotaKeeper().setTokenLimit(tokenTestSuite.addressOf(Tokens.LINK), type(uint96).max);
        cft.gauge().updateEpoch();
        creditConfigurator.makeTokenQuoted(tokenTestSuite.addressOf(Tokens.LINK));
        vm.stopPrank();

        tokenTestSuite.mint(Tokens.LINK, USER, LINK_ACCOUNT_AMOUNT);
        tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

        MultiCall[] memory calls = new MultiCall[](2);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), LINK_ACCOUNT_AMOUNT)
                )
        });

        calls[1] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.updateQuota,
                (tokenTestSuite.addressOf(Tokens.LINK), int96(int256(LINK_ACCOUNT_AMOUNT)), 0)
                )
        });

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        vm.warp(block.timestamp + 30 days);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (DAI_ACCOUNT_AMOUNT / 2))
        });

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - multicall with decreaseDebt with quoted tokens: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-10]: multicall with enableToken
    function test_G_FA_10_enableToken_gas_estimate_1() public {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = new MultiCall[](1);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
                )
        });

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.enableToken, (tokenTestSuite.addressOf(Tokens.LINK)))
        });

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - multicall with enableToken: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-11]: multicall with disableToken
    function test_G_FA_11_disableToken_gas_estimate_1() public {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = new MultiCall[](2);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
                )
        });

        calls[1] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.enableToken, (tokenTestSuite.addressOf(Tokens.LINK)))
        });

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.disableToken, (tokenTestSuite.addressOf(Tokens.LINK)))
        });

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - multicall with disableToken: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-12]: multicall with a single swap
    function test_G_FA_12_multicall_gas_estimate_1() public {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = new MultiCall[](1);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
                )
        });

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        calls[0] = MultiCall({
            target: address(adapterMock),
            callData: abi.encodeCall(
                AdapterMock.executeSwapSafeApprove,
                (tokenTestSuite.addressOf(Tokens.DAI), tokenTestSuite.addressOf(Tokens.LINK), "", false)
                )
        });

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - multicall with a single swap: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-12A]: multicall with a single swap
    function test_G_FA_12A_multicall_gas_estimate_1A() public {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = new MultiCall[](1);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
                )
        });

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        calls = new MultiCall[](2);

        calls[0] = MultiCall({
            target: address(adapterMock),
            callData: abi.encodeCall(
                AdapterMock.executeSwapSafeApprove,
                (tokenTestSuite.addressOf(Tokens.DAI), tokenTestSuite.addressOf(Tokens.LINK), "", false)
                )
        });

        calls[1] = MultiCall({
            target: address(adapterMock),
            callData: abi.encodeCall(
                AdapterMock.executeSwapSafeApprove,
                (tokenTestSuite.addressOf(Tokens.LINK), tokenTestSuite.addressOf(Tokens.USDC), "", true)
                )
        });

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - multicall with two swaps: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-13]: multicall with a single swap into quoted token
    function test_G_FA_13_multicall_gas_estimate_2() public {
        vm.startPrank(CONFIGURATOR);
        cft.gauge().addQuotaToken(tokenTestSuite.addressOf(Tokens.LINK), 500, 500);
        cft.poolQuotaKeeper().setTokenLimit(tokenTestSuite.addressOf(Tokens.LINK), type(uint96).max);
        cft.gauge().updateEpoch();
        creditConfigurator.makeTokenQuoted(tokenTestSuite.addressOf(Tokens.LINK));
        vm.stopPrank();

        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = new MultiCall[](1);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
                )
        });

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        tokenTestSuite.burn(Tokens.DAI, creditAccount, DAI_ACCOUNT_AMOUNT * 2);
        tokenTestSuite.mint(Tokens.LINK, creditAccount, LINK_ACCOUNT_AMOUNT * 3);

        calls = new MultiCall[](2);

        calls[0] = MultiCall({
            target: address(adapterMock),
            callData: abi.encodeCall(
                AdapterMock.executeSwapSafeApprove,
                (tokenTestSuite.addressOf(Tokens.DAI), tokenTestSuite.addressOf(Tokens.LINK), "", true)
                )
        });

        calls[1] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.updateQuota,
                (tokenTestSuite.addressOf(Tokens.LINK), int96(int256(LINK_ACCOUNT_AMOUNT * 3)), 0)
                )
        });

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.multicall(creditAccount, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(
            string(
                abi.encodePacked(
                    "Gas spent - multicall with a single swap into quoted collateral and updating quotas: "
                )
            )
        );
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-14]: closeCreditAccount with underlying only
    function test_G_FA_14_closeCreditAccount_gas_estimate_1() public {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = new MultiCall[](1);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
                )
        });

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        vm.roll(block.number + 1);

        calls = new MultiCall[](0);

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.closeCreditAccount(creditAccount, USER, 0, false, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - closeCreditAccount with underlying only: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-15]: closeCreditAccount with two tokens
    function test_G_FA_15_closeCreditAccount_gas_estimate_2() public {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);
        tokenTestSuite.mint(Tokens.LINK, USER, LINK_ACCOUNT_AMOUNT);
        tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

        MultiCall[] memory calls = new MultiCall[](2);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
                )
        });

        calls[1] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), LINK_ACCOUNT_AMOUNT)
                )
        });

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        vm.roll(block.number + 1);

        calls = new MultiCall[](0);

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.closeCreditAccount(creditAccount, USER, 0, false, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - closeCreditAccount with 2 tokens: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-16]: closeCreditAccount with 2 tokens and active quota interest
    function test_G_FA_16_closeCreditAccount_gas_estimate_3() public {
        vm.startPrank(CONFIGURATOR);
        cft.gauge().addQuotaToken(tokenTestSuite.addressOf(Tokens.LINK), 500, 500);
        cft.poolQuotaKeeper().setTokenLimit(tokenTestSuite.addressOf(Tokens.LINK), type(uint96).max);
        cft.gauge().updateEpoch();
        creditConfigurator.makeTokenQuoted(tokenTestSuite.addressOf(Tokens.LINK));
        vm.stopPrank();

        tokenTestSuite.mint(Tokens.LINK, USER, LINK_ACCOUNT_AMOUNT);
        tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

        MultiCall[] memory calls = new MultiCall[](2);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), LINK_ACCOUNT_AMOUNT)
                )
        });

        calls[1] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.updateQuota,
                (tokenTestSuite.addressOf(Tokens.LINK), int96(int256(LINK_ACCOUNT_AMOUNT)), 0)
                )
        });

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        vm.roll(block.number + 1);

        vm.warp(block.timestamp + 30 days);

        calls = new MultiCall[](0);

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.closeCreditAccount(creditAccount, USER, 0, false, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - closeCreditAccount with underlying and quoted token: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-17]: closeCreditAccount with one swap
    function test_G_FA_17_closeCreditAccount_gas_estimate_4() public {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = new MultiCall[](1);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
                )
        });

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        vm.roll(block.number + 1);

        calls[0] = MultiCall({
            target: address(adapterMock),
            callData: abi.encodeCall(
                AdapterMock.executeSwapSafeApprove,
                (tokenTestSuite.addressOf(Tokens.LINK), tokenTestSuite.addressOf(Tokens.DAI), "", true)
                )
        });

        uint256 gasBefore = gasleft();

        vm.prank(USER);
        creditFacade.closeCreditAccount(creditAccount, USER, 0, false, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - closeCreditAccount with one swap: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-18]: liquidateCreditAccount with underlying only
    function test_G_FA_18_liquidateCreditAccount_gas_estimate_1() public {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

        MultiCall[] memory calls = new MultiCall[](1);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
                )
        });

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        vm.roll(block.number + 1);

        _zeroAllLTs();

        calls = new MultiCall[](0);

        uint256 gasBefore = gasleft();

        vm.prank(FRIEND);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 0, false, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - liquidateCreditAccount with underlying only: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-19]: liquidateCreditAccount with two tokens
    function test_G_FA_19_liquidateCreditAccount_gas_estimate_2() public {
        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);
        tokenTestSuite.mint(Tokens.LINK, USER, LINK_ACCOUNT_AMOUNT);
        tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

        tokenTestSuite.mint(Tokens.DAI, FRIEND, DAI_ACCOUNT_AMOUNT * 100);
        tokenTestSuite.approve(Tokens.DAI, FRIEND, address(creditManager));

        MultiCall[] memory calls = new MultiCall[](2);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
                )
        });

        calls[1] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), LINK_ACCOUNT_AMOUNT)
                )
        });

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        vm.roll(block.number + 1);

        _zeroAllLTs();

        calls = new MultiCall[](0);

        uint256 gasBefore = gasleft();

        vm.prank(FRIEND);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 0, false, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(string(abi.encodePacked("Gas spent - liquidateCreditAccount with 2 tokens: ")));
        emit log_uint(gasSpent);
    }

    /// @dev G:[FA-20]: liquidateCreditAccount with 2 tokens and active quota interest
    function test_G_FA_20_liquidateCreditAccount_gas_estimate_3() public {
        vm.startPrank(CONFIGURATOR);
        cft.gauge().addQuotaToken(tokenTestSuite.addressOf(Tokens.LINK), 500, 500);
        cft.poolQuotaKeeper().setTokenLimit(tokenTestSuite.addressOf(Tokens.LINK), type(uint96).max);
        cft.gauge().updateEpoch();
        creditConfigurator.makeTokenQuoted(tokenTestSuite.addressOf(Tokens.LINK));
        vm.stopPrank();

        tokenTestSuite.mint(Tokens.LINK, USER, LINK_ACCOUNT_AMOUNT);
        tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

        tokenTestSuite.mint(Tokens.DAI, FRIEND, DAI_ACCOUNT_AMOUNT * 100);
        tokenTestSuite.approve(Tokens.DAI, FRIEND, address(creditManager));

        MultiCall[] memory calls = new MultiCall[](2);

        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), LINK_ACCOUNT_AMOUNT)
                )
        });

        calls[1] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.updateQuota,
                (tokenTestSuite.addressOf(Tokens.LINK), int96(int256(LINK_ACCOUNT_AMOUNT)), 0)
                )
        });

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

        _zeroAllLTs();

        vm.roll(block.number + 1);

        vm.warp(block.timestamp + 30 days);

        calls = new MultiCall[](0);

        uint256 gasBefore = gasleft();

        vm.prank(FRIEND);
        creditFacade.liquidateCreditAccount(creditAccount, FRIEND, 0, false, calls);

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(
            string(abi.encodePacked("Gas spent - liquidateCreditAccount with underlying and quoted token: "))
        );
        emit log_uint(gasSpent);
    }
}
