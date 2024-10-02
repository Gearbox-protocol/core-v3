// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/Create2.sol";

import "../interfaces/IAddressProviderV3.sol";

import {CreditManagerV3} from "../../credit/CreditManagerV3.sol";
import {CreditFacadeV3} from "../../credit/CreditFacadeV3.sol";
import {CreditConfiguratorV3} from "../../credit/CreditConfiguratorV3.sol";

import {DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER} from "../../libraries/Constants.sol";

/// @title CreditManagerFactory
/// @notice Deploys 3 core interdependent contracts: CreditManage, CreditFacadeV3 and CredigConfigurator
///         and setup them by following options
contract CreditManagerFactory {
    CreditManagerV3 public creditManager;
    CreditFacadeV3 public creditFacade;
    CreditConfiguratorV3 public creditConfigurator;

    constructor(
        address weth,
        address accountFactory,
        address priceOracle,
        address botList,
        address pool,
        address degenNFT,
        bool expirable,
        uint8 maxEnabledTokens,
        uint16 feeInterest,
        string memory name
    ) {
        creditManager = new CreditManagerV3(pool, accountFactory, priceOracle, maxEnabledTokens, feeInterest, name);

        creditFacade = new CreditFacadeV3(address(creditManager), botList, weth, degenNFT, expirable);
        creditManager.setCreditFacade(address(creditFacade));

        creditConfigurator = new CreditConfiguratorV3(address(creditManager));
        creditManager.setCreditConfigurator(address(creditConfigurator));
    }
}
