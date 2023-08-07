// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {ITokenTestSuite} from "./ITokenTestSuite.sol";
import {CreditManagerOpts, CollateralToken} from "../../credit/CreditConfiguratorV3.sol";

struct PriceFeedConfig {
    address token;
    address priceFeed;
    uint32 stalenessPeriod;
}

interface ICreditConfig {
    function getCreditOpts() external returns (CreditManagerOpts memory);

    function getCollateralTokens() external returns (CollateralToken[] memory collateralTokens);

    function getAccountAmount() external view returns (uint256);

    function underlying() external view returns (address);

    function wethToken() external view returns (address);

    function minDebt() external view returns (uint128);

    function maxDebt() external view returns (uint128);
}
