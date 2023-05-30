// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {CreditManagerV3} from "../credit/CreditManagerV3.sol";
import {CreditFacadeV3} from "../credit/CreditFacadeV3.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

enum AllowanceAction {
    FORBID,
    ALLOW
}

/// @dev A struct containing parameters for a recognized collateral token in the system
struct CollateralToken {
    /// @dev Address of the collateral token
    address token;
    /// @dev Address of the liquidation threshold
    uint16 liquidationThreshold;
}

/// @dev A struct representing the initial Credit Manager configuration parameters
struct CreditManagerOpts {
    /// @dev The minimal debt principal amount
    uint128 minDebt;
    /// @dev The maximal debt principal amount
    uint128 maxDebt;
    /// @dev The initial list of collateral tokens to allow
    CollateralToken[] collateralTokens;
    /// @dev Address of IDegenNFTV2, address(0) if whitelisted mode is not used
    address degenNFT;
    /// @dev Address of BlacklistHelper, address(0) if the underlying is not blacklistable
    address withdrawalManager;
    /// @dev Whether the Credit Manager is connected to an expirable pool (and the CreditFacadeV3 is expirable)
    bool expirable;
}

interface ICreditConfiguratorEvents {
    /// @dev Emits when a collateral token's liquidation threshold is changed
    event SetTokenLiquidationThreshold(address indexed token, uint16 liquidationThreshold);

    event ScheduleTokenLiquidationThresholdRamp(
        address indexed token,
        uint16 liquidationThresholdInitial,
        uint16 liquidationThresholdFinal,
        uint40 timestampRampStart,
        uint40 timestampRampEnd
    );

    /// @dev Emits when a new or a previously forbidden token is allowed
    event AllowToken(address indexed token);

    /// @dev Emits when a collateral token is forbidden
    event ForbidToken(address indexed token);

    /// @dev Emits when a contract <> adapter pair is linked for a Credit Manager
    event AllowAdapter(address indexed targetContract, address indexed adapter);

    /// @dev Emits when an adapter is forbidden
    event ForbidAdapter(address indexed targetContract, address indexed adapter);

    /// @dev Emits when debt principal limits are changed
    event SetBorrowingLimits(uint256 minDebt, uint256 maxDebt);

    /// @dev Emits when Credit Manager's fee parameters are updated
    event UpdateFees(
        uint16 feeInterest,
        uint16 feeLiquidation,
        uint16 liquidationPremium,
        uint16 feeLiquidationExpired,
        uint16 liquidationPremiumExpired
    );

    /// @dev Emits when a new Price Oracle is connected to the Credit Manager
    event SetPriceOracle(address indexed newPriceOracle);

    /// @dev Emits when a new Credit Facade is connected to the Credit Manager
    event SetCreditFacade(address indexed newCreditFacade);

    /// @dev Emits when a new Credit Configurator is connected to the Credit Manager
    event CreditConfiguratorUpgraded(address indexed newCreditConfigurator);

    /// @dev Emits when the status of the debt increase restriction is changed
    event AllowBorrowing(); // F:[CC-32]

    /// @dev Emits when the status of the debt increase restriction is changed
    event ForbidBorrowing();

    /// @dev Emits when the borrowing limit per block is changed
    event SetMaxDebtPerBlockMultiplier(uint8);

    /// @dev Emits when the expiration date is updated in an expirable Credit Facade
    event SetExpirationDate(uint40);

    /// @dev Emits when the enabled token limit is updated
    event SetMaxEnabledTokens(uint8);

    /// @dev Emits when an address is added to the list of emergency liquidators
    event AddEmergencyLiquidator(address);

    /// @dev Emits when an address is removed from the list of emergency liquidators
    event RemoveEmergencyLiquidator(address);

    /// @dev Emits when the bot list is updated in Credit Facade
    event SetBotList(address);

    /// @dev Emits when the token is set as limited
    event QuoteToken(address);

    /// @dev Emits when new max cumulative loss is set
    event SetMaxCumulativeLoss(uint128);

    /// @dev Emits when the current cumulative loss in Credit Facade is reset
    event ResetCumulativeLoss();

    /// @dev Emits when new total debt limit is set
    event SetTotalDebtLimit(uint128);
}

/// @dev CreditConfiguratorV3 Exceptions

interface ICreditConfiguratorV3 is ICreditConfiguratorEvents, IVersion {
    //
    // STATE-CHANGING FUNCTIONS
    //

    /// @dev Adds token to the list of allowed collateral tokens, and sets the LT
    /// @param token Address of token to be added
    /// @param liquidationThreshold Liquidation threshold for account health calculations
    function addCollateralToken(address token, uint16 liquidationThreshold) external;

    /// @dev Sets a liquidation threshold for any token except the underlying
    /// @param token Token address
    /// @param liquidationThreshold in PERCENTAGE_FORMAT (100% = 10000)
    function setLiquidationThreshold(address token, uint16 liquidationThreshold) external;

    /// @dev Schedules an LT ramping for any token except underlying
    /// @param token Token to ramp LT for
    /// @param liquidationThresholdFinal Liquidation threshold after ramping
    /// @param rampDuration Duration of ramping
    function rampLiquidationThreshold(
        address token,
        uint16 liquidationThresholdFinal,
        uint40 rampStart,
        uint24 rampDuration
    ) external;

