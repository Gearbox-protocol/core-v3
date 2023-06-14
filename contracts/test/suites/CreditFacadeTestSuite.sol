// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {CreditFacadeV3} from "../../credit/CreditFacadeV3.sol";
import {CreditConfiguratorV3} from "../../credit/CreditConfiguratorV3.sol";
import {CreditManagerV3} from "../../credit/CreditManagerV3.sol";

import {AccountFactoryV3} from "../../core/AccountFactoryV3.sol";
import {CreditManagerFactory} from "./CreditManagerFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DegenNFTV2} from "@gearbox-protocol/core-v2/contracts/tokens/DegenNFTV2.sol";

import "../lib/constants.sol";

import {PoolDeployer} from "./PoolDeployer.sol";
import {ICreditConfig, CreditManagerOpts} from "../interfaces/ICreditConfig.sol";
import {ITokenTestSuite} from "../interfaces/ITokenTestSuite.sol";

/// @title CreditManagerTestSuite
/// @notice Deploys contract for unit testing of CreditManagerV3.sol
contract CreditFacadeTestSuite is PoolDeployer {
    ITokenTestSuite public tokenTestSuite;

    CreditManagerV3 public creditManager;
    CreditFacadeV3 public creditFacade;
    CreditConfiguratorV3 public creditConfigurator;
    DegenNFTV2 public degenNFT;

    uint128 public minDebt;
    uint128 public maxDebt;

    uint256 public creditAccountAmount;

    ICreditConfig creditConfig;

    constructor(
        ICreditConfig _creditConfig,
        bool supportQuotas,
        bool withDegenNFT,
        bool withExpiration,
        uint8 accountFactoryVer
    )
        PoolDeployer(
            _creditConfig.tokenTestSuite(),
            _creditConfig.underlying(),
            _creditConfig.wethToken(),
            10 * _creditConfig.getAccountAmount(),
            _creditConfig.getPriceFeeds(),
            accountFactoryVer,
            supportQuotas
        )
    {
        creditConfig = _creditConfig;

        minDebt = creditConfig.minDebt();
        maxDebt = creditConfig.maxDebt();

        tokenTestSuite = creditConfig.tokenTestSuite();

        creditAccountAmount = creditConfig.getAccountAmount();

        CreditManagerOpts memory cmOpts = creditConfig.getCreditOpts();

        cmOpts.expirable = withExpiration;

        if (withDegenNFT) {
            degenNFT = new DegenNFTV2(
            address(addressProvider),
            "DegenNFTV2",
            "Gear-Degen"
        );

            vm.prank(CONFIGURATOR);
            degenNFT.setMinter(CONFIGURATOR);

            cmOpts.degenNFT = address(degenNFT);
        }

        CreditManagerFactory cmf = new CreditManagerFactory(
            address(addressProvider),
            address(pool),
            cmOpts,
            0
        );

        creditManager = cmf.creditManager();
        creditFacade = cmf.creditFacade();
        creditConfigurator = cmf.creditConfigurator();

        vm.prank(CONFIGURATOR);
        cr.addCreditManager(address(creditManager));

        if (withDegenNFT) {
            vm.prank(CONFIGURATOR);
            degenNFT.addCreditFacade(address(creditFacade));
        }

        if (withExpiration) {
            vm.prank(CONFIGURATOR);
            creditConfigurator.setExpirationDate(uint40(block.timestamp + 1));
        }

        if (accountFactoryVer == 2) {
            vm.prank(CONFIGURATOR);
            AccountFactoryV3(address(af)).addCreditManager(address(creditManager));
        }

        if (supportQuotas) {
            vm.prank(CONFIGURATOR);
            poolQuotaKeeper.addCreditManager(address(creditManager));
        }

        vm.prank(CONFIGURATOR);
        pool.setCreditManagerDebtLimit(address(creditManager), type(uint256).max);

        vm.prank(CONFIGURATOR);
        botList.setApprovedCreditManagerStatus(address(creditManager), true);

        vm.label(address(pool), "Pool");
        vm.label(address(creditFacade), "CreditFacadeV3");
        vm.label(address(creditManager), "CreditManagerV3");
        vm.label(address(creditConfigurator), "CreditConfiguratorV3");

        tokenTestSuite.mint(underlying, USER, creditAccountAmount);
        tokenTestSuite.mint(underlying, FRIEND, creditAccountAmount);

        vm.prank(USER);
        IERC20(underlying).approve(address(creditManager), type(uint256).max);
        vm.prank(FRIEND);
        IERC20(underlying).approve(address(creditManager), type(uint256).max);
    }
}
