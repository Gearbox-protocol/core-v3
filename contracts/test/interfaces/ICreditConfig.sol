// SPDX-License-Identifier: UNLICENSED
// Gearbox. Generalized leverage protocol that allows to take leverage and then use it across other DeFi protocols and platforms in a composable way.
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {ITokenTestSuite} from "./ITokenTestSuite.sol";
import {PriceFeedConfig} from "@gearbox-protocol/core-v2/contracts/oracles/PriceOracleV2.sol";
import {CreditManagerOpts, CollateralToken} from "../../credit/CreditConfiguratorV3.sol";

interface ICreditConfig {
    function getCreditOpts() external returns (CreditManagerOpts memory);

    function getCollateralTokens() external returns (CollateralToken[] memory collateralTokens);

    function getAccountAmount() external view returns (uint256);

    function getPriceFeeds() external view returns (PriceFeedConfig[] memory);

    function underlying() external view returns (address);

    function wethToken() external view returns (address);

    function tokenTestSuite() external view returns (ITokenTestSuite);

    function minDebt() external view returns (uint128);

    function maxDebt() external view returns (uint128);
}