    /// @dev Allow a known collateral token if it was forbidden before.
    /// @param token Address of collateral token
    function allowToken(address token) external;

    /// @dev Forbids a collateral token.
    /// Forbidden tokens are counted as collateral during health checks, however, they cannot be enabled
    /// or received as a result of adapter operation anymore. This means that a token can never be
    /// acquired through adapter operations after being forbidden.
    /// @param token Address of collateral token to forbid
    function forbidToken(address token) external;

    /// @dev Adds pair [contract <-> adapter] to the list of allowed contracts
    /// or updates adapter address if a contract already has a connected adapter
    /// @dev The target contract is retrieved from the adapter
    /// @param adapter Adapter address
    function allowAdapter(address adapter) external;

    /// @dev Forbids contract as a target for calls from Credit Accounts
    /// @param targetContract Address of a contract to be forbidden
    function forbidAdapter(address targetContract) external;

    /// @dev Sets borrowed amount limits in Credit Facade
    /// @param minDebt Minimum borrowed amount
    /// @param maxDebt Maximum borrowed amount
    function setLimits(uint128 minDebt, uint128 maxDebt) external;

    /// @dev Sets fees for creditManager
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
    ) external;

    /// @dev Upgrades the price oracle in the Credit Manager, taking the address
    /// from the address provider
    function setPriceOracle(uint256 version) external;

    /// @dev Upgrades the Credit Facade corresponding to the Credit Manager
    /// @param creditFacade address of the new CreditFacadeV3
    /// @param migrateParams Whether the previous CreditFacadeV3's parameter need to be copied
    function setCreditFacade(address creditFacade, bool migrateParams) external;

    /// @dev Upgrades the Credit Configurator for a connected Credit Manager
    /// @param creditConfigurator New Credit Configurator's address
    function upgradeCreditConfigurator(address creditConfigurator) external;

    /// @dev Sets the maximal borrowed amount per block as multiplier to maxDebt
    function setMaxDebtPerBlockMultiplier(uint8 newMaxDebtLimitPerBlockMultiplier) external;

    /// @dev Sets expiration date in a CreditFacadeV3 connected
    /// To a CreditManagerV3 with an expirable pool
    /// @param newExpirationDate The timestamp of the next expiration
    function setExpirationDate(uint40 newExpirationDate) external;

    /// @dev Sets the maximal amount of enabled tokens per Credit Account
    /// @param maxEnabledTokens The new maximal number of enabled tokens
    /// @notice A large number of enabled collateral tokens on a Credit Account
    /// can make liquidations and health checks prohibitively expensive in terms of gas,
    /// hence the number is limited
    function setMaxEnabledTokens(uint8 maxEnabledTokens) external;

    /// @dev Adds an address to the list of emergency liquidators
    /// @param liquidator The address to add to the list
    /// @notice Emergency liquidators are trusted addresses
    /// that are able to liquidate positions while the contracts are paused,
    /// e.g. when there is a risk of bad debt while an exploit is being patched.
    /// In the interest of fairness, emergency liquidators do not receive a premium
    /// And are compensated by the Gearbox DAO separately.
    function addEmergencyLiquidator(address liquidator) external;

    /// @dev Removex an address frp, the list of emergency liquidators
    /// @param liquidator The address to remove from the list
    function removeEmergencyLiquidator(address liquidator) external;

    /// @dev Sets the max cumulative loss, which is a threshold of total loss that triggers a system pause
    /// @param _maxCumulativeLoss The new value for maximal cumulative loss
    function setMaxCumulativeLoss(uint128 _maxCumulativeLoss) external;

    /// @dev Resets the current cumulative loss in Credit Facade
    function resetCumulativeLoss() external;

    /// @notice Disables borrowing in Credit Facade
    function forbidBorrowing() external;

    /// @dev Sets the bot list contract
    /// @param version The version of the new bot list contract
    ///                The contract address is retrieved from addressProvider
    function setBotList(uint256 version) external;

    /// @notice Sets a new total debt limit
    /// @dev Only works for Credit Facades that track total debt limit
    /// @param newLimit New total debt limit for Credit Manager
    function setTotalDebtLimit(uint128 newLimit) external;

    /// @notice Sets both current total debt and total debt limit, only used during Credit Facade migration
    /// @dev Only works for Credit Facades that track total debt limit
    /// @param newCurrentTotalDebt New current total debt
    /// @param newLimit New total debt limit
    function setTotalDebtParams(uint128 newCurrentTotalDebt, uint128 newLimit) external;

    /// @notice Marks the token as limited, which enables quota logic and additional interest for it
    /// @param token Token to make limited
    /// @dev This action is irreversible!
    function makeTokenQuoted(address token) external;

    //
    // GETTERS
    //

    /// @dev Address provider (needed for upgrading the Price Oracle)
    function addressProvider() external view returns (address);

    /// @dev Returns the Credit Facade currently connected to the Credit Manager
    function creditFacade() external view returns (address);

    /// @dev Address of the Credit Manager
    function creditManager() external view returns (address);

    /// @dev Address of the Credit Manager's underlying asset
    function underlying() external view returns (address);

    /// @dev Returns all allowed adapters
    function allowedAdapters() external view returns (address[] memory);

    /// @dev Returns all emergency liquidators
    function emergencyLiquidators() external view returns (address[] memory);
}
