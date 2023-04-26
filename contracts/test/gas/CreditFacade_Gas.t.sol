// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";

import {CreditFacadeV3} from "../../credit/CreditFacadeV3.sol";
import {CreditManagerV3} from "../../credit/CreditManagerV3.sol";

import {CreditAccount} from "@gearbox-protocol/core-v2/contracts/credit/CreditAccount.sol";
import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";

import {BotList} from "../../support/BotList.sol";

import {ICreditFacade, ICreditFacadeMulticall, ICreditFacadeEvents} from "../../interfaces/ICreditFacade.sol";
import {ICreditManagerV3, ICreditManagerV3Events, ClosureAction} from "../../interfaces/ICreditManagerV3.sol";

import {IDegenNFT, IDegenNFTExceptions} from "@gearbox-protocol/core-v2/contracts/interfaces/IDegenNFT.sol";
import {IWithdrawManager} from "../../interfaces/IWithdrawManager.sol";
import {QuotaUpdate} from "../../interfaces/IPoolQuotaKeeper.sol";

// DATA
import {MultiCall, MultiCallOps} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {Balance} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";

import {
    CreditFacadeMulticaller,
    CreditFacadeCalls
} from "@gearbox-protocol/core-v2/contracts/multicall/CreditFacadeCalls.sol";

// CONSTANTS

import {LEVERAGE_DECIMALS} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// TESTS

import "../lib/constants.sol";
import {BalanceHelper} from "../helpers/BalanceHelper.sol";
import {CreditFacadeTestHelper} from "../helpers/CreditFacadeTestHelper.sol";

// EXCEPTIONS
import "../../interfaces/IExceptions.sol";

// MOCKS
import {AdapterMock} from "../mocks/adapters/AdapterMock.sol";
import {TargetContractMock} from "@gearbox-protocol/core-v2/contracts/test/mocks/adapters/TargetContractMock.sol";
import {ERC20BlacklistableMock} from "../mocks/token/ERC20Blacklistable.sol";

