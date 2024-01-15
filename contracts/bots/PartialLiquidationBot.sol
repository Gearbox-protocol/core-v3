// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPartialLiquidationBot, LiquidationParams, PriceUpdate} from "../interfaces/IPartialLiquidationBot.sol";
import {ICreditFacadeV3} from "../interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "../interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditManagerV3, CollateralDebtData, CollateralCalcTask} from "../interfaces/ICreditManagerV3.sol";
import {IPriceOracleV3} from "../interfaces/IPriceOracleV3.sol";
import {CreditLogic} from "../libraries/CreditLogic.sol";

import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {IUpdatablePriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";

import "../interfaces/IExceptions.sol";

contract PartialLiquidationBot is IPartialLiquidationBot {
    /// @notice Performs a partial liquidation by swapping some collateral asset for underlying with a discount
    /// @param params A struct encoding liquidation params:
    ///               * creditManager - Credit Manager where the liquidated CA currently resides
    ///               * creditAccount - Credit Account to liquidate
    ///               * assetOut - asset that the liquidator wishes to receive
    ///               * amountOut - amount of the asset the liquidator wants to receive
    ///               * maxAmountInUnderlying - the maximal amount of underlying that the liquidator will be charged
    ///               * repay - whether to repay debt after swapping into underlying
    ///               * priceUpdates - data for price feeds to update before liquidation
    function liquidatePartialSingleAsset(LiquidationParams memory params) external {
        address priceOracle = ICreditManagerV3(params.creditManager).priceOracle();

        /// Since we are computing debt and collateral before liquidation,
        /// we need to update prices beforehand, if needed
        _applyPriceUpdates(params.priceUpdates, priceOracle);

        CollateralDebtData memory cdd = ICreditManagerV3(params.creditManager).calcDebtAndCollateral(
            params.creditAccount, CollateralCalcTask.DEBT_COLLATERAL
        );

        if (cdd.twvUSD >= cdd.totalDebtUSD) revert CreditAccountNotLiquidatableException();

        address creditFacade = ICreditManagerV3(params.creditManager).creditFacade();

        // It's techically possible to pass underlying as assetOut
        // However, this would reduce the HF of the account, which will result
        // in a revert due to failed collateral check on CM side
        address underlying = ICreditManagerV3(params.creditManager).underlying();

        uint256 amountInUnderlying =
            _getAmountIn(priceOracle, params.creditManager, underlying, params.assetOut, params.amountOut);

        if (params.repay) {
            /// If debt is being repaid, we will revert early here if the
            /// minimal debt limit is violated as a result
            (uint256 minDebt,) = ICreditFacadeV3(creditFacade).debtLimits();
            if (amountInUnderlying > CreditLogic.calcTotalDebt(cdd) - minDebt) {
                revert CantPartialLiquidateBelowMinDebt();
            }
        }

        if (amountInUnderlying > params.maxAmountInUnderlying) revert AmountUnderlyingLargerThanMax();

        IERC20(underlying).transferFrom(msg.sender, address(this), amountInUnderlying);
        IERC20(underlying).approve(params.creditManager, amountInUnderlying);

        ICreditFacadeV3(creditFacade).botMulticall(
            params.creditAccount,
            _getMultiCall(creditFacade, underlying, amountInUnderlying, params.assetOut, params.amountOut, params.repay)
        );
    }

    /// @notice Returns the maximal asset out amount that can be received from a partial liquidation,
    ///         and the corresponding amount of udnerlying that will be charged
    /// @param creditManager Credit Manager where the liquidated CA resides
    /// @param creditAccount Credit Account to liquidate
    /// @param assetOut Asset to receive
    /// @param priceUpdates Price updates required to compute account values
    /// @dev Intended to be used with an external static call
    function getLiquidationWithRepayMaxAmount(
        address creditManager,
        address creditAccount,
        address assetOut,
        PriceUpdate[] memory priceUpdates
    ) external returns (uint256 maxAmountAssetOut, uint256 amountAssetIn) {
        address priceOracle = ICreditManagerV3(creditManager).priceOracle();

        _applyPriceUpdates(priceUpdates, priceOracle);

        CollateralDebtData memory cdd =
            ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);

        if (cdd.twvUSD >= cdd.totalDebtUSD) return (0, 0);

        uint256 assetOutBalance = IERC20(assetOut).balanceOf(creditAccount);

        uint256 balanceSwapAmountIn = _getAmountIn(
            priceOracle, creditManager, ICreditManagerV3(creditManager).underlying(), assetOut, assetOutBalance
        );

        uint256 maxRepay;

        {
            address creditFacade = ICreditManagerV3(creditManager).creditFacade();
            (uint256 minDebt,) = ICreditFacadeV3(creditFacade).debtLimits();
            maxRepay = CreditLogic.calcTotalDebt(cdd) - minDebt;
        }

        if (balanceSwapAmountIn > maxRepay) {
            return (assetOutBalance * maxRepay / (balanceSwapAmountIn + 1), maxRepay);
        } else {
            return (assetOutBalance, balanceSwapAmountIn);
        }
    }

    /// @dev Computes the amount of underlying to pay for a corresponding amount of assetOut
    function _getAmountIn(
        address priceOracle,
        address creditManager,
        address underlying,
        address assetOut,
        uint256 amountOut
    ) internal view returns (uint256) {
        (,, uint16 liquidationDiscount,,) = ICreditManagerV3(creditManager).fees();
        return IPriceOracleV3(priceOracle).convert(amountOut, assetOut, underlying) * liquidationDiscount
            / PERCENTAGE_FACTOR;
    }

    /// @dev Returns the multicall to execute in Credit Facade
    function _getMultiCall(
        address creditFacade,
        address underlying,
        uint256 amountInUnderlying,
        address assetOut,
        uint256 amountOut,
        bool repay
    ) internal view returns (MultiCall[] memory calls) {
        calls = new MultiCall[](repay ? 3 : 2);

        calls[0] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, amountInUnderlying))
        });

        calls[1] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (assetOut, amountOut, msg.sender))
        });
        if (repay) {
            calls[2] = MultiCall({
                target: creditFacade,
                callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (amountInUnderlying))
            });
        }
    }

    /// @dev Applies required price feed updates
    function _applyPriceUpdates(PriceUpdate[] memory priceUpdates, address priceOracle) internal {
        uint256 len = priceUpdates.length;

        for (uint256 i = 0; i < len;) {
            PriceUpdate memory update = priceUpdates[i];

            address priceFeed = IPriceOracleV3(priceOracle).priceFeedsRaw(update.token, update.reserve);

            if (priceFeed == address(0)) {
                revert PriceFeedDoesNotExistException();
            }

            IUpdatablePriceFeed(priceFeed).updatePrice(update.data);

            unchecked {
                ++i;
            }
        }
    }
}
