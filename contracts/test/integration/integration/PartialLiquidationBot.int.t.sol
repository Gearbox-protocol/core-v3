// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {CreditLogic} from "../../../libraries/CreditLogic.sol";
import {CollateralDebtData, CollateralCalcTask} from "../../../interfaces/ICreditManagerV3.sol";
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
import {PriceFeedOnDemandMock} from "../../mocks/oracles/PriceFeedOnDemandMock.sol";

// SUITES
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

import "../../../interfaces/IExceptions.sol";

contract PartialLiquidationBotIntegrationTest is IntegrationTestHelper {
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

    /// @dev I:[PLB-01]: liquidatePartialSingleAsset correctly updates prices
    function test_I_PLB_01_liquidatePartialSingleAsset_correctly_updates_prices() public creditTest {
        _setUp();

        address mockUpdatablePF_01 = address(new PriceFeedOnDemandMock());
        address mockUpdatablePF_02 = address(new PriceFeedOnDemandMock());

        vm.startPrank(CONFIGURATOR);
        priceOracle.setReservePriceFeed(underlying, mockUpdatablePF_01, type(uint32).max);
        priceOracle.setReservePriceFeed(tokenTestSuite.addressOf(Tokens.LINK), mockUpdatablePF_02, type(uint32).max);
        vm.stopPrank();

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

        PriceUpdate[] memory pUpdates = new PriceUpdate[](2);

        pUpdates[0] = PriceUpdate({token: underlying, reserve: true, data: "hello DAI"});

        pUpdates[1] = PriceUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), reserve: true, data: "hello LINK"});

        vm.expectCall(mockUpdatablePF_01, abi.encodeCall(PriceFeedOnDemandMock.updatePrice, ("hello DAI")));
        vm.expectCall(mockUpdatablePF_02, abi.encodeCall(PriceFeedOnDemandMock.updatePrice, ("hello LINK")));

        vm.startPrank(FRIEND);
        plb.partialLiquidateExactOut({
            creditManager: address(creditManager),
            creditAccount: creditAccount,
            assetOut: tokenTestSuite.addressOf(Tokens.LINK),
            amountOut: type(uint256).max,
            repay: false,
            priceUpdates: pUpdates
        });
        vm.stopPrank();
    }

    /// @dev I:[PLB-02]: liquidatePartialSingleAsset reverts when the account is not liquidatable
    function test_I_PLB_02_liquidatePartialSingleAsset_reverts_for_non_liquidatable_account() public creditTest {
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

        address link = tokenTestSuite.addressOf(Tokens.LINK);

        vm.expectRevert(CreditAccountNotLiquidatableException.selector);

        vm.prank(FRIEND);
        plb.partialLiquidateExactOut({
            creditManager: address(creditManager),
            creditAccount: creditAccount,
            assetOut: link,
            amountOut: type(uint256).max,
            repay: false,
            priceUpdates: new PriceUpdate[](0)
        });
    }

    /// @dev I:[PLB-03]: liquidatePartialSingleAsset reverts when assetOut == underlying
    function test_I_PLB_03_liquidatePartialSingleAsset_reverts_when_assetOut_is_underlying() public creditTest {
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

        vm.expectRevert(CantPartialLiquidateUnderlying.selector);

        vm.startPrank(FRIEND);
        plb.partialLiquidateExactOut({
            creditManager: address(creditManager),
            creditAccount: creditAccount,
            assetOut: underlying,
            amountOut: type(uint256).max,
            repay: false,
            priceUpdates: new PriceUpdate[](0)
        });
        vm.stopPrank();
    }

    /// @dev I:[PLB-04]: liquidatePartialSingleAsset allows correct max repayment amount for both repayment cases
    function test_I_PLB_04_liquidatePartialSingleAsset_max_swap_is_correct() public creditTest {
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

        for (uint256 i = 0; i < 2; ++i) {
            uint256 snapshot = vm.snapshot();

            CollateralDebtData memory cdd =
                creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);

            (uint256 minDebt,) = creditFacade.debtLimits();

            uint256 maxRepayable = i == 0
                ? CreditLogic.calcTotalDebt(cdd) * plb.DEBT_BUFFER() / PERCENTAGE_FACTOR - WAD
                : CreditLogic.calcTotalDebt(cdd) - minDebt - WAD;

            address link = tokenTestSuite.addressOf(Tokens.LINK);

            vm.expectCall(underlying, abi.encodeCall(IERC20.transferFrom, (FRIEND, creditAccount, maxRepayable)));

            vm.startPrank(FRIEND);
            (uint256 underlyingAmountIn,) = plb.partialLiquidateExactOut({
                creditManager: address(creditManager),
                creditAccount: creditAccount,
                assetOut: link,
                amountOut: type(uint256).max,
                repay: i == 1,
                priceUpdates: new PriceUpdate[](0)
            });
            vm.stopPrank();

            assertEq(underlyingAmountIn, maxRepayable, "Incorrect amount of spent underlying returned");

            vm.revertTo(snapshot);
        }
    }

    /// @dev I:[PLB-05]: liquidatePartialSingleAsset revert on too low health factor post liqudiation
    function test_I_PLB_05_liquidatePartialSingleAsset_reverts_on_hf_too_low() public creditTest {
        _setUp();

        // Exactly enough LINK to cover debt at HF = 1 after swapping + 100 WAD
        // Should be enough to cover debt after swapping, but just barely
        uint256 linkAmount = 100 * WAD
            + priceOracle.convert(
                DAI_ACCOUNT_AMOUNT * PERCENTAGE_FACTOR / creditManager.liquidationThresholds(underlying),
                underlying,
                tokenTestSuite.addressOf(Tokens.LINK)
            );

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
        _purgeToken(creditAccount, underlying, DAI_ACCOUNT_AMOUNT);

        address link = tokenTestSuite.addressOf(Tokens.LINK);

        vm.expectRevert(HealthFactorTooLowException.selector);

        vm.startPrank(FRIEND);
        plb.partialLiquidateExactOut({
            creditManager: address(creditManager),
            creditAccount: creditAccount,
            assetOut: link,
            amountOut: type(uint256).max,
            repay: false,
            priceUpdates: new PriceUpdate[](0)
        });
        vm.stopPrank();
    }
}
