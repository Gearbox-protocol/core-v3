// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

enum AllowanceAction {
    FORBID,
    ALLOW
}

/// @notice Struct with credit manager configuration parameters
/// @param minDebt Minimum debt amount per account
/// @param maxDebt Maximum debt amount per account
/// @param degenNFT Whether to apply Degen NFT whitelist logic
/// @param expirable Whether facade must be expirable
/// @param name Credit manager name
struct CreditManagerOpts {
    uint128 minDebt;
    uint128 maxDebt;
    address degenNFT;
    bool expirable;
    string name;
}

interface ICreditConfiguratorV3Events {
    // ------ //
    // TOKENS //
    // ------ //

    /// @notice Emitted when a token is made recognizable as collateral in the credit manager
    event AddCollateralToken(address indexed token);

    /// @notice Emitted when a new collateral token liquidation threshold is set
    event SetTokenLiquidationThreshold(address indexed token, uint16 liquidationThreshold);

    /// @notice Emitted when a collateral token liquidation threshold ramping is scheduled
    event ScheduleTokenLiquidationThresholdRamp(
        address indexed token,
        uint16 liquidationThresholdInitial,
        uint16 liquidationThresholdFinal,
        uint40 timestampRampStart,
        uint40 timestampRampEnd
    );

    /// @notice Emitted when a collateral token is forbidden
    event ForbidToken(address indexed token);

    /// @notice Emitted when a previously forbidden collateral token is allowed
    event AllowToken(address indexed token);

    /// @notice Emitted when a token is made quoted
    event QuoteToken(address indexed token);

    // -------- //
    // ADAPTERS //
    // -------- //

    /// @notice Emitted when a new adapter and its target contract are allowed in the credit manager
    event AllowAdapter(address indexed targetContract, address indexed adapter);

    /// @notice Emitted when adapter and its target contract are forbidden in the credit manager
    event ForbidAdapter(address indexed targetContract, address indexed adapter);

    // -------------- //
    // CREDIT MANAGER //
    // -------------- //

    /// @notice Emitted when a new maximum number of enabled tokens is set in the credit manager
    event SetMaxEnabledTokens(uint8 maxEnabledTokens);

    /// @notice Emitted when new fee parameters are set in the credit manager
    event UpdateFees(
        uint16 feeInterest,
        uint16 feeLiquidation,
        uint16 liquidationPremium,
        uint16 feeLiquidationExpired,
        uint16 liquidationPremiumExpired
    );

    // -------- //
    // UPGRADES //
    // -------- //

    /// @notice Emitted when a new price oracle is set in the credit manager
    event SetPriceOracle(address indexed priceOracle);

    /// @notice Emitted when a new bot list is set in the credit facade
    event SetBotList(address indexed botList);

    /// @notice Emitted when a new facade is connected to the credit manager
    event SetCreditFacade(address indexed creditFacade);

    /// @notice Emitted when credit manager's configurator contract is upgraded
    event CreditConfiguratorUpgraded(address indexed creditConfigurator);

    // ------------- //
    // CREDIT FACADE //
    // ------------- //

    /// @notice Emitted when new debt principal limits are set
    event SetBorrowingLimits(uint256 minDebt, uint256 maxDebt);

    /// @notice Emitted when a new max debt per block multiplier is set
    event SetMaxDebtPerBlockMultiplier(uint8 maxDebtPerBlockMultiplier);

    /// @notice Emitted when a new max cumulative loss is set
    event SetMaxCumulativeLoss(uint128 maxCumulativeLoss);

    /// @notice Emitted when cumulative loss is reset to zero in the credit facade
    event ResetCumulativeLoss();

    /// @notice Emitted when a new expiration timestamp is set in the credit facade
    event SetExpirationDate(uint40 expirationDate);

    /// @notice Emitted when an address is added to the list of emergency liquidators
    event AddEmergencyLiquidator(address indexed liquidator);

    /// @notice Emitted when an address is removed from the list of emergency liquidators
    event RemoveEmergencyLiquidator(address indexed liquidator);
}

/// @title Credit configurator V3 interface
interface ICreditConfiguratorV3 is IVersion, ICreditConfiguratorV3Events {
    function addressProvider() external view returns (address);

    function creditManager() external view returns (address);

    function creditFacade() external view returns (address);

    function underlying() external view returns (address);

    // ------ //
    // TOKENS //
    // ------ //

    function addCollateralToken(address token, uint16 liquidationThreshold) external;

    function setLiquidationThreshold(address token, uint16 liquidationThreshold) external;

    function rampLiquidationThreshold(
        address token,
        uint16 liquidationThresholdFinal,
        uint40 rampStart,
        uint24 rampDuration
    ) external;

    function forbidToken(address token) external;

    function allowToken(address token) external;

    function makeTokenQuoted(address token) external;

    // -------- //
    // ADAPTERS //
    // -------- //

    function allowedAdapters() external view returns (address[] memory);

    function allowAdapter(address adapter) external;

    function forbidAdapter(address adapter) external;

    // -------------- //
    // CREDIT MANAGER //
    // -------------- //

    function setFees(
        uint16 feeInterest,
        uint16 feeLiquidation,
        uint16 liquidationPremium,
        uint16 feeLiquidationExpired,
        uint16 liquidationPremiumExpired
    ) external;

    function setMaxEnabledTokens(uint8 newMaxEnabledTokens) external;

    // -------- //
    // UPGRADES //
    // -------- //

    function setPriceOracle(uint256 newVersion) external;

    function setBotList(uint256 newVersion) external;

    function setCreditFacade(address newCreditFacade, bool migrateParams) external;

    function upgradeCreditConfigurator(address newCreditConfigurator) external;

    // ------------- //
    // CREDIT FACADE //
    // ------------- //

    function setMinDebtLimit(uint128 newMinDebt) external;

    function setMaxDebtLimit(uint128 newMaxDebt) external;

    function setMaxDebtPerBlockMultiplier(uint8 newMaxDebtLimitPerBlockMultiplier) external;

    function forbidBorrowing() external;

    function setMaxCumulativeLoss(uint128 newMaxCumulativeLoss) external;

    function resetCumulativeLoss() external;

    function setExpirationDate(uint40 newExpirationDate) external;

    function emergencyLiquidators() external view returns (address[] memory);

    function addEmergencyLiquidator(address liquidator) external;

    function removeEmergencyLiquidator(address liquidator) external;
}
