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

/// @title Partial liquidation bot
/// @notice A bot that allows to swap collateral assets of unhealthy accounts to underlying with a discount (equal to the Credit Manager's liquidation premium)
/// @dev It is expected that this is set as a special permission bot in BotListV3 for all Credit Managers
contract PartialLiquidationBot is IPartialLiquidationBot {
    /// @notice Performs a partial liquidation by swapping some collateral asset for underlying with a discount
    /// @dev Returns the amount of underlying charged and amount of assetOut received
    /// @param params A struct encoding liquidation params:
    ///               * creditManager - Credit Manager where the liquidated CA currently resides
    ///               * creditAccount - Credit Account to liquidate
    ///               * assetOut - asset that the liquidator wishes to receive
    ///               * amountOut - amount of the asset the liquidator wants to receive
    ///               * repay - whether to repay debt after swapping into underlying
    ///               * priceUpdates - data for price feeds to update before liquidation
    function liquidatePartialSingleAsset(LiquidationParams memory params) external returns (uint256, uint256) {
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

        // In case the liquidator wants to get as much assetOut as possible,
        // they would pass uint256.max
        params.amountOut = params.amountOut == type(uint256).max
            ? IERC20(params.assetOut).balanceOf(params.creditAccount)
            : params.amountOut;

        // There is a limit imposed on the maximal amount of underlying that the liquidator can swap
        // If the debt is repaid, then that limit is totalDebt - minDebt - underlyingBalance (i.e., exactly enough to reduce debt to minDebt)
        // If the debt is not repaid, then that limit is totalDebt - underlyingBalance (i.e., exactly enough to fully liquidate the user in the future)

        uint256 amountInUnderlying;
        {
            uint256 underlyingBalance = IERC20(underlying).balanceOf(params.creditAccount);
            (uint256 minDebt,) = ICreditFacadeV3(creditFacade).debtLimits();

            uint256 repayable = CreditLogic.calcTotalDebt(cdd) - (params.repay ? minDebt : 0);

            if (underlyingBalance >= repayable) revert NothingToLiquidateException();

            uint256 maxAmountIn = repayable - underlyingBalance;

            (amountInUnderlying, params.amountOut) = _getAmounts(params, priceOracle, underlying, maxAmountIn);

            IERC20(underlying).transferFrom(msg.sender, params.creditAccount, amountInUnderlying);
        }

        ICreditFacadeV3(creditFacade).botMulticall(
            params.creditAccount, _getMultiCall(params, creditFacade, underlying)
        );

        return (amountInUnderlying, params.amountOut);
    }

    /// @dev Computes the amount of underlying to pay and assetOut to receive
    function _getAmounts(LiquidationParams memory params, address priceOracle, address underlying, uint256 maxAmountIn)
        internal
        view
        returns (uint256, uint256)
    {
        (,, uint16 liquidationDiscount,,) = ICreditManagerV3(params.creditManager).fees();

        uint256 underlyingEquivalent = IPriceOracleV3(priceOracle).convert(
            params.amountOut, params.assetOut, underlying
        ) * liquidationDiscount / PERCENTAGE_FACTOR;

        // If the computed amount of underlying is larger than max amount, then only the max amount is paid,
        // and the amount of assetOut is adjusted proportionally
        if (underlyingEquivalent > maxAmountIn) {
            return (maxAmountIn, maxAmountIn * params.amountOut / underlyingEquivalent);
        } else {
            return (underlyingEquivalent, params.amountOut);
        }
    }

    /// @dev Returns the multicall to execute in Credit Facade
    function _getMultiCall(LiquidationParams memory params, address creditFacade, address underlying)
        internal
        view
        returns (MultiCall[] memory calls)
    {
        calls = new MultiCall[](params.repay ? 3 : 2);

        calls[0] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.enableToken, (underlying))
        });

        calls[1] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.withdrawCollateral, (params.assetOut, params.amountOut, msg.sender)
                )
        });
        if (params.repay) {
            calls[2] = MultiCall({
                target: creditFacade,
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.decreaseDebt, (IERC20(underlying).balanceOf(params.creditAccount))
                    )
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
