// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Tokens} from "@gearbox-protocol/sdk/contracts/Tokens.sol";

import {ITokenTestSuite} from "./ITokenTestSuite.sol";
import {CreditManagerOpts, CollateralToken} from "../../interfaces/ICreditConfiguratorV3.sol";
import {Contracts} from "@gearbox-protocol/sdk/contracts/SupportedContracts.sol";

struct PriceFeedConfig {
    address token;
    address priceFeed;
    uint32 stalenessPeriod;
}

struct LinearIRMV3DeployParams {
    uint16 U_1;
    uint16 U_2;
    uint16 R_base;
    uint16 R_slope1;
    uint16 R_slope2;
    uint16 R_slope3;
    bool _isBorrowingMoreU2Forbidden;
}

struct PoolV3DeployParams {
    uint16 withdrawalFee;
    uint256 expectedLiquidityLimit;
}

/// @dev A struct representing the initial Credit Manager configuration parameters
struct CreditManagerV3DeployParams {
    /// @dev The minimal debt principal amount
    uint128 minDebt;
    /// @dev The maximal debt principal amount
    uint128 maxDebt;
    /// @dev The initial list of collateral tokens to allow
    CollateralTokenHuman[] collateralTokens;
    /// @dev Address of DegenNFT, address(0) if whitelisted mode is not used
    bool whitelisted;
    /// @dev Whether the Credit Manager is connected to an expirable pool (and the CreditFacade is expirable)
    bool expirable;
    /// @dev Whether to skip normal initialization - used for new Credit Configurators that are deployed for existing CMs
    bool skipInit;
    /// @dev Contracts which should become adapters
    Contracts[] contracts;
    /// @dev Pool limit
    uint256 poolLimit;
}

struct GaugeRate {
    Tokens token;
    uint16 minRate;
    uint16 maxRate;
}

struct PoolQuotaLimit {
    Tokens token;
    uint256 quotaIncreaseFee;
    uint256 limit;
}

struct CollateralTokenHuman {
    Tokens token;
    uint16 lt;
}

interface IPoolV3DeployConfig {
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);

    function chainId() external view returns (uint256);
    function underlying() external view returns (Tokens);
    function supportsQuotas() external view returns (bool);

    function poolParams() external view returns (PoolV3DeployParams memory);

    function irm() external view returns (LinearIRMV3DeployParams memory);

    function gaugeRates() external view returns (GaugeRate[] memory);

    function quotaLimits() external view returns (PoolQuotaLimit[] memory);

    function getAccountAmount() external view returns (uint256);

    function creditManagers() external view returns (CreditManagerV3DeployParams[] memory);
}
