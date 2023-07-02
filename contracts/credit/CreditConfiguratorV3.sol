// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

// LIBRARIES & CONSTANTS
import {
    DEFAULT_FEE_INTEREST,
    DEFAULT_FEE_LIQUIDATION,
    DEFAULT_LIQUIDATION_PREMIUM,
    DEFAULT_FEE_LIQUIDATION_EXPIRED,
    DEFAULT_LIQUIDATION_PREMIUM_EXPIRED,
    DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER,
    PERCENTAGE_FACTOR,
    WAD
} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {BitMask, UNDERLYING_TOKEN_MASK} from "../libraries/BitMask.sol";

// CONTRACTS
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {CreditFacadeV3} from "./CreditFacadeV3.sol";
import {CreditManagerV3} from "./CreditManagerV3.sol";

// INTERFACES
import {IAdapter} from "../interfaces/IAdapter.sol";
import {
    ICreditConfiguratorV3,
    CollateralToken,
    CreditManagerOpts,
    AllowanceAction
} from "../interfaces/ICreditConfiguratorV3.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracleV2.sol";
import {IPoolQuotaKeeperV3} from "../interfaces/IPoolQuotaKeeperV3.sol";
import "../interfaces/IAddressProviderV3.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

/// @title CreditConfiguratorV3
/// @notice This contract is used to configure Credit Managers and is the only one with the privilege
///         to call access-restricted functions
/// @dev All functions can only by called by the Configurator as per ACL.
///      Credit Manager blindly executes all requests (in nearly all cases) from Credit Configurator,
///      so most sanity checks are performed here.
contract CreditConfiguratorV3 is ICreditConfiguratorV3, ACLNonReentrantTrait {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Address for address;
    using BitMask for uint256;

    /// @notice Contract version
    uint256 public constant version = 3_00;

    /// @notice Address provider (needed for upgrading the Price Oracle)
    address public immutable override addressProvider;

    /// @notice Address of the Credit Manager
    address public immutable override creditManager;

    /// @notice Address of the Credit Manager's underlying asset
    address public immutable override underlying;

    /// @notice Set of allowed contracts
    EnumerableSet.AddressSet private allowedAdaptersSet;

    /// @notice Set of emergency liquidators
    EnumerableSet.AddressSet private emergencyLiquidatorsSet;

    /// @notice Sanity check to verify that the token is not the underlying
    modifier nonUnderlyingTokenOnly(address token) {
        _revertIfUnderlyingToken(token);
        _;
    }

    function _revertIfUnderlyingToken(address token) internal view {
        if (token == underlying) revert TokenNotAllowedException();
    }

    /// @notice Constructor has a special role in Credit Manager deployment
    /// For newly deployed CMs, this is where the initial configuration is performed.
    /// The correct deployment flow is as follows:
    ///
    /// 1. Configures CreditManagerV3 fee parameters and sets underlying LT
    /// 2. Adds collateral tokens and sets their LTs
    /// 3. Connects creditFacade and priceOracle to the Credit Manager
    /// 4. Sets itself as creditConfigurator in Credit Manager
    ///
    /// For existing Credit Manager the CC will only migrate some parameters from the previous Credit Configurator,
    /// and will otherwise keep the existing CM configuration intact.
    /// @param _creditManager CreditManagerV3 contract instance
    /// @param _creditFacade CreditFacadeV3 contract instance
    /// @param opts Configuration parameters for CreditManagerV3
    constructor(CreditManagerV3 _creditManager, CreditFacadeV3 _creditFacade, CreditManagerOpts memory opts)
        ACLNonReentrantTrait(_creditManager.addressProvider())
    {
        creditManager = address(_creditManager); // I:[CC-1]

        underlying = _creditManager.underlying(); // I:[CC-1]

        addressProvider = _creditManager.addressProvider(); // I:[CC-1]

        address currentConfigurator = CreditManagerV3(creditManager).creditConfigurator(); // I:[CC-41]

        if (currentConfigurator != address(this)) {
            // DEPLOYED FOR EXISTING CREDIT MANAGER
            // In the case where the CC is deployed for the existing Credit Manager,
            // we only need to copy several array parameters from the last CC,
            // but the existing configs must be kept intact otherwise
            // 1. Allowed contracts set stores all the connected third-party contracts - currently only used
            //    to retrieve externally
            // 2. Emergency liquidator set stores all emergency liquidators - used for parameter migration when changing the Credit Facade
            // 3. Forbidden token set stores all forbidden tokens - used for parameter migration when changing the Credit Facade

            address[] memory allowedAdaptersPrev = CreditConfiguratorV3(currentConfigurator).allowedAdapters(); // I:[CC-29]
            uint256 len = allowedAdaptersPrev.length;
            unchecked {
                for (uint256 i = 0; i < len; ++i) {
                    allowedAdaptersSet.add(allowedAdaptersPrev[i]); // I:[CC-29]
                }
            }

            address[] memory emergencyLiquidatorsPrev = CreditConfiguratorV3(currentConfigurator).emergencyLiquidators(); // I:[CC-29]
            len = emergencyLiquidatorsPrev.length;
            unchecked {
                for (uint256 i = 0; i < len; ++i) {
                    emergencyLiquidatorsSet.add(emergencyLiquidatorsPrev[i]); // I:[CC-29]
                }
            }
        } else {
            // DEPLOYED FOR NEW CREDIT MANAGER

            // Sets liquidation discounts and fees for the Credit Manager
            _setFees({
                feeInterest: DEFAULT_FEE_INTEREST,
                feeLiquidation: DEFAULT_FEE_LIQUIDATION,
                liquidationDiscount: PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM,
                feeLiquidationExpired: DEFAULT_FEE_LIQUIDATION_EXPIRED,
                liquidationDiscountExpired: PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM_EXPIRED
            }); // I:[CC-1]

            // Adds collateral tokens and sets their liquidation thresholds
            // The underlying must not be in this list, since its LT is set separately in _setFees
            uint256 len = opts.collateralTokens.length;
            unchecked {
                for (uint256 i = 0; i < len; ++i) {
                    address token = opts.collateralTokens[i].token;
                    if (token == address(0)) revert ZeroAddressException();

                    _addCollateralToken({token: token}); // I:[CC-1]
                    _setLiquidationThreshold({
                        token: token,
                        liquidationThreshold: opts.collateralTokens[i].liquidationThreshold
                    }); // I:[CC-1]
                }
            }

            // Connects creditFacade and priceOracle
            CreditManagerV3(creditManager).setCreditFacade(address(_creditFacade)); // I:[CC-1]

            emit SetCreditFacade(address(_creditFacade)); // I:[CC-1A]
            emit SetPriceOracle(CreditManagerV3(creditManager).priceOracle()); // I:[CC-1A]

            // Sets the max debt per block multiplier
            // This parameter determines the maximal new debt per block as a factor of
            // maximal Credit Account debt - essentially a cap on the number of new Credit Accounts per block
            _setMaxDebtPerBlockMultiplier(address(_creditFacade), uint8(DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER)); // I:[CC-1]

            // Sets the borrowing limits per Credit Account
            _setLimits({_creditFacade: address(_creditFacade), minDebt: opts.minDebt, maxDebt: opts.maxDebt}); // I:[CC-1]
        }
    }

    //
    // CONFIGURATION: TOKEN MANAGEMENT
    //

    /// @notice Adds token to the list of allowed collateral tokens, and sets the LT
    /// @param token Address of token to be added
    /// @param liquidationThreshold Liquidation threshold for account health calculations
    function addCollateralToken(address token, uint16 liquidationThreshold)
        external
        override
        nonZeroAddress(token)
        configuratorOnly // I:[CC-2]
    {
        _addCollateralToken({token: token}); // I:[CC-3,4]
        _setLiquidationThreshold({token: token, liquidationThreshold: liquidationThreshold}); // I:[CC-4]
    }

    /// @dev Makes all sanity checks and adds the token to the collateral token list
    /// @param token Address of token to be added
    function _addCollateralToken(address token) internal {
        // Checks that the token is a contract
        if (!token.isContract()) revert AddressIsNotContractException(token); // I:[CC-3]

        // Checks that the contract has balanceOf method
        try IERC20(token).balanceOf(address(this)) returns (uint256) {}
        catch {
            revert IncorrectTokenContractException(); // I:[CC-3]
        }

        // Checks that the token has a correct priceFeed in priceOracle
        try IPriceOracleV2(CreditManagerV3(creditManager).priceOracle()).convertToUSD({amount: WAD, token: token})
        returns (uint256) {} catch {
            revert IncorrectPriceFeedException(); // I:[CC-3]
        }

        // сreditManager has an additional check that the token is not added yet
        CreditManagerV3(creditManager).addToken({token: token}); // I:[CC-4]

        if (CreditManagerV3(creditManager).supportsQuotas() && _isQuotedToken(token)) {
            _makeTokenQuoted(token);
        }

        emit AllowToken({token: token}); // I:[CC-4]
    }

    /// @notice Sets a liquidation threshold for any token except the underlying
    /// @param token Token address
    /// @param liquidationThreshold in PERCENTAGE_FORMAT (100% = 10000)
    function setLiquidationThreshold(address token, uint16 liquidationThreshold)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        _setLiquidationThreshold({token: token, liquidationThreshold: liquidationThreshold}); // I:[CC-5]
    }

    /// @dev IMPLEMENTAION: setLiquidationThreshold
    // Checks that the token is not underlying, since its LT is determined by Credit Manager params
    function _setLiquidationThreshold(address token, uint16 liquidationThreshold)
        internal
        nonUnderlyingTokenOnly(token)
    {
        (, uint16 ltUnderlying) =
            CreditManagerV3(creditManager).collateralTokenByMask({tokenMask: UNDERLYING_TOKEN_MASK});

        // Sanity check for the liquidation threshold. The LT should be less than underlying
        if (liquidationThreshold > ltUnderlying) {
            revert IncorrectLiquidationThresholdException(); // I:[CC-5]
        }

        /// When the LT of a token is set directly, we set the parameters
        /// as if it was a ramp from `liquidationThreshold` to `liquidationThreshold`
        /// starting in far future. This ensures that the LT function in Credit Manager
        /// will always return `liquidationThreshold` until the parameters are changed
        CreditManagerV3(creditManager).setCollateralTokenData({
            token: token,
            ltInitial: liquidationThreshold,
            ltFinal: liquidationThreshold,
            timestampRampStart: type(uint40).max,
            rampDuration: 0
        }); // I:[CC-6]

        emit SetTokenLiquidationThreshold({token: token, liquidationThreshold: liquidationThreshold}); // I:[CC-6]
    }

    /// @notice Schedules an LT ramping for any token except underlying
    /// @param token Token to ramp LT for
    /// @param liquidationThresholdFinal Liquidation threshold after ramping
    /// @param rampDuration Duration of ramping
    function rampLiquidationThreshold(
        address token,
        uint16 liquidationThresholdFinal,
        uint40 rampStart,
        uint24 rampDuration
    )
        external
        override
        nonUnderlyingTokenOnly(token)
        controllerOnly // I: [CC-2B]
    {
        (, uint16 ltUnderlying) =
            CreditManagerV3(creditManager).collateralTokenByMask({tokenMask: UNDERLYING_TOKEN_MASK});
        // Sanity check for the liquidation threshold. The LT should be less than underlying
        if (liquidationThresholdFinal > ltUnderlying) {
            revert IncorrectLiquidationThresholdException(); // I:[CC-30]
        }

        // In case that (for some reason) the function is executed later than
        // the start of the ramp, we start the ramp from the current moment
        // to prevent discontinueous jumps in token's LT
        rampStart = block.timestamp > rampStart ? uint40(block.timestamp) : rampStart; // I:[CC-30]

        uint16 currentLT = CreditManagerV3(creditManager).liquidationThresholds({token: token}); // I:[CC-30]

        // CollateralTokenData in CreditManager stores 4 values: ltInitial, ltFinal, rampStart and rampDuration
        // The actual LT changes linearly between ltInitial and ltFinal over rampDuration;
        // E.g., it is ltInitial when block.timestamp == rampStart and ltFinal when block.timestamp == rampStart + rampDuration
        CreditManagerV3(creditManager).setCollateralTokenData({
            token: token,
            ltInitial: currentLT,
            ltFinal: liquidationThresholdFinal,
            timestampRampStart: rampStart,
            rampDuration: rampDuration
        }); // I:[CC-30]

        emit ScheduleTokenLiquidationThresholdRamp({
            token: token,
            liquidationThresholdInitial: currentLT,
            liquidationThresholdFinal: liquidationThresholdFinal,
            timestampRampStart: rampStart,
            timestampRampEnd: uint40(block.timestamp) + rampDuration
        }); // I:[CC-30]
    }

    /// @notice Allow a known collateral token if it was forbidden before.
    /// @param token Address of collateral token
    function allowToken(address token)
        external
        override
        nonZeroAddress(token)
        nonUnderlyingTokenOnly(token)
        configuratorOnly // I:[CC-2]
    {
        CreditFacadeV3 cf = CreditFacadeV3(creditFacade());

        // Gets token masks. Reverts if the token was not added as collateral
        uint256 tokenMask = _getTokenMaskOrRevert({token: token}); // I:[CC-7]

        // If the token was forbidden before, flips the corresponding bit in the mask,
        // otherwise no actions done.
        // Skipping case: I:[CC-8]
        if (cf.forbiddenTokenMask() & tokenMask == 0) return;

        cf.setTokenAllowance({token: token, allowance: AllowanceAction.ALLOW}); // I:[CC-8]
        emit AllowToken({token: token}); // I:[CC-8]
    }

    /// @notice Forbids a collateral token.
    /// Forbidden tokens are counted as collateral during health checks, however, they cannot be enabled
    /// or received as a result of adapter operation anymore. This means that a token can never be
    /// acquired through adapter operations after being forbidden.
    /// @param token Address of collateral token to forbid
    function forbidToken(address token)
        external
        override
        nonZeroAddress(token)
        pausableAdminsOnly // I:[CC-2A]
    {
        _forbidToken({_creditFacade: creditFacade(), token: token});
    }

    /// @dev IMPLEMENTATION: forbidToken
    function _forbidToken(address _creditFacade, address token) internal nonUnderlyingTokenOnly(token) {
        CreditFacadeV3 cf = CreditFacadeV3(_creditFacade);

        // Gets token masks. Reverts if the token was not added as collateral
        uint256 tokenMask = _getTokenMaskOrRevert({token: token}); // I:[CC-9]

        // If the token was not forbidden before, flips the corresponding bit in the mask,
        // otherwise no actions done.
        // Skipping case: I:[CC-9]
        if (cf.forbiddenTokenMask() & tokenMask != 0) return;

        cf.setTokenAllowance({token: token, allowance: AllowanceAction.FORBID}); // I:[CC-9]
        emit ForbidToken({token: token}); // I:[CC-9]
    }

    /// @notice Marks the token as limited, which enables quota logic and additional interest for it
    /// @param token Token to make limited
    /// @dev This action is irreversible!
    function makeTokenQuoted(address token)
        external
        override
        configuratorOnly // I: [CC-2]
    {
        if (!_isQuotedToken(token)) {
            revert TokenIsNotQuotedException();
        }
        _makeTokenQuoted(token);
    }

    /// @dev IMPLEMENTATION: _makeTokenQuoted
    function _makeTokenQuoted(address token) internal nonUnderlyingTokenOnly(token) {
        // Gets token masks. Reverts if the token was not added as collateral
        uint256 tokenMask = _getTokenMaskOrRevert({token: token});

        // Gets current limited mask
        uint256 quotedTokensMask = CreditManagerV3(creditManager).quotedTokensMask();

        // If the token was not limited before, flips the corresponding bit in the mask,
        // otherwise no actions done.
        if (quotedTokensMask & tokenMask != 0) return;

        CreditManagerV3(creditManager).setQuotedMask(quotedTokensMask.enable(tokenMask));
        emit QuoteToken(token);
    }

    /// @dev Checks whether the quota keeper has a token registered as quotable
    function _isQuotedToken(address token) internal view returns (bool) {
        address quotaKeeper = CreditManagerV3(creditManager).poolQuotaKeeper();
        return IPoolQuotaKeeperV3(quotaKeeper).isQuotedToken(token);
    }

    /// @dev Helper to get token mask
    function _getTokenMaskOrRevert(address token) internal view returns (uint256 tokenMask) {
        return CreditManagerV3(creditManager).getTokenMaskOrRevert(token); // I:[CC-7]
    }

    //
    // CONFIGURATION: CONTRACTS & ADAPTERS MANAGEMENT
    //

    /// @notice Adds pair [contract <-> adapter] to the list of allowed contracts
    /// or updates adapter address if a contract already has a connected adapter
    /// @dev The target contract is retrieved from the adapter
    /// @param adapter Adapter address
    function allowAdapter(address adapter)
        external
        override
        nonZeroAddress(adapter)
        configuratorOnly // I:[CC-2]
    {
        address targetContract = _getTargetContractOrRevert({adapter: adapter});
        if (!targetContract.isContract()) {
            revert AddressIsNotContractException(targetContract); // I:[CC-10A]
        }

        // Additional check that adapter or targetContract is not Credit Manager or Credit Facade.
        // Credit Manager and Credit Facade are security-critical, and calling them through adapters
        // can have unforeseen consequences.
        if (
            targetContract == creditManager || targetContract == creditFacade() || adapter == creditManager
                || adapter == creditFacade()
        ) revert TargetContractNotAllowedException(); // I:[CC-10C]

        // If there is an existing adapter for the target contract, it has to be removed
        address currentAdapter = CreditManagerV3(creditManager).contractToAdapter(targetContract);
        if (currentAdapter != address(0)) {
            CreditManagerV3(creditManager).setContractAllowance({adapter: currentAdapter, targetContract: address(0)}); // I:[CC-12]
            allowedAdaptersSet.remove(currentAdapter); // I:[CC-12]
        }

        // Sets a link between adapter and targetContract in creditFacade and creditManager
        CreditManagerV3(creditManager).setContractAllowance({adapter: adapter, targetContract: targetContract}); // I:[CC-11]

        // adds contract to the list of allowed contracts
        allowedAdaptersSet.add(adapter); // I:[CC-11]

        emit AllowAdapter({targetContract: targetContract, adapter: adapter}); // I:[CC-11]
    }

    /// @notice Forbids an adapter as a target for calls from Credit Accounts
    /// Internally, mappings that determine the adapter <> targetContract link
    /// Are reset to zero addresses
    /// @param adapter Address of an adapter to be forbidden
    function forbidAdapter(address adapter)
        external
        override
        nonZeroAddress(adapter)
        controllerOnly // I:[CC-2B]
    {
        address targetContract = _getTargetContractOrRevert({adapter: adapter});

        // Checks that adapter in the CM is the same as the passed adapter
        if (CreditManagerV3(creditManager).adapterToContract(adapter) == address(0)) {
            revert AdapterIsNotRegisteredException(); // I:[CC-13]
        }

        // Sets both contractToAdapter[targetContract] and adapterToContract[adapter]
        // To address(0), which would make Credit Manager revert on attempts to
        // call the respective targetContract using the adapter
        CreditManagerV3(creditManager).setContractAllowance({adapter: adapter, targetContract: address(0)}); // I:[CC-14]
        CreditManagerV3(creditManager).setContractAllowance({adapter: address(0), targetContract: targetContract}); // I:[CC-14]

        // removes contract from the list of allowed contracts
        allowedAdaptersSet.remove(adapter); // I:[CC-14]

        emit ForbidAdapter({targetContract: targetContract, adapter: adapter}); // I:[CC-14]
    }

    /// @dev Checks adapter compatibility and retrieves the target contract with proper error handling
    function _getTargetContractOrRevert(address adapter) internal view returns (address targetContract) {
        _revertIfContractIncompatible(adapter); // I: [CC-10, CC-10B]

        try IAdapter(adapter).targetContract() returns (address tc) {
            targetContract = tc;
        } catch {
            revert IncompatibleContractException();
        }

        if (targetContract == address(0)) revert TargetContractNotAllowedException();
    }

    //
    // CREDIT MANAGER MGMT
    //

    /// @notice Sets borrowed amount limits in Credit Facade
    /// @param minDebt Minimum borrowed amount
    /// @param maxDebt Maximum borrowed amount
    function setLimits(uint128 minDebt, uint128 maxDebt)
        external
        override
        controllerOnly // I:[CC-2B]
    {
        _setLimits(creditFacade(), minDebt, maxDebt);
    }

    /// @dev IMPLEMENTATION: setLimits
    function _setLimits(address _creditFacade, uint128 minDebt, uint128 maxDebt) internal {
        // Performs sanity checks on limits:
        // maxDebt must not be less than minDebt
        if (minDebt > maxDebt) {
            revert IncorrectLimitsException();
        } // I:[CC-15]

        CreditFacadeV3 cf = CreditFacadeV3(_creditFacade);

        // Checks that at least one limit is changed to avoid redundant events
        (uint128 currentMinDebt, uint128 currentMaxDebt) = cf.debtLimits();
        if (currentMinDebt == minDebt && currentMaxDebt == maxDebt) return;

        cf.setDebtLimits(minDebt, maxDebt, cf.maxDebtPerBlockMultiplier()); // I:[CC-16]
        emit SetBorrowingLimits(minDebt, maxDebt); // I:[CC-1A,19]
    }

    /// @notice Sets fees for creditManager
    /// @param feeInterest Percent which protocol charges additionally for interest rate
    /// @param feeLiquidation The fee that is paid to the pool from liquidation
    /// @param liquidationPremium Discount for totalValue which is given to liquidator
    /// @param feeLiquidationExpired The fee that is paid to the pool from liquidation when liquidating an expired account
    /// @param liquidationPremiumExpired Discount for totalValue which is given to liquidator when liquidating an expired account
    function setFees(
        uint16 feeInterest,
        uint16 feeLiquidation,
        uint16 liquidationPremium,
        uint16 feeLiquidationExpired,
        uint16 liquidationPremiumExpired
    )
        external
        override
        configuratorOnly // I:[CC-2]
    {
        // Checks that feeInterest and (liquidationPremium + feeLiquidation) are in range [0..10000]
        if (
            feeInterest >= PERCENTAGE_FACTOR || (liquidationPremium + feeLiquidation) >= PERCENTAGE_FACTOR
                || (liquidationPremiumExpired + feeLiquidationExpired) >= PERCENTAGE_FACTOR
        ) revert IncorrectParameterException(); // I:[CC-17]

        _setFees({
            feeInterest: feeInterest,
            feeLiquidation: feeLiquidation,
            liquidationDiscount: PERCENTAGE_FACTOR - liquidationPremium,
            feeLiquidationExpired: feeLiquidationExpired,
            liquidationDiscountExpired: PERCENTAGE_FACTOR - liquidationPremiumExpired
        });
    }

    /// @dev IMPLEMENTATION: setFees
    ///      Does sanity checks on fee params and sets them in CreditManagerV3
    function _setFees(
        uint16 feeInterest,
        uint16 feeLiquidation,
        uint16 liquidationDiscount,
        uint16 feeLiquidationExpired,
        uint16 liquidationDiscountExpired
    ) internal {
        // Computes the underlying LT and updates it if required
        uint16 newLTUnderlying = uint16(liquidationDiscount - feeLiquidation); // I:[CC-18]
        (, uint16 ltUnderlying) =
            CreditManagerV3(creditManager).collateralTokenByMask({tokenMask: UNDERLYING_TOKEN_MASK});

        if (newLTUnderlying != ltUnderlying) {
            _updateUnderlyingLT(newLTUnderlying); // I:[CC-18]
            emit SetTokenLiquidationThreshold({token: underlying, liquidationThreshold: newLTUnderlying}); // I:[CC-1A,18]
        }

        (
            uint16 _feeInterestCurrent,
            uint16 _feeLiquidationCurrent,
            uint16 _liquidationDiscountCurrent,
            uint16 _feeLiquidationExpiredCurrent,
            uint16 _liquidationDiscountExpiredCurrent
        ) = CreditManagerV3(creditManager).fees();

        // Checks that at least one parameter is changed
        if (
            (feeInterest == _feeInterestCurrent) && (feeLiquidation == _feeLiquidationCurrent)
                && (liquidationDiscount == _liquidationDiscountCurrent)
                && (feeLiquidationExpired == _feeLiquidationExpiredCurrent)
                && (liquidationDiscountExpired == _liquidationDiscountExpiredCurrent)
        ) return;

        // updates params in creditManager
        CreditManagerV3(creditManager).setFees({
            _feeInterest: feeInterest,
            _feeLiquidation: feeLiquidation,
            _liquidationDiscount: liquidationDiscount,
            _feeLiquidationExpired: feeLiquidationExpired,
            _liquidationDiscountExpired: liquidationDiscountExpired
        }); // I:[CC-19]

        emit UpdateFees({
            feeInterest: feeInterest,
            feeLiquidation: feeLiquidation,
            liquidationPremium: PERCENTAGE_FACTOR - liquidationDiscount,
            feeLiquidationExpired: feeLiquidationExpired,
            liquidationPremiumExpired: PERCENTAGE_FACTOR - liquidationDiscountExpired
        }); // I:[CC-1A,19]
    }

    /// @dev Updates Liquidation threshold for the underlying asset
    /// @param ltUnderlying New LT for the underlying
    function _updateUnderlyingLT(uint16 ltUnderlying) internal {
        CreditManagerV3(creditManager).setCollateralTokenData({
            token: underlying,
            ltInitial: ltUnderlying,
            ltFinal: ltUnderlying,
            timestampRampStart: type(uint40).max,
            rampDuration: 0
        }); // I:[CC-25]

        // An LT of an ordinary collateral token cannot be larger than the LT of underlying
        // As such, all LTs need to be checked and reduced if needed
        // NB: This action will interrupt all ongoing LT ramps
        uint256 len = CreditManagerV3(creditManager).collateralTokensCount();
        unchecked {
            for (uint256 i = 1; i < len; ++i) {
                (address token, uint16 lt) = CreditManagerV3(creditManager).collateralTokenByMask({tokenMask: 1 << i});
                if (lt > ltUnderlying) {
                    _setLiquidationThreshold({token: token, liquidationThreshold: ltUnderlying}); // I:[CC-25]
                }
            }
        }
    }

    //
    // CONTRACT UPGRADES
    //

    /// @notice Upgrades the price oracle in the Credit Manager, taking the address from the address provider
    function setPriceOracle(uint256 _version)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        address priceOracle = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_PRICE_ORACLE, _version); // I:[CC-21]

        // Checks that the price oracle is actually new to avoid emitting redundant events
        if (priceOracle == CreditManagerV3(creditManager).priceOracle()) return;

        CreditManagerV3(creditManager).setPriceOracle(priceOracle); // I:[CC-21]
        emit SetPriceOracle(priceOracle); // I:[CC-21]
    }

    /// @notice Upgrades the Credit Facade corresponding to the Credit Manager
    /// @param _creditFacade address of the new Credit Facade
    /// @param migrateParams Whether the previous Credit Facade's parameters need to be copied
    function setCreditFacade(address _creditFacade, bool migrateParams)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        // Retrieves all parameters in case they need to be migrated
        CreditFacadeV3 prevCreditFacace = CreditFacadeV3(creditFacade());

        // Checks that the Credit Facade is actually changed, to avoid any redundant actions and events
        if (_creditFacade == address(prevCreditFacace)) return;

        // Sanity checks that the address is a contract and has correct Credit Manager
        _revertIfContractIncompatible(_creditFacade); // I:[CC-20]

        // Sets Credit Facade to the new address
        CreditManagerV3(creditManager).setCreditFacade(_creditFacade); // I:[CC-22]

        if (migrateParams) {
            // Copies all limits and restrictions on borrowing
            _setMaxDebtPerBlockMultiplier(_creditFacade, prevCreditFacace.maxDebtPerBlockMultiplier()); // I:[CC-22]

            // Copy debt limits
            (uint128 minDebt, uint128 maxDebt) = prevCreditFacace.debtLimits();
            _setLimits({_creditFacade: _creditFacade, minDebt: minDebt, maxDebt: maxDebt}); // I:[CC-22]

            // Copy max cumulative loss params
            (, uint128 maxCumulativeLoss) = prevCreditFacace.lossParams();
            _setMaxCumulativeLoss(_creditFacade, maxCumulativeLoss); // I: [CC-22]

            // Migrates array-based parameters
            _migrateEmergencyLiquidators(_creditFacade); // I:[CC-22С]

            // Copy forbidden token mask
            _migrateForbiddenTokens(_creditFacade, prevCreditFacace.forbiddenTokenMask()); // I:[CC-22С]

            // Copies the expiration date if the contract is expirable
            if (prevCreditFacace.expirable()) _setExpirationDate(_creditFacade, prevCreditFacace.expirationDate()); // I:[CC-22]

            address botList = prevCreditFacace.botList();
            if (botList != address(0)) _setBotList(_creditFacade, botList); // I:[CC-22A]
        } else {
            _clearArrayCreditFacadeParams(); // I:[CC-22С]
        }

        // If credit facade tracks total debt, it copies it's value and limit if migration is on
        if (prevCreditFacace.trackTotalDebt()) {
            (uint128 currentTotalDebt, uint128 totalDebtLimit) = prevCreditFacace.totalDebt();
            _setTotalDebtParams({
                _creditFacade: _creditFacade,
                newCurrentTotalDebt: currentTotalDebt,
                newLimit: migrateParams ? totalDebtLimit : 0
            }); // I:[CC-22B]
        }

        emit SetCreditFacade(_creditFacade); // I:[CC-22]
    }

    /// @dev Internal function to migrate emergency liquidators when
    ///      updating the Credit Facade
    function _migrateEmergencyLiquidators(address _creditFacade) internal {
        uint256 len = emergencyLiquidatorsSet.length();
        unchecked {
            for (uint256 i; i < len; ++i) {
                _addEmergencyLiquidator(_creditFacade, emergencyLiquidatorsSet.at(i));
            }
        }
    }

    /// @dev Internal function to migrate forbidden tokens when
    ///      updating the Credit Facade
    function _migrateForbiddenTokens(address _creditFacade, uint256 forbiddenTokenMask) internal {
        unchecked {
            for (uint256 mask = 1; mask <= forbiddenTokenMask; mask <<= 1) {
                if (mask & forbiddenTokenMask != 0) {
                    address token = CreditManagerV3(creditManager).getTokenByMask(mask);
                    _forbidToken(_creditFacade, token);
                }
            }
        }
    }

    /// @dev Clears array-based parameters in Credit Facade
    /// @dev Needs to be done on changing a Credit Facade without migrating parameters,
    ///      in order to keep these parameters consistent between the CC and the CF
    function _clearArrayCreditFacadeParams() internal {
        uint256 len = emergencyLiquidatorsSet.length();

        unchecked {
            for (uint256 i; i < len; ++i) {
                emergencyLiquidatorsSet.remove(emergencyLiquidatorsSet.at(len - i - 1));
            }
        }
    }

    /// @notice Upgrades the Credit Configurator for a connected Credit Manager
    /// @param _creditConfigurator New Credit Configurator's address
    /// @dev After this function executes, this Credit Configurator no longer
    ///         has admin access to the Credit Manager
    function upgradeCreditConfigurator(address _creditConfigurator)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        if (_creditConfigurator == address(this)) return;

        _revertIfContractIncompatible(_creditConfigurator); // I:[CC-20]
        CreditManagerV3(creditManager).setCreditConfigurator(_creditConfigurator); // I:[CC-23]
        emit CreditConfiguratorUpgraded(_creditConfigurator); // I:[CC-23]
    }

    /// @dev Performs sanity checks that the address is a contract compatible with the Credit Manager
    function _revertIfContractIncompatible(address _contract)
        internal
        view
        nonZeroAddress(_contract) // I:[CC-12,29]
    {
        // Checks that the address is a contract
        if (!_contract.isContract()) {
            revert AddressIsNotContractException(_contract);
        } // I:[CC-12A,29]

        // Checks that the contract has a creditManager() function, which returns a correct value
        try CreditFacadeV3(_contract).creditManager() returns (address cm) {
            if (cm != creditManager) revert IncompatibleContractException(); // I:[CC-12B,29]
        } catch {
            revert IncompatibleContractException(); // I:[CC-12B,29]
        }
    }

    /// @notice Disables borrowing in Credit Facade (and, consequently, the Credit Manager)
    function forbidBorrowing()
        external
        override
        pausableAdminsOnly // I: [CC-2A]
    {
        /// This is done by setting the max debt per block multiplier to 0, which prevents all new borrowing
        _setMaxDebtPerBlockMultiplier(creditFacade(), 0); // I: [CC-24]
    }

    /// @notice Sets the max cumulative loss, which is a threshold of total loss that triggers a system pause
    function setMaxCumulativeLoss(uint128 _maxCumulativeLoss)
        external
        override
        configuratorOnly // I:[CC-02]
    {
        _setMaxCumulativeLoss(creditFacade(), _maxCumulativeLoss); // I: [CC-31]
    }

    /// @dev IMPLEMENTATION: setMaxCumulativeLoss
    function _setMaxCumulativeLoss(address _creditFacade, uint128 _maxCumulativeLoss) internal {
        CreditFacadeV3 cf = CreditFacadeV3(_creditFacade);

        (, uint128 maxCumulativeLossCurrent) = cf.lossParams(); // I: [CC-31]
        if (_maxCumulativeLoss == maxCumulativeLossCurrent) return;

        cf.setCumulativeLossParams(_maxCumulativeLoss, false); // I: [CC-31]
        emit SetMaxCumulativeLoss(_maxCumulativeLoss); // I: [CC-31]
    }

    /// @notice Resets the current cumulative loss
    function resetCumulativeLoss()
        external
        override
        configuratorOnly // I:[CC-02]
    {
        CreditFacadeV3 cf = CreditFacadeV3(creditFacade());
        (, uint128 maxCumulativeLossCurrent) = cf.lossParams(); // I: [CC-32]
        cf.setCumulativeLossParams(maxCumulativeLossCurrent, true); // I: [CC-32]
        emit ResetCumulativeLoss(); // I: [CC-32]
    }

    /// @notice Sets the maximal borrowed amount per block
    /// @param newMaxDebtLimitPerBlockMultiplier The new max borrowed amount per block
    function setMaxDebtPerBlockMultiplier(uint8 newMaxDebtLimitPerBlockMultiplier)
        external
        override
        controllerOnly // I:[CC-2B]
    {
        _setMaxDebtPerBlockMultiplier(creditFacade(), newMaxDebtLimitPerBlockMultiplier); // I:[CC-24]
    }

    /// @dev IMPLEMENTATION: _setMaxDebtPerBlockMultiplier
    function _setMaxDebtPerBlockMultiplier(address _creditFacade, uint8 newMaxDebtLimitPerBlockMultiplier) internal {
        CreditFacadeV3 cf = CreditFacadeV3(_creditFacade);

        // Checks that the limit is actually changed to avoid redundant events
        if (newMaxDebtLimitPerBlockMultiplier == cf.maxDebtPerBlockMultiplier()) return;

        (uint128 minDebt, uint128 maxDebt) = cf.debtLimits();
        cf.setDebtLimits(minDebt, maxDebt, newMaxDebtLimitPerBlockMultiplier); // I:[CC-24]
        emit SetMaxDebtPerBlockMultiplier(newMaxDebtLimitPerBlockMultiplier); // I:[CC-1A,24]
    }

    /// @notice Sets expiration date in a CreditFacadeV3 connected
    /// To a CreditManagerV3 with an expirable pool
    /// @param newExpirationDate The timestamp of the next expiration
    function setExpirationDate(uint40 newExpirationDate)
        external
        override
        controllerOnly // I:[CC-2B]
    {
        _setExpirationDate(creditFacade(), newExpirationDate); // I:[CC-25]
    }

    /// @dev IMPLEMENTATION: setExpirationDate
    function _setExpirationDate(address _creditFacade, uint40 newExpirationDate) internal {
        CreditFacadeV3 cf = CreditFacadeV3(_creditFacade);

        // Sanity checks on the new expiration date
        // The new expiration date must be later than the previous one
        // The new expiration date cannot be earlier than now
        if (block.timestamp > newExpirationDate || cf.expirationDate() >= newExpirationDate) {
            revert IncorrectExpirationDateException(); // I:[CC-25]
        }

        cf.setExpirationDate(newExpirationDate); // I:[CC-25]
        emit SetExpirationDate(newExpirationDate); // I:[CC-25]
    }

    /// @notice Sets the maximal amount of enabled tokens per Credit Account
    /// @param maxEnabledTokens The new maximal number of enabled tokens
    /// @dev A large number of enabled collateral tokens on a Credit Account
    /// can make liquidations and health checks prohibitively expensive in terms of gas,
    /// hence the number is limited
    function setMaxEnabledTokens(uint8 maxEnabledTokens)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        CreditManagerV3 cm = CreditManagerV3(creditManager);

        if (maxEnabledTokens == 0) revert IncorrectParameterException(); // I:[CC-26]

        // Checks that value is actually changed to avoid redundant events
        if (maxEnabledTokens == cm.maxEnabledTokens()) return;

        cm.setMaxEnabledTokens(maxEnabledTokens); // I:[CC-26]
        emit SetMaxEnabledTokens(maxEnabledTokens); // I:[CC-26]
    }

    /// @notice Sets the bot list contract
    /// @param _version The version of the new bot list contract
    ///                The contract address is retrieved from addressProvider
    /// @notice The bot list determines the permissions for actions
    ///         that bots can perform on Credit Accounts
    function setBotList(uint256 _version)
        external
        override
        configuratorOnly // I: [CC-2]
    {
        address botList = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_BOT_LIST, _version); // I: [CC-33]
        _setBotList(creditFacade(), botList); // I: [CC-33]
    }

    /// @dev IMPLEMENTATION: setBotList
    function _setBotList(address _creditFacade, address botList) internal {
        CreditFacadeV3 cf = CreditFacadeV3(_creditFacade);
        if (botList == cf.botList()) return;
        cf.setBotList(botList); // I: [CC-33]
        emit SetBotList(botList); // I: [CC-33]
    }

    /// @notice Adds an address to the list of emergency liquidators
    /// @param liquidator The address to add to the list
    /// @dev Emergency liquidators are trusted addresses
    /// that are able to liquidate positions while the contracts are paused,
    /// e.g. when there is a risk of bad debt while an exploit is being patched.
    function addEmergencyLiquidator(address liquidator)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        _addEmergencyLiquidator(creditFacade(), liquidator); // I:[CC-27]
    }

    /// @dev IMPLEMENTATION: addEmergencyLiquidator
    function _addEmergencyLiquidator(address _creditFacade, address liquidator) internal {
        CreditFacadeV3 cf = CreditFacadeV3(_creditFacade);

        // Checks that the address is not already in the list to avoid redundant events
        if (cf.canLiquidateWhilePaused(liquidator)) return;

        cf.setEmergencyLiquidator(liquidator, AllowanceAction.ALLOW); // I:[CC-27]
        emergencyLiquidatorsSet.add(liquidator); // I:[CC-27]
        emit AddEmergencyLiquidator(liquidator); // I:[CC-27]
    }

    /// @notice Removes an address from the list of emergency liquidators
    /// @param liquidator The address to remove from the list
    function removeEmergencyLiquidator(address liquidator)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        CreditFacadeV3 cf = CreditFacadeV3(creditFacade());

        // Checks that the address is in the list to avoid redundant events
        if (!cf.canLiquidateWhilePaused(liquidator)) return;

        cf.setEmergencyLiquidator(liquidator, AllowanceAction.FORBID); // I:[CC-28]
        emergencyLiquidatorsSet.remove(liquidator); // I:[CC-28]
        emit RemoveEmergencyLiquidator(liquidator); // I:[CC-28]
    }

    /// @notice Sets a new total debt limit
    /// @dev Only works for Credit Facades that track total debt limit
    /// @param newLimit New total debt limit
    function setTotalDebtLimit(uint128 newLimit)
        external
        override
        controllerOnly // I: [CC-2]
    {
        CreditFacadeV3 cf = CreditFacadeV3(creditFacade());
        if (!cf.trackTotalDebt()) revert TotalDebtNotTrackedException(); // I:[CC-34]
        _setTotalDebtLimit(address(cf), newLimit); // I:[CC-34]
    }

    /// @notice Sets both current total debt and total debt limit, only used during Credit Facade migration
    /// @dev Only works for Credit Facades that track total debt limit
    /// @param newCurrentTotalDebt New current total debt
    /// @param newLimit New total debt limit
    function setTotalDebtParams(uint128 newCurrentTotalDebt, uint128 newLimit)
        external
        override
        configuratorOnly // I: [CC-2]
    {
        CreditFacadeV3 cf = CreditFacadeV3(creditFacade());
        if (!cf.trackTotalDebt()) revert TotalDebtNotTrackedException(); // I:[CC-34]
        _setTotalDebtParams(address(cf), newCurrentTotalDebt, newLimit); // I:[CC-34]
    }

    /// @dev IMPLEMENTATION: setTotalDebtLimit
    function _setTotalDebtLimit(address _creditFacade, uint128 newLimit) internal {
        (uint128 totalDebtCurrent, uint128 totalDebtLimitCurrent) = CreditFacadeV3(_creditFacade).totalDebt(); // I:[CC-34]
        if (newLimit != totalDebtLimitCurrent) {
            _setTotalDebtParams(_creditFacade, totalDebtCurrent, newLimit); // I:[CC-34]
        }
    }

    /// @dev IMPLEMENTATION: setTotalDebtParams
    function _setTotalDebtParams(address _creditFacade, uint128 newCurrentTotalDebt, uint128 newLimit) internal {
        CreditFacadeV3(_creditFacade).setTotalDebtParams({newCurrentTotalDebt: newCurrentTotalDebt, newLimit: newLimit});
        emit SetTotalDebtLimit(newLimit);
    }

    //
    // GETTERS
    //

    /// @notice Returns all allowed adapters
    function allowedAdapters() external view override returns (address[] memory) {
        return allowedAdaptersSet.values();
    }

    /// @notice Returns all emergency liquidators
    function emergencyLiquidators() external view override returns (address[] memory) {
        return emergencyLiquidatorsSet.values();
    }

    /// @notice Returns the Credit Facade currently connected to the Credit Manager
    function creditFacade() public view override returns (address) {
        return CreditManagerV3(creditManager).creditFacade();
    }
}
