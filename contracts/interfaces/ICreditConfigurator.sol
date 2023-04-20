// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {IAddressProvider} from "@gearbox-protocol/core-v2/contracts/interfaces/IAddressProvider.sol";
import {CreditManagerV3} from "../credit/CreditManagerV3.sol";
import {CreditFacadeV3} from "../credit/CreditFacadeV3.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

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
    uint128 minBorrowedAmount;
    /// @dev The maximal debt principal amount
    uint128 maxBorrowedAmount;
    /// @dev The initial list of collateral tokens to allow
    CollateralToken[] collateralTokens;
    /// @dev Address of DegenNFT, address(0) if whitelisted mode is not used
    address degenNFT;
    /// @dev Address of BlacklistHelper, address(0) if the underlying is not blacklistable
    address blacklistHelper;
    /// @dev Whether the Credit Manager is connected to an expirable pool (and the CreditFacadeV3 is expirable)
    bool expirable;
}

interface ICreditConfiguratorEvents {
    /// @dev Emits when a collateral token's liquidation threshold is changed
    event SetTokenLiquidationThreshold(address indexed token, uint16 liquidityThreshold);

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
    event AllowContract(address indexed protocol, address indexed adapter);

    /// @dev Emits when a 3rd-party contract is forbidden
    event ForbidContract(address indexed protocol);

    /// @dev Emits when a particular adapter for a target contract is forbidden
    event ForbidAdapter(address indexed adapter);

    /// @dev Emits when debt principal limits are changed
    event SetBorrowingLimits(uint256 minBorrowedAmount, uint256 maxBorrowedAmount);

    /// @dev Emits when Credit Manager's fee parameters are updated
    event FeesUpdated(
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
    event SetIncreaseDebtForbiddenMode(bool);

    /// @dev Emits when the borrowing limit per block is changed
    event SetBorrowingLimitPerBlock(uint128);

    /// @dev Emits when an address is added to the upgradeable contract list
    event AddedToUpgradeable(address);

    /// @dev Emits when an address is removed from the upgradeable contract list
    event RemovedFromUpgradeable(address);

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
    event LimitToken(address);

    /// @dev Emits when new max cumulative loss is set
    event SetMaxCumulativeLoss(uint128);

    /// @dev Emits when the current cumulative loss in Credit Facade is reset
    event ResetCumulativeLoss();
}

/// @dev CreditConfigurator Exceptions

interface ICreditConfigurator is ICreditConfiguratorEvents, IVersion {
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
    /// @param targetContract Address of allowed contract
    /// @param adapter Adapter address
    function allowContract(address targetContract, address adapter) external;

    /// @dev Forbids contract as a target for calls from Credit Accounts
    /// @param targetContract Address of a contract to be forbidden
    function forbidContract(address targetContract) external;

    /// @dev Forbids adapter (and only the adapter - the target contract is not affected)
    /// @param adapter Address of adapter to disable
    /// @notice Used to clean up orphaned adapters
    function forbidAdapter(address adapter) external;

    /// @dev Sets borrowed amount limits in Credit Facade
    /// @param _minBorrowedAmount Minimum borrowed amount
    /// @param _maxBorrowedAmount Maximum borrowed amount
    function setLimits(uint128 _minBorrowedAmount, uint128 _maxBorrowedAmount) external;

    /// @dev Sets fees for creditManager
    /// @param _feeInterest Percent which protocol charges additionally for interest rate
    /// @param _feeLiquidation The fee that is paid to the pool from liquidation
    /// @param _liquidationPremium Discount for totalValue which is given to liquidator
    /// @param _feeLiquidationExpired The fee that is paid to the pool from liquidation when liquidating an expired account
    /// @param _liquidationPremiumExpired Discount for totalValue which is given to liquidator when liquidating an expired account
    function setFees(
        uint16 _feeInterest,
        uint16 _feeLiquidation,
        uint16 _liquidationPremium,
        uint16 _feeLiquidationExpired,
        uint16 _liquidationPremiumExpired
    ) external;

    /// @dev Upgrades the price oracle in the Credit Manager, taking the address
    /// from the address provider
    function upgradePriceOracle() external;

    /// @dev Upgrades the Credit Facade corresponding to the Credit Manager
    /// @param _creditFacade address of the new CreditFacadeV3
    /// @param migrateParams Whether the previous CreditFacadeV3's parameter need to be copied
    function upgradeCreditFacade(address _creditFacade, bool migrateParams) external;

    /// @dev Upgrades the Credit Configurator for a connected Credit Manager
    /// @param _creditConfigurator New Credit Configurator's address
    function upgradeCreditConfigurator(address _creditConfigurator) external;

    /// @dev Enables or disables borrowing
    /// In Credit Facade (and, consequently, the Credit Manager)
    /// @param _mode Prohibits borrowing if true, and allows borrowing otherwise
    function setIncreaseDebtForbidden(bool _mode) external;

    /// @dev Sets the maximal borrowed amount per block
    /// @param newLimit The new max borrowed amount per block
    function setLimitPerBlock(uint128 newLimit) external;

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

    /// @dev Sets the bot list contract
    /// @param botList The address of the new bot list
    function setBotList(address botList) external;

    //
    // GETTERS
    //

    /// @dev Address provider (needed for upgrading the Price Oracle)
    function addressProvider() external view returns (IAddressProvider);

    /// @dev Returns the Credit Facade currently connected to the Credit Manager
    function creditFacade() external view returns (CreditFacadeV3);

    /// @dev Address of the Credit Manager
    function creditManager() external view returns (CreditManagerV3);

    /// @dev Address of the Credit Manager's underlying asset
    function underlying() external view returns (address);

    /// @dev Returns all allowed contracts
    function allowedContracts() external view returns (address[] memory);
}
