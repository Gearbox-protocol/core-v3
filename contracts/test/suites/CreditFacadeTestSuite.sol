// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {CreditFacadeV3} from "../../credit/CreditFacadeV3.sol";
import {CreditConfigurator} from "../../credit/CreditConfigurator.sol";
import {CreditManagerV3} from "../../credit/CreditManagerV3.sol";
import {WithdrawManager} from "../../support/WithdrawManager.sol";

import {CreditManagerFactory} from "../../factories/CreditManagerFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DegenNFT} from "@gearbox-protocol/core-v2/contracts/tokens/DegenNFT.sol";

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
    CreditConfigurator public creditConfigurator;
    DegenNFT public degenNFT;

    uint128 public minBorrowedAmount;
    uint128 public maxBorrowedAmount;

    uint256 public creditAccountAmount;

    ICreditConfig creditConfig;

    constructor(ICreditConfig _creditConfig)
        PoolDeployer(
            _creditConfig.tokenTestSuite(),
            _creditConfig.underlying(),
            _creditConfig.wethToken(),
            10 * _creditConfig.getAccountAmount(),
            _creditConfig.getPriceFeeds()
        )
    {
        creditConfig = _creditConfig;

        minBorrowedAmount = creditConfig.minBorrowedAmount();
        maxBorrowedAmount = creditConfig.maxBorrowedAmount();

        tokenTestSuite = creditConfig.tokenTestSuite();

        creditAccountAmount = creditConfig.getAccountAmount();

        CreditManagerOpts memory cmOpts = creditConfig.getCreditOpts();

        cmOpts.withdrawManager = address(withdrawManager);

        CreditManagerFactory cmf = new CreditManagerFactory(
            address(poolMock),
            cmOpts,
            0
        );

        creditManager = cmf.creditManager();
        creditFacade = cmf.creditFacade();
        creditConfigurator = cmf.creditConfigurator();

        cr.addCreditManager(address(creditManager));

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

        addressProvider.transferOwnership(CONFIGURATOR);
        acl.transferOwnership(CONFIGURATOR);

        evm.startPrank(CONFIGURATOR);

        acl.claimOwnership();
        addressProvider.claimOwnership();

        evm.stopPrank();
    }

    function testFacadeWithDegenNFT() external {
        degenNFT = new DegenNFT(
            address(addressProvider),
            "DegenNFT",
            "Gear-Degen"
        );

        evm.startPrank(CONFIGURATOR);

        degenNFT.setMinter(CONFIGURATOR);

        creditFacade = new CreditFacadeV3(
            address(creditManager),
            address(degenNFT),

            false
        );

        creditConfigurator.setCreditFacade(address(creditFacade), true);

        degenNFT.addCreditFacade(address(creditFacade));

        evm.stopPrank();
    }

    function testFacadeWithExpiration() external {
        evm.startPrank(CONFIGURATOR);

        creditFacade = new CreditFacadeV3(
            address(creditManager),
            address(0),

            true
        );

        creditConfigurator.setCreditFacade(address(creditFacade), true);
        creditConfigurator.setExpirationDate(uint40(block.timestamp + 1));

        evm.stopPrank();
    }

    function testFacadeWithBlacklistHelper() external {
        evm.startPrank(CONFIGURATOR);

        creditFacade = new CreditFacadeV3(
            address(creditManager),
            address(0),

            false
        );

        creditConfigurator.setCreditFacade(address(creditFacade), true);

        // blacklistHelper.addCreditFacade(address(creditFacade));

        evm.stopPrank();
    }

    function testFacadeWithQuotas() external {
        poolMock.setSupportsQuotas(true);

        CreditManagerFactory cmf = new CreditManagerFactory(
            address(poolMock),
            creditConfig.getCreditOpts(),
            0
        );

        creditManager = cmf.creditManager();
        creditFacade = cmf.creditFacade();
        creditConfigurator = cmf.creditConfigurator();

        assertTrue(creditManager.supportsQuotas(), "Credit Manager does not support quotas");

        evm.startPrank(CONFIGURATOR);
        cr.addCreditManager(address(creditManager));
        poolQuotaKeeper.addCreditManager(address(creditManager));
        evm.stopPrank();

        evm.label(address(poolMock), "Pool");
        evm.label(address(creditFacade), "CreditFacadeV3");
        evm.label(address(creditManager), "CreditManagerV3");
        evm.label(address(creditConfigurator), "CreditConfigurator");

        evm.prank(USER);
        IERC20(underlying).approve(address(creditManager), type(uint256).max);
        evm.prank(FRIEND);
        IERC20(underlying).approve(address(creditManager), type(uint256).max);
    }
}
