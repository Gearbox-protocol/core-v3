// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {CreditFacadeV3} from "../../credit/CreditFacadeV3.sol";
import {CreditConfigurator} from "../../credit/CreditConfiguratorV3.sol";
import {CreditManagerV3} from "../../credit/CreditManagerV3.sol";
import {WithdrawalManager} from "../../support/WithdrawalManager.sol";

import {AccountFactoryV2} from "../../core/AccountFactory.sol";
import {CreditManagerFactory} from "../../factories/CreditManagerFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DegenNFT} from "@gearbox-protocol/core-v2/contracts/tokens/DegenNFT.sol";

import "../lib/constants.sol";

import {PoolDeployer} from "./PoolDeployer.sol";
import {ICreditConfig, CreditManagerOpts} from "../interfaces/ICreditConfig.sol";
import {ITokenTestSuite} from "../interfaces/ITokenTestSuite.sol";

import "forge-std/console.sol";

/// @title CreditManagerTestSuite
/// @notice Deploys contract for unit testing of CreditManagerV3.sol
contract CreditFacadeTestSuite is PoolDeployer {
    ITokenTestSuite public tokenTestSuite;

    CreditManagerV3 public creditManager;
    CreditFacadeV3 public creditFacade;
    CreditConfigurator public creditConfigurator;
    DegenNFT public degenNFT;

    uint128 public minBorrowedAmount;
    uint128 public maxBorrowedAmount;

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
            accountFactoryVer
        )
    {
        poolMock.setSupportsQuotas(supportQuotas);
        creditConfig = _creditConfig;

        minBorrowedAmount = creditConfig.minBorrowedAmount();
        maxBorrowedAmount = creditConfig.maxBorrowedAmount();

        tokenTestSuite = creditConfig.tokenTestSuite();

        creditAccountAmount = creditConfig.getAccountAmount();

        CreditManagerOpts memory cmOpts = creditConfig.getCreditOpts();

        cmOpts.expirable = withExpiration;

        if (withDegenNFT) {
            degenNFT = new DegenNFT(
            address(addressProvider),
            "DegenNFT",
            "Gear-Degen"
        );

            evm.prank(CONFIGURATOR);
            degenNFT.setMinter(CONFIGURATOR);

            cmOpts.degenNFT = address(degenNFT);
        }

        cmOpts.withdrawalManager = address(withdrawalManager);

        CreditManagerFactory cmf = new CreditManagerFactory(
            address(poolMock),
            cmOpts,
            0
        );

        creditManager = cmf.creditManager();
        creditFacade = cmf.creditFacade();
        creditConfigurator = cmf.creditConfigurator();

        evm.prank(CONFIGURATOR);
        cr.addCreditManager(address(creditManager));

        if (withDegenNFT) {
            evm.prank(CONFIGURATOR);
            degenNFT.addCreditFacade(address(creditFacade));
        }

        if (withExpiration) {
            evm.prank(CONFIGURATOR);
            creditConfigurator.setExpirationDate(uint40(block.timestamp + 1));
        }

        if (accountFactoryVer == 2) {
            evm.prank(CONFIGURATOR);
            AccountFactoryV2(address(af)).addCreditManager(address(creditManager));
        }

        if (supportQuotas) {
            evm.prank(CONFIGURATOR);
            poolQuotaKeeper.addCreditManager(address(creditManager));
        }

        evm.label(address(poolMock), "Pool");
        evm.label(address(creditFacade), "CreditFacadeV3");
        evm.label(address(creditManager), "CreditManagerV3");
        evm.label(address(creditConfigurator), "CreditConfigurator");

        tokenTestSuite.mint(underlying, USER, creditAccountAmount);
        tokenTestSuite.mint(underlying, FRIEND, creditAccountAmount);

        evm.prank(USER);
        IERC20(underlying).approve(address(creditManager), type(uint256).max);
        evm.prank(FRIEND);
        IERC20(underlying).approve(address(creditManager), type(uint256).max);
    }
}