// SUITES
import {TokensTestSuite} from "../suites/TokensTestSuite.sol";
import {Tokens} from "../config/Tokens.sol";
import {CreditFacadeTestSuite} from "../suites/CreditFacadeTestSuite.sol";
import {CreditConfig} from "../config/CreditConfig.sol";

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
        tokenTestSuite = new TokensTestSuite();
        tokenTestSuite.topUpWETH{value: 100 * WAD}();

        CreditConfig creditConfig = new CreditConfig(
            tokenTestSuite,
            _underlying
        );

        cft = new CreditFacadeTestSuite(creditConfig);

        cft.testFacadeWithQuotas();

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

    function _zeroAllLTs() internal {
        uint256 collateralTokensCount = creditManager.collateralTokensCount();

        for (uint256 i = 0; i < collateralTokensCount; ++i) {
            (address token,) = creditManager.collateralTokens(i);

            evm.prank(address(creditConfigurator));
            CreditManagerV3(address(creditManager)).setLiquidationThreshold(token, 0);
        }
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    // /// @dev [G-FA-1]: openCreditAccount
    // function test_G_FA_01_openCreditAccount_gas_estimate() public {
    //     uint256 accountAmount = cft.creditAccountAmount();

    //     tokenTestSuite.mint(underlying, USER, accountAmount);

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(accountAmount, USER, 100, 0);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(string(abi.encodePacked("Gas spent: ")));
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-2]: openCreditAccount with just adding collateral
    // function test_G_FA_02_openCreditAccountMulticall_gas_estimate_1() public {
    //     tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

    //     MultiCall[] memory calls = new MultiCall[](1);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(string(abi.encodePacked("Gas spent - opening an account with just adding collateral: ")));
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-3]: openCreditAccount with adding collateral and single swap
    // function test_G_FA_03_openCreditAccountMulticall_gas_estimate_2() public {
    //     tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

    //     MultiCall[] memory calls = new MultiCall[](2);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     calls[1] = MultiCall({
    //         target: address(adapterMock),
    //         callData: abi.encodeCall(
    //             AdapterMock.executeSwapSafeApprove,
    //             (tokenTestSuite.addressOf(Tokens.DAI), tokenTestSuite.addressOf(Tokens.USDC), "", false)
    //             )
    //     });

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(
    //         string(abi.encodePacked("Gas spent - opening an account with adding collateral and executing one swap: "))
    //     );
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-4]: openCreditAccount with adding collateral and two swaps
    // function test_G_FA_04_openCreditAccountMulticall_gas_estimate_3() public {
    //     tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

    //     MultiCall[] memory calls = new MultiCall[](3);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     calls[1] = MultiCall({
    //         target: address(adapterMock),
    //         callData: abi.encodeCall(
    //             AdapterMock.executeSwapSafeApprove,
    //             (tokenTestSuite.addressOf(Tokens.DAI), tokenTestSuite.addressOf(Tokens.USDC), "", false)
    //             )
    //     });

    //     calls[2] = MultiCall({
    //         target: address(adapterMock),
    //         callData: abi.encodeCall(
    //             AdapterMock.executeSwapSafeApprove,
    //             (tokenTestSuite.addressOf(Tokens.USDC), tokenTestSuite.addressOf(Tokens.LINK), "", false)
    //             )
    //     });

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(
    //         string(abi.encodePacked("Gas spent - opening an account with adding collateral and executing two swaps: "))
    //     );
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-5]: openCreditAccount with adding quoted collateral and updating quota
    // function test_G_FA_05_openCreditAccountMulticall_gas_estimate_4() public {
    //     evm.startPrank(CONFIGURATOR);
    //     cft.gaugeMock().addQuotaToken(tokenTestSuite.addressOf(Tokens.LINK), 500);
    //     cft.poolQuotaKeeper().setTokenLimit(tokenTestSuite.addressOf(Tokens.LINK), type(uint96).max);
    //     cft.gaugeMock().updateEpoch();
    //     creditConfigurator.makeTokenLimited(tokenTestSuite.addressOf(Tokens.LINK));
    //     evm.stopPrank();

    //     tokenTestSuite.mint(Tokens.LINK, USER, LINK_ACCOUNT_AMOUNT);
    //     tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

    //     MultiCall[] memory calls = new MultiCall[](2);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), LINK_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](1);

    //     quotaUpdates[0] =
    //         QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), quotaChange: int96(int256(LINK_ACCOUNT_AMOUNT))});

    //     calls[1] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(ICreditFacadeMulticall.updateQuotas, (quotaUpdates))
    //     });

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(
    //         string(
    //             abi.encodePacked("Gas spent - opening an account with adding quoted collateral and updating 1 quota: ")
    //         )
    //     );
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-6]: openCreditAccount with swapping and updating quota
    // function test_G_FA_06_openCreditAccountMulticall_gas_estimate_5() public {
    //     evm.startPrank(CONFIGURATOR);
    //     cft.gaugeMock().addQuotaToken(tokenTestSuite.addressOf(Tokens.LINK), 500);
    //     cft.poolQuotaKeeper().setTokenLimit(tokenTestSuite.addressOf(Tokens.LINK), type(uint96).max);
    //     cft.gaugeMock().updateEpoch();
    //     creditConfigurator.makeTokenLimited(tokenTestSuite.addressOf(Tokens.LINK));
    //     evm.stopPrank();

    //     tokenTestSuite.mint(Tokens.LINK, USER, LINK_ACCOUNT_AMOUNT);
    //     tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

    //     MultiCall[] memory calls = new MultiCall[](3);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), LINK_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](1);

    //     quotaUpdates[0] =
    //         QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), quotaChange: int96(int256(LINK_ACCOUNT_AMOUNT))});

    //     calls[1] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(ICreditFacadeMulticall.updateQuotas, (quotaUpdates))
    //     });

    //     calls[2] = MultiCall({
    //         target: address(adapterMock),
    //         callData: abi.encodeCall(
    //             AdapterMock.executeSwapSafeApprove,
    //             (tokenTestSuite.addressOf(Tokens.DAI), tokenTestSuite.addressOf(Tokens.LINK), "", false)
    //             )
    //     });

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(
    //         string(abi.encodePacked("Gas spent - opening an account with swapping into quoted collateral: "))
    //     );
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-7]: multicall with increaseDebt
    // function test_G_FA_07_increaseDebt_gas_estimate_1() public {
    //     tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

    //     MultiCall[] memory calls = new MultiCall[](1);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
    //     });

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.multicall(calls);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(string(abi.encodePacked("Gas spent - multicall with increaseDebt: ")));
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-8]: multicall with decreaseDebt
    // function test_G_FA_08_decreaseDebt_gas_estimate_1() public {
    //     tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

    //     MultiCall[] memory calls = new MultiCall[](1);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(ICreditFacadeMulticall.decreaseDebt, (DAI_ACCOUNT_AMOUNT / 2))
    //     });

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.multicall(calls);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(string(abi.encodePacked("Gas spent - multicall with decreaseDebt: ")));
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-9]: multicall with decreaseDebt and active quota interest
    // function test_G_FA_09_decreaseDebt_gas_estimate_2() public {
    //     evm.startPrank(CONFIGURATOR);
    //     cft.gaugeMock().addQuotaToken(tokenTestSuite.addressOf(Tokens.LINK), 500);
    //     cft.poolQuotaKeeper().setTokenLimit(tokenTestSuite.addressOf(Tokens.LINK), type(uint96).max);
    //     cft.gaugeMock().updateEpoch();
    //     creditConfigurator.makeTokenLimited(tokenTestSuite.addressOf(Tokens.LINK));
    //     evm.stopPrank();

    //     tokenTestSuite.mint(Tokens.LINK, USER, LINK_ACCOUNT_AMOUNT);
    //     tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

    //     MultiCall[] memory calls = new MultiCall[](2);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), LINK_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](1);

    //     quotaUpdates[0] =
    //         QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), quotaChange: int96(int256(LINK_ACCOUNT_AMOUNT))});

    //     calls[1] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(ICreditFacadeMulticall.updateQuotas, (quotaUpdates))
    //     });

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     evm.warp(block.timestamp + 30 days);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(ICreditFacadeMulticall.decreaseDebt, (DAI_ACCOUNT_AMOUNT / 2))
    //     });

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.multicall(calls);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(string(abi.encodePacked("Gas spent - multicall with decreaseDebt with quoted tokens: ")));
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-10]: multicall with enableToken
    // function test_G_FA_10_enableToken_gas_estimate_1() public {
    //     tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

    //     MultiCall[] memory calls = new MultiCall[](1);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(ICreditFacadeMulticall.enableToken, (tokenTestSuite.addressOf(Tokens.LINK)))
    //     });

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.multicall(calls);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(string(abi.encodePacked("Gas spent - multicall with enableToken: ")));
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-11]: multicall with disableToken
    // function test_G_FA_11_disableToken_gas_estimate_1() public {
    //     tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

    //     MultiCall[] memory calls = new MultiCall[](2);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     calls[1] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(ICreditFacadeMulticall.enableToken, (tokenTestSuite.addressOf(Tokens.LINK)))
    //     });

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(ICreditFacadeMulticall.disableToken, (tokenTestSuite.addressOf(Tokens.LINK)))
    //     });

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.multicall(calls);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(string(abi.encodePacked("Gas spent - multicall with disableToken: ")));
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-12]: multicall with a single swap
    // function test_G_FA_12_multicall_gas_estimate_1() public {
    //     tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

    //     MultiCall[] memory calls = new MultiCall[](1);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     calls[0] = MultiCall({
    //         target: address(adapterMock),
    //         callData: abi.encodeCall(
    //             AdapterMock.executeSwapSafeApprove,
    //             (tokenTestSuite.addressOf(Tokens.DAI), tokenTestSuite.addressOf(Tokens.LINK), "", false)
    //             )
    //     });

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.multicall(calls);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(string(abi.encodePacked("Gas spent - multicall with a single swap: ")));
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-12A]: multicall with a single swap
    // function test_G_FA_12A_multicall_gas_estimate_1A() public {
    //     tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

    //     MultiCall[] memory calls = new MultiCall[](1);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     calls = new MultiCall[](2);

    //     calls[0] = MultiCall({
    //         target: address(adapterMock),
    //         callData: abi.encodeCall(
    //             AdapterMock.executeSwapSafeApprove,
    //             (tokenTestSuite.addressOf(Tokens.DAI), tokenTestSuite.addressOf(Tokens.LINK), "", false)
    //             )
    //     });

    //     calls[1] = MultiCall({
    //         target: address(adapterMock),
    //         callData: abi.encodeCall(
    //             AdapterMock.executeSwapSafeApprove,
    //             (tokenTestSuite.addressOf(Tokens.LINK), tokenTestSuite.addressOf(Tokens.USDC), "", true)
    //             )
    //     });

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.multicall(calls);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(string(abi.encodePacked("Gas spent - multicall with two swaps: ")));
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-13]: multicall with a single swap into quoted token
    // function test_G_FA_13_multicall_gas_estimate_2() public {
    //     evm.startPrank(CONFIGURATOR);
    //     cft.gaugeMock().addQuotaToken(tokenTestSuite.addressOf(Tokens.LINK), 500);
    //     cft.poolQuotaKeeper().setTokenLimit(tokenTestSuite.addressOf(Tokens.LINK), type(uint96).max);
    //     cft.gaugeMock().updateEpoch();
    //     creditConfigurator.makeTokenLimited(tokenTestSuite.addressOf(Tokens.LINK));
    //     evm.stopPrank();

    //     tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

    //     MultiCall[] memory calls = new MultiCall[](1);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     address creditAccount = creditManager.getCreditAccountOrRevert(USER);

    //     tokenTestSuite.burn(Tokens.DAI, creditAccount, DAI_ACCOUNT_AMOUNT * 2);
    //     tokenTestSuite.mint(Tokens.LINK, creditAccount, LINK_ACCOUNT_AMOUNT * 3);

    //     calls = new MultiCall[](2);

    //     calls[0] = MultiCall({
    //         target: address(adapterMock),
    //         callData: abi.encodeCall(
    //             AdapterMock.executeSwapSafeApprove,
    //             (tokenTestSuite.addressOf(Tokens.DAI), tokenTestSuite.addressOf(Tokens.LINK), "", true)
    //             )
    //     });

    //     QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](1);

    //     quotaUpdates[0] = QuotaUpdate({
    //         token: tokenTestSuite.addressOf(Tokens.LINK),
    //         quotaChange: int96(int256(LINK_ACCOUNT_AMOUNT * 3))
    //     });

    //     calls[1] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(ICreditFacadeMulticall.updateQuotas, (quotaUpdates))
    //     });

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.multicall(calls);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(
    //         string(
    //             abi.encodePacked(
    //                 "Gas spent - multicall with a single swap into quoted collateral and updating quotas: "
    //             )
    //         )
    //     );
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-14]: closeCreditAccount with underlying only
    // function test_G_FA_14_closeCreditAccount_gas_estimate_1() public {
    //     tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

    //     MultiCall[] memory calls = new MultiCall[](1);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     evm.roll(block.number + 1);

    //     calls = new MultiCall[](0);

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.closeCreditAccount(USER, 0, false, calls);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(string(abi.encodePacked("Gas spent - closeCreditAccount with underlying only: ")));
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-15]: closeCreditAccount with two tokens
    // function test_G_FA_15_closeCreditAccount_gas_estimate_2() public {
    //     tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);
    //     tokenTestSuite.mint(Tokens.LINK, USER, LINK_ACCOUNT_AMOUNT);
    //     tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

    //     MultiCall[] memory calls = new MultiCall[](2);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     calls[1] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), LINK_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     evm.roll(block.number + 1);

    //     calls = new MultiCall[](0);

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.closeCreditAccount(USER, 0, false, calls);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(string(abi.encodePacked("Gas spent - closeCreditAccount with 2 tokens: ")));
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-16]: closeCreditAccount with 2 tokens and active quota interest
    // function test_G_FA_16_closeCreditAccount_gas_estimate_3() public {
    //     evm.startPrank(CONFIGURATOR);
    //     cft.gaugeMock().addQuotaToken(tokenTestSuite.addressOf(Tokens.LINK), 500);
    //     cft.poolQuotaKeeper().setTokenLimit(tokenTestSuite.addressOf(Tokens.LINK), type(uint96).max);
    //     cft.gaugeMock().updateEpoch();
    //     creditConfigurator.makeTokenLimited(tokenTestSuite.addressOf(Tokens.LINK));
    //     evm.stopPrank();

    //     tokenTestSuite.mint(Tokens.LINK, USER, LINK_ACCOUNT_AMOUNT);
    //     tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

    //     MultiCall[] memory calls = new MultiCall[](2);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), LINK_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](1);

    //     quotaUpdates[0] =
    //         QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), quotaChange: int96(int256(LINK_ACCOUNT_AMOUNT))});

    //     calls[1] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(ICreditFacadeMulticall.updateQuotas, (quotaUpdates))
    //     });

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     evm.roll(block.number + 1);

    //     evm.warp(block.timestamp + 30 days);

    //     calls = new MultiCall[](0);

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.closeCreditAccount(USER, 0, false, calls);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(string(abi.encodePacked("Gas spent - closeCreditAccount with underlying and quoted token: ")));
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-17]: closeCreditAccount with one swap
    // function test_G_FA_17_closeCreditAccount_gas_estimate_4() public {
    //     tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

    //     MultiCall[] memory calls = new MultiCall[](1);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     evm.roll(block.number + 1);

    //     calls[0] = MultiCall({
    //         target: address(adapterMock),
    //         callData: abi.encodeCall(
    //             AdapterMock.executeSwapSafeApprove,
    //             (tokenTestSuite.addressOf(Tokens.LINK), tokenTestSuite.addressOf(Tokens.DAI), "", true)
    //             )
    //     });

    //     uint256 gasBefore = gasleft();

    //     evm.prank(USER);
    //     creditFacade.closeCreditAccount(USER, 0, false, calls);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(string(abi.encodePacked("Gas spent - closeCreditAccount with one swap: ")));
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-18]: liquidateCreditAccount with underlying only
    // function test_G_FA_18_liquidateCreditAccount_gas_estimate_1() public {
    //     tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);

    //     MultiCall[] memory calls = new MultiCall[](1);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     evm.roll(block.number + 1);

    //     _zeroAllLTs();

    //     calls = new MultiCall[](0);

    //     uint256 gasBefore = gasleft();

    //     evm.prank(FRIEND);
    //     creditFacade.liquidateCreditAccount(USER, FRIEND, 0, false, calls);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(string(abi.encodePacked("Gas spent - liquidateCreditAccount with underlying only: ")));
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-19]: liquidateCreditAccount with two tokens
    // function test_G_FA_19_liquidateCreditAccount_gas_estimate_2() public {
    //     tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);
    //     tokenTestSuite.mint(Tokens.LINK, USER, LINK_ACCOUNT_AMOUNT);
    //     tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

    //     tokenTestSuite.mint(Tokens.DAI, FRIEND, DAI_ACCOUNT_AMOUNT * 100);
    //     tokenTestSuite.approve(Tokens.DAI, FRIEND, address(creditManager));

    //     MultiCall[] memory calls = new MultiCall[](2);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     calls[1] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), LINK_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     evm.roll(block.number + 1);

    //     _zeroAllLTs();

    //     calls = new MultiCall[](0);

    //     uint256 gasBefore = gasleft();

    //     evm.prank(FRIEND);
    //     creditFacade.liquidateCreditAccount(USER, FRIEND, 0, false, calls);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(string(abi.encodePacked("Gas spent - liquidateCreditAccount with 2 tokens: ")));
    //     emit log_uint(gasSpent);
    // }

    // /// @dev [G-FA-20]: liquidateCreditAccount with 2 tokens and active quota interest
    // function test_G_FA_20_liquidateCreditAccount_gas_estimate_3() public {
    //     evm.startPrank(CONFIGURATOR);
    //     cft.gaugeMock().addQuotaToken(tokenTestSuite.addressOf(Tokens.LINK), 500);
    //     cft.poolQuotaKeeper().setTokenLimit(tokenTestSuite.addressOf(Tokens.LINK), type(uint96).max);
    //     cft.gaugeMock().updateEpoch();
    //     creditConfigurator.makeTokenLimited(tokenTestSuite.addressOf(Tokens.LINK));
    //     evm.stopPrank();

    //     tokenTestSuite.mint(Tokens.LINK, USER, LINK_ACCOUNT_AMOUNT);
    //     tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

    //     tokenTestSuite.mint(Tokens.DAI, FRIEND, DAI_ACCOUNT_AMOUNT * 100);
    //     tokenTestSuite.approve(Tokens.DAI, FRIEND, address(creditManager));

    //     MultiCall[] memory calls = new MultiCall[](2);

    //     calls[0] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(
    //             ICreditFacadeMulticall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), LINK_ACCOUNT_AMOUNT)
    //             )
    //     });

    //     QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](1);

    //     quotaUpdates[0] =
    //         QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), quotaChange: int96(int256(LINK_ACCOUNT_AMOUNT))});

    //     calls[1] = MultiCall({
    //         target: address(creditFacade),
    //         callData: abi.encodeCall(ICreditFacadeMulticall.updateQuotas, (quotaUpdates))
    //     });

    //     evm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER, calls, 0);

    //     _zeroAllLTs();

    //     evm.roll(block.number + 1);

    //     evm.warp(block.timestamp + 30 days);

    //     calls = new MultiCall[](0);

    //     uint256 gasBefore = gasleft();

    //     evm.prank(FRIEND);
    //     creditFacade.liquidateCreditAccount(USER, FRIEND, 0, false, calls);

    //     uint256 gasSpent = gasBefore - gasleft();

    //     emit log_string(
    //         string(abi.encodePacked("Gas spent - liquidateCreditAccount with underlying and quoted token: "))
    //     );
    //     emit log_uint(gasSpent);
    // }
}
