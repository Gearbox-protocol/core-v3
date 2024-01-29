// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {ICreditFacadeV3Multicall} from "../../../interfaces/ICreditFacadeV3.sol";
import {MultiCallBuilder} from "../../lib/MultiCallBuilder.sol";
import {PartialLiquidationBot} from "../../../bots/PartialLiquidationBot.sol";
import {LiquidationParams, PriceUpdate} from "../../../interfaces/IPartialLiquidationBot.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    DECREASE_DEBT_PERMISSION,
    ENABLE_TOKEN_PERMISSION,
    WITHDRAW_COLLATERAL_PERMISSION
} from "../../../interfaces/ICreditFacadeV3Multicall.sol";

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// DATA
import {MultiCall, MultiCallOps} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";

// TESTS
import "../../lib/constants.sol";
import {IntegrationTestHelper} from "../../helpers/IntegrationTestHelper.sol";

// MOCKS
import {AdapterMock} from "../../mocks/core/AdapterMock.sol";

// SUITES
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

contract PartialLiquidationBotGasTest is IntegrationTestHelper {
    PartialLiquidationBot plb;

    function _setUp() public {
        plb = new PartialLiquidationBot();

        vm.prank(CONFIGURATOR);
        botList.setBotSpecialPermissions(
            address(plb),
            address(creditManager),
            ENABLE_TOKEN_PERMISSION | WITHDRAW_COLLATERAL_PERMISSION | DECREASE_DEBT_PERMISSION
        );
    }

    function _purgeToken(address creditAccount, address token, uint256 amount) internal {
        vm.prank(creditAccount);
        IERC20(token).transfer(address(1), amount);
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev G:[PLB-01]: partial liquidation with one token and underlying, no repay
    function test_G_PLB_01_partial_liquidation_gas_estimate_1_no_repay() public creditTest {
        _setUp();

        // Exactly enough LINK to cover debt + 100 WAD
        uint256 linkAmount = 100 * WAD
            + priceOracle.convert(DAI_ACCOUNT_AMOUNT, underlying, tokenTestSuite.addressOf(Tokens.LINK)) * PERCENTAGE_FACTOR
                / creditManager.liquidationThresholds(tokenTestSuite.addressOf(Tokens.LINK));

        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);
        tokenTestSuite.mint(Tokens.LINK, USER, linkAmount);
        tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

        tokenTestSuite.mint(Tokens.DAI, FRIEND, DAI_ACCOUNT_AMOUNT * 100);
        tokenTestSuite.approve(Tokens.DAI, FRIEND, address(plb));

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), linkAmount)
                    )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        vm.roll(block.number + 1);

        // Account should be liquidatable after
        _purgeToken(creditAccount, tokenTestSuite.addressOf(Tokens.LINK), 101 * WAD);
        _purgeToken(creditAccount, underlying, DAI_ACCOUNT_AMOUNT - WAD);

        uint256 gasBefore = gasleft();

        vm.startPrank(FRIEND);
        plb.partialLiquidateExactOut({
            creditManager: address(creditManager),
            creditAccount: creditAccount,
            assetOut: tokenTestSuite.addressOf(Tokens.LINK),
            amountOut: type(uint256).max,
            to: FRIEND,
            repay: false,
            priceUpdates: new PriceUpdate[](0)
        });
        vm.stopPrank();

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(
            string(abi.encodePacked("Gas spent - liquidateCreditAccount with 1 token + underlying, without repay: "))
        );
        emit log_uint(gasSpent);
    }

    /// @dev G:[PLB-01A]: partial liquidation with one token and underlying, with repay
    function test_G_PLB_01A_partial_liquidation_gas_estimate_1_with_repay() public creditTest {
        _setUp();

        // Exactly enough LINK to cover debt + 100 WAD
        uint256 linkAmount = 100 * WAD
            + priceOracle.convert(DAI_ACCOUNT_AMOUNT, underlying, tokenTestSuite.addressOf(Tokens.LINK)) * PERCENTAGE_FACTOR
                / creditManager.liquidationThresholds(tokenTestSuite.addressOf(Tokens.LINK));

        tokenTestSuite.mint(underlying, USER, DAI_ACCOUNT_AMOUNT);
        tokenTestSuite.mint(Tokens.LINK, USER, linkAmount);
        tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

        tokenTestSuite.mint(Tokens.DAI, FRIEND, DAI_ACCOUNT_AMOUNT * 100);
        tokenTestSuite.approve(Tokens.DAI, FRIEND, address(plb));

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), linkAmount)
                    )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        vm.roll(block.number + 1);

        // Account should be liquidatable after
        _purgeToken(creditAccount, tokenTestSuite.addressOf(Tokens.LINK), 101 * WAD);
        _purgeToken(creditAccount, underlying, DAI_ACCOUNT_AMOUNT - WAD);

        uint256 gasBefore = gasleft();

        vm.startPrank(FRIEND);
        plb.partialLiquidateExactOut({
            creditManager: address(creditManager),
            creditAccount: creditAccount,
            assetOut: tokenTestSuite.addressOf(Tokens.LINK),
            amountOut: type(uint256).max,
            to: FRIEND,
            repay: true,
            priceUpdates: new PriceUpdate[](0)
        });
        vm.stopPrank();

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(
            string(abi.encodePacked("Gas spent - liquidateCreditAccount with 1 token + underlying, with repay: "))
        );
        emit log_uint(gasSpent);
    }

    /// @dev G:[PLB-02]: liquidateCreditAccount with 2 tokens and active quota interest, no repay
    function test_G_PLB_02_partial_liquidation_gas_estimate_2_no_repay() public creditTest {
        _setUp();

        // Exactly enough LINK to cover debt + 100 WAD
        uint256 linkAmount = 100 * WAD
            + priceOracle.convert(DAI_ACCOUNT_AMOUNT, underlying, tokenTestSuite.addressOf(Tokens.LINK)) * PERCENTAGE_FACTOR
                / creditManager.liquidationThresholds(tokenTestSuite.addressOf(Tokens.LINK));

        vm.startPrank(CONFIGURATOR);
        gauge.addQuotaToken(tokenTestSuite.addressOf(Tokens.LINK), 500, 500);
        poolQuotaKeeper.setTokenLimit(tokenTestSuite.addressOf(Tokens.LINK), type(uint96).max);
        creditConfigurator.makeTokenQuoted(tokenTestSuite.addressOf(Tokens.LINK));

        vm.warp(block.timestamp + 7 days);
        gauge.updateEpoch();
        vm.stopPrank();

        tokenTestSuite.mint(Tokens.LINK, USER, linkAmount);
        tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

        tokenTestSuite.mint(Tokens.DAI, FRIEND, DAI_ACCOUNT_AMOUNT * 100);
        tokenTestSuite.approve(Tokens.DAI, FRIEND, address(plb));

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), linkAmount)
                    )
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota,
                    (tokenTestSuite.addressOf(Tokens.LINK), int96(int256(DAI_ACCOUNT_AMOUNT)), 0)
                    )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        // Account should be liquidatable after
        _purgeToken(creditAccount, tokenTestSuite.addressOf(Tokens.LINK), 100 * WAD);
        _purgeToken(creditAccount, underlying, DAI_ACCOUNT_AMOUNT - WAD);

        vm.roll(block.number + 1);

        vm.warp(block.timestamp + 30 days);

        uint256 gasBefore = gasleft();

        vm.startPrank(FRIEND);
        plb.partialLiquidateExactOut({
            creditManager: address(creditManager),
            creditAccount: creditAccount,
            assetOut: tokenTestSuite.addressOf(Tokens.LINK),
            amountOut: type(uint256).max,
            to: FRIEND,
            repay: false,
            priceUpdates: new PriceUpdate[](0)
        });
        vm.stopPrank();

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(
            string(
                abi.encodePacked("Gas spent - liquidatePartialSingleAsset with underlying and quoted token, no repay: ")
            )
        );
        emit log_uint(gasSpent);
    }

    /// @dev G:[PLB-02A]: liquidateCreditAccount with 2 tokens and active quota interest, with repay
    function test_G_PLB_02A_partial_liquidation_gas_estimate_2_with_repay() public creditTest {
        _setUp();

        // Exactly enough LINK to cover debt + 100 WAD
        uint256 linkAmount = 100 * WAD
            + priceOracle.convert(DAI_ACCOUNT_AMOUNT, underlying, tokenTestSuite.addressOf(Tokens.LINK)) * PERCENTAGE_FACTOR
                / creditManager.liquidationThresholds(tokenTestSuite.addressOf(Tokens.LINK));

        vm.startPrank(CONFIGURATOR);
        gauge.addQuotaToken(tokenTestSuite.addressOf(Tokens.LINK), 500, 500);
        poolQuotaKeeper.setTokenLimit(tokenTestSuite.addressOf(Tokens.LINK), type(uint96).max);
        creditConfigurator.makeTokenQuoted(tokenTestSuite.addressOf(Tokens.LINK));

        vm.warp(block.timestamp + 7 days);
        gauge.updateEpoch();
        vm.stopPrank();

        tokenTestSuite.mint(Tokens.LINK, USER, linkAmount);
        tokenTestSuite.approve(Tokens.LINK, USER, address(creditManager));

        tokenTestSuite.mint(Tokens.DAI, FRIEND, DAI_ACCOUNT_AMOUNT * 100);
        tokenTestSuite.approve(Tokens.DAI, FRIEND, address(plb));

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.LINK), linkAmount)
                    )
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota,
                    (tokenTestSuite.addressOf(Tokens.LINK), int96(int256(DAI_ACCOUNT_AMOUNT)), 0)
                    )
            })
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        // Account should be liquidatable after
        _purgeToken(creditAccount, tokenTestSuite.addressOf(Tokens.LINK), 100 * WAD);
        _purgeToken(creditAccount, underlying, DAI_ACCOUNT_AMOUNT - WAD);

        vm.roll(block.number + 1);

        vm.warp(block.timestamp + 30 days);

        uint256 gasBefore = gasleft();

        vm.startPrank(FRIEND);
        plb.partialLiquidateExactOut({
            creditManager: address(creditManager),
            creditAccount: creditAccount,
            assetOut: tokenTestSuite.addressOf(Tokens.LINK),
            amountOut: type(uint256).max,
            to: FRIEND,
            repay: true,
            priceUpdates: new PriceUpdate[](0)
        });
        vm.stopPrank();

        uint256 gasSpent = gasBefore - gasleft();

        emit log_string(
            string(
                abi.encodePacked(
                    "Gas spent - liquidatePartialSingleAsset with underlying and quoted token, with repay: "
                )
            )
        );
        emit log_uint(gasSpent);
    }
}
