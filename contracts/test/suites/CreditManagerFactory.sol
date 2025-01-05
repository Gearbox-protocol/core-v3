// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/Create2.sol";

import "../interfaces/IAddressProviderV3.sol";
import {IACLTrait} from "../../interfaces/base/IACLTrait.sol";

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

    struct ManagerParams {
        address accountFactory;
        address priceOracle;
        uint8 maxEnabledTokens;
        uint16 feeInterest;
        uint16 feeLiquidation;
        uint16 liquidationPremium;
        uint16 feeLiquidationExpired;
        uint16 liquidationPremiumExpired;
        string name;
    }

    struct FacadeParams {
        address lossPolicy;
        address botList;
        address weth;
        address degenNFT;
        bool expirable;
    }

    constructor(address pool, ManagerParams memory cmParams, FacadeParams memory cfParams) {
        creditManager = new CreditManagerV3(
            pool,
            cmParams.accountFactory,
            cmParams.priceOracle,
            cmParams.maxEnabledTokens,
            cmParams.feeInterest,
            cmParams.feeLiquidation,
            cmParams.liquidationPremium,
            cmParams.feeLiquidationExpired,
            cmParams.liquidationPremiumExpired,
            cmParams.name
        );

        address acl = IACLTrait(pool).acl();
        creditFacade = new CreditFacadeV3(
            acl,
            address(creditManager),
            cfParams.lossPolicy,
            cfParams.botList,
            cfParams.weth,
            cfParams.degenNFT,
            cfParams.expirable
        );
        creditManager.setCreditFacade(address(creditFacade));

        creditConfigurator = new CreditConfiguratorV3(acl, address(creditManager));
        creditManager.setCreditConfigurator(address(creditConfigurator));
    }
}
