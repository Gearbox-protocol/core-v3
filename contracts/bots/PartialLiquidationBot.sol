// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IAddressProviderV3.sol";
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
    /// @notice Minimal health factor of account after liquidation
    uint16 public constant THRESHOLD_HEALTH_FACTOR = 10200;

    /// @notice Address of the Gearbox DAO treasury
    address public immutable treasury;

    constructor(address _addressProvider) {
        treasury = IAddressProviderV3(_addressProvider).getAddressOrRevert(AP_TREASURY, NO_VERSION_CONTROL);
    }

    /// @notice Performs a partial liquidation by swapping some CA collateral to underlying at a discount.
    ///         Accepts the amount of underlying that the liquidator is willing to spend
    /// @param creditManager Credit Manager where the account resides
    /// @param creditAccount Credit Account to liquidate
    /// @param assetOut Asset to receive for underlying
    /// @param amountIn Amount of underlying to pay. Note that depending on the CA's balance in assetOut and
    ///                 the maximal swappable amount of underlying, the actual spent amount may be less
    /// @param repay Whether to repay debt or only perform a swap
    /// @param priceUpdates Data for updatable price feeds, if any are required to compute account health
    function partialLiquidateExactIn(
        address creditManager,
        address creditAccount,
        address assetOut,
        uint256 amountIn,
        address to,
        bool repay,
        PriceUpdate[] memory priceUpdates
    ) external returns (uint256, uint256) {
        LiquidationParams memory params =
            _prepareParams(creditManager, creditAccount, assetOut, amountIn, 0, to, repay, true);

        /// Since we are computing debt and collateral before liquidation,
        /// we need to update prices beforehand, if needed
        _applyPriceUpdates(priceUpdates, params.priceOracle);

        _retrieveAndCheckDebt(params);

        _liquidate(params);

        return (params.amountIn, params.amountOut);
    }

    /// @notice Performs a partial liquidation by swapping some CA collateral to underlying at a discount.
    ///         Accepts the amount of assetOut that the liquidator wishes to receive
    /// @param creditManager Credit Manager where the account resides
    /// @param creditAccount Credit Account to liquidate
    /// @param assetOut Asset to receive for underlying
    /// @param amountOut Amount of assetOut to receive. Note that depending on the CA's balance in assetOut and
    ///                 the maximal swappable amount of underlying, the actual received amount may be less
    ///                 (with the spent amount adjusted accordingly)
    /// @param repay Whether to repay debt or only perform a swap
    /// @param priceUpdates Data for updatable price feeds, if any are required to compute account health
    function partialLiquidateExactOut(
        address creditManager,
        address creditAccount,
        address assetOut,
        uint256 amountOut,
        address to,
        bool repay,
        PriceUpdate[] memory priceUpdates
    ) external returns (uint256, uint256) {
        LiquidationParams memory params =
            _prepareParams(creditManager, creditAccount, assetOut, 0, amountOut, to, repay, false);

        /// Since we are computing debt and collateral before liquidation,
        /// we need to update prices beforehand, if needed
        _applyPriceUpdates(priceUpdates, params.priceOracle);

        _retrieveAndCheckDebt(params);

        _liquidate(params);

        return (params.amountIn, params.amountOut);
    }

    /// @dev Internal function that prepares the parameter struct
    function _prepareParams(
        address creditManager,
        address creditAccount,
        address assetOut,
        uint256 amountIn,
        uint256 amountOut,
        address to,
        bool repay,
        bool exactIn
    ) internal view returns (LiquidationParams memory params) {
        params.creditManager = creditManager;
        params.creditAccount = creditAccount;
        params.assetOut = assetOut;
        params.amountIn = amountIn;
        params.amountOut = amountOut;
        params.exactIn = exactIn;
        params.repay = repay;
        params.to = to;
        params.creditFacade = ICreditManagerV3(creditManager).creditFacade();
        params.cmVersion = ICreditManagerV3(creditManager).version();
        params.underlying = ICreditManagerV3(creditManager).underlying();
        params.priceOracle = ICreditManagerV3(creditManager).priceOracle();

        // Passing the underlying as assetOut and repaying would allow the liquidator to make
        // profit without actually meaningfully changing account health, hence this is prohibited
        if (params.underlying == params.assetOut) revert CantPartialLiquidateUnderlying();
    }

    /// @dev Internal function that retrieves the current account's debt and checks that it is liquidatable
    function _retrieveAndCheckDebt(LiquidationParams memory params) internal view {
        CollateralDebtData memory cdd = ICreditManagerV3(params.creditManager).calcDebtAndCollateral(
            params.creditAccount, CollateralCalcTask.DEBT_COLLATERAL
        );

        if (cdd.twvUSD >= cdd.totalDebtUSD) revert CreditAccountNotLiquidatableException();

        params.totalDebt = CreditLogic.calcTotalDebt(cdd);
    }

    /// @dev Internal function implementing the main liquidation logic
    ///      1. Determines the maximal amount of underlying that can be sold and maximal amount of assetOut that can be bought
    ///      2. Computes the input and output amounts
    ///      3. Transfers underlying from caller to Credit Account
    ///      4. Performs a multicall to enable the underlying and transfer assetOut to caller (and optionally decrease debt)
    ///      5. Checks that the resulting HF is above the minimal threshold
    function _liquidate(LiquidationParams memory params) internal {
        uint256 maxAmountIn;
        uint256 maxAmountOut;
        {
            uint256 underlyingBalance = IERC20(params.underlying).balanceOf(params.creditAccount);
            (uint256 minDebt,) = ICreditFacadeV3(params.creditFacade).debtLimits();

            uint256 repayable;

            // If the liquidation is with repayment, the maximal amount of underlying is exactly enough to repay until minDebt
            // If there is no repayment, we allow to fill up the account up to the totalDebt + a 1% buffer to cover future interest

            if (params.repay) {
                repayable = params.totalDebt - minDebt;
            } else {
                repayable = params.totalDebt;
            }

            if (underlyingBalance >= repayable) revert NothingToLiquidateException();

            maxAmountIn = repayable - underlyingBalance;
            maxAmountOut = IERC20(params.assetOut).balanceOf(params.creditAccount);
        }

        if (params.exactIn) {
            (params.amountIn, params.amountOut, params.amountFee) =
                _getAmountsExactIn(params, maxAmountIn, maxAmountOut);
        } else {
            params.amountOut = params.amountOut == type(uint256).max ? maxAmountOut : params.amountOut;
            (params.amountIn, params.amountOut, params.amountFee) =
                _getAmountsExactOut(params, maxAmountIn, maxAmountOut);
        }

        IERC20(params.underlying).transferFrom(msg.sender, params.creditAccount, params.amountIn - params.amountFee);
        IERC20(params.underlying).transferFrom(msg.sender, treasury, params.amountFee);

        ICreditFacadeV3(params.creditFacade).botMulticall(params.creditAccount, _getMultiCall(params));

        if (params.cmVersion == 3_00) {
            CollateralDebtData memory cdd = ICreditManagerV3(params.creditManager).calcDebtAndCollateral(
                params.creditAccount, CollateralCalcTask.DEBT_COLLATERAL
            );

            if (cdd.twvUSD * PERCENTAGE_FACTOR < cdd.totalDebtUSD * THRESHOLD_HEALTH_FACTOR) {
                revert HealthFactorTooLowException();
            }
        }
    }

    /// @dev Computes the amount of underlying to pay and assetOut to receive, given explicit amountIn
    /// @dev The actual sum sold can be smaller than passed amountIn, as it is constrained by
    ///      current assetOut balance and the maximal swappable underlying amount
    function _getAmountsExactIn(LiquidationParams memory params, uint256 maxAmountIn, uint256 maxAmountOut)
        internal
        view
        returns (uint256, uint256, uint256)
    {
        uint16 liquidationDiscount;
        uint256 amountIn;
        uint256 amountFee;

        {
            uint16 feeLiquidation;
            (, feeLiquidation, liquidationDiscount,,) = ICreditManagerV3(params.creditManager).fees();

            maxAmountIn = maxAmountIn * PERCENTAGE_FACTOR / (PERCENTAGE_FACTOR - feeLiquidation) - 1;

            amountIn = Math.min(params.amountIn, maxAmountIn);
            amountFee = amountIn * feeLiquidation / PERCENTAGE_FACTOR;
        }

        uint256 assetOutEquivalent = IPriceOracleV3(params.priceOracle).convert(
            amountIn, params.underlying, params.assetOut
        ) * PERCENTAGE_FACTOR / liquidationDiscount;

        // If the computed amount of assetOut is larger than balance, then only the max amount is bought,
        // and the amount of underlying is adjusted proportionally
        if (assetOutEquivalent > maxAmountOut) {
            return (
                amountIn * maxAmountOut / assetOutEquivalent,
                maxAmountOut,
                amountFee * maxAmountOut / assetOutEquivalent
            );
        } else {
            return (amountIn, assetOutEquivalent, amountFee);
        }
    }

    /// @dev Computes the amount of underlying to pay and assetOut to receive, given explicit amountOut
    /// @dev The actual sum bought can be smaller than passed amountOut, as it is constrained by
    ///      current assetOut balance and the maximal swappable underlying amount
    function _getAmountsExactOut(LiquidationParams memory params, uint256 maxAmountIn, uint256 maxAmountOut)
        internal
        view
        returns (uint256, uint256, uint256)
    {
        (, uint16 feeLiquidation, uint16 liquidationDiscount,,) = ICreditManagerV3(params.creditManager).fees();

        maxAmountIn = maxAmountIn * PERCENTAGE_FACTOR / (PERCENTAGE_FACTOR - feeLiquidation) - 1;

        uint256 amountOut = Math.min(params.amountOut, maxAmountOut);

        uint256 underlyingEquivalent = IPriceOracleV3(params.priceOracle).convert(
            amountOut, params.assetOut, params.underlying
        ) * liquidationDiscount / PERCENTAGE_FACTOR;
        uint256 amountFee = underlyingEquivalent * feeLiquidation / PERCENTAGE_FACTOR;

        // If the computed amount of underlying is larger than max amount, then only the max amount is paid,
        // and the amount of assetOut is adjusted proportionally
        if (underlyingEquivalent > maxAmountIn) {
            return (
                maxAmountIn,
                amountOut * maxAmountIn / underlyingEquivalent,
                amountFee * maxAmountIn / underlyingEquivalent
            );
        } else {
            return (underlyingEquivalent, amountOut, amountFee);
        }
    }

    /// @dev Returns the multicall to execute in Credit Facade
    function _getMultiCall(LiquidationParams memory params) internal view returns (MultiCall[] memory calls) {
        calls = new MultiCall[](2 + (params.repay ? 1 : 0) + (params.cmVersion > 3_00 ? 1 : 0));

        calls[0] = MultiCall({
            target: params.creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.enableToken, (params.underlying))
        });

        calls[1] = MultiCall({
            target: params.creditFacade,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.withdrawCollateral, (params.assetOut, params.amountOut, params.to)
                )
        });
        if (params.repay) {
            calls[2] = MultiCall({
                target: params.creditFacade,
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.decreaseDebt, (IERC20(params.underlying).balanceOf(params.creditAccount))
                    )
            });
        }

        if (params.cmVersion > 3_00) {
            calls[calls.length - 1] = MultiCall({
                target: params.creditFacade,
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.setFullCheckParams, (new uint256[](0), THRESHOLD_HEALTH_FACTOR)
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
