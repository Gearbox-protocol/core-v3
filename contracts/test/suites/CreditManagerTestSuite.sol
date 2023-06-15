// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {CreditManagerV3} from "../../credit/CreditManagerV3.sol";
import {CreditManagerOpts, CollateralToken} from "../../credit/CreditConfiguratorV3.sol";

import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";

import {AccountFactoryV3} from "../../core/AccountFactoryV3.sol";

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

import "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

import "../lib/constants.sol";
import {CreditManagerV3Harness} from "../unit/credit/CreditManagerV3Harness.sol";
import {PoolDeployer} from "./PoolDeployer.sol";
import {ICreditConfig} from "../interfaces/ICreditConfig.sol";
import {ITokenTestSuite} from "../interfaces/ITokenTestSuite.sol";

/// @title CreditManagerTestSuite
/// @notice Deploys contract for unit testing of CreditManagerV3.sol
contract CreditManagerTestSuite is PoolDeployer {
    ITokenTestSuite public tokenTestSuite;

    CreditManagerV3 public creditManager;

    IWETH wethToken;

    address public creditFacade;
    uint256 creditAccountAmount;

    bool supportsQuotas;

    constructor(ICreditConfig creditConfig, bool _supportsQuotas, uint8 accountFactoryVer)
        PoolDeployer(
            creditConfig.tokenTestSuite(),
            creditConfig.underlying(),
            creditConfig.wethToken(),
            10 * creditConfig.getAccountAmount(),
            creditConfig.getPriceFeeds(),
            accountFactoryVer,
            _supportsQuotas
        )
    {
        supportsQuotas = _supportsQuotas;

        creditAccountAmount = creditConfig.getAccountAmount();

        tokenTestSuite = creditConfig.tokenTestSuite();

        creditManager = new CreditManagerV3(address(addressProvider), address(pool));

        creditFacade = msg.sender;

        creditManager.setCreditConfigurator(CONFIGURATOR);

        vm.startPrank(CONFIGURATOR);
        creditManager.setCreditFacade(creditFacade);

        creditManager.setFees(
            DEFAULT_FEE_INTEREST,
            DEFAULT_FEE_LIQUIDATION,
            PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM,
            DEFAULT_FEE_LIQUIDATION_EXPIRED,
            PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM_EXPIRED
        );

        CollateralToken[] memory collateralTokens = creditConfig.getCollateralTokens();

        for (uint256 i = 0; i < collateralTokens.length; i++) {
            if (collateralTokens[i].token != underlying) {
                address token = collateralTokens[i].token;
                creditManager.addToken(token);
                creditManager.setCollateralTokenData(
                    token,
                    collateralTokens[i].liquidationThreshold,
                    collateralTokens[i].liquidationThreshold,
                    type(uint40).max,
                    0
                );
            }
        }

        cr.addCreditManager(address(creditManager));

        pool.setCreditManagerDebtLimit(address(creditManager), type(uint256).max);

        assertEq(creditManager.creditConfigurator(), CONFIGURATOR, "Configurator wasn't set");

        if (supportsQuotas) {
            poolQuotaKeeper.addCreditManager(address(creditManager));
        }

        if (accountFactoryVer == 2) {
            AccountFactoryV3(address(af)).addCreditManager(address(creditManager));
        }

        withdrawalManager.addCreditManager(address(creditManager));

        vm.stopPrank();

        // Approve USER & LIQUIDATOR to credit manager
        tokenTestSuite.approve(underlying, USER, address(creditManager));
        tokenTestSuite.approve(underlying, LIQUIDATOR, address(creditManager));
    }

    ///
    /// HELPERS

    /// @dev Opens credit account for testing management functions
    function openCreditAccount()
        external
        returns (uint256 borrowedAmount, uint256 cumulativeIndexLastUpdate, address creditAccount)
    {
        return openCreditAccount(creditAccountAmount);
    }

    function openCreditAccount(uint256 _borrowedAmount)
        public
        returns (uint256 borrowedAmount, uint256 cumulativeIndexLastUpdate, address creditAccount)
    {
        // Set up real value, which should be configired before CM would be launched
        vm.prank(CONFIGURATOR);
        creditManager.setCollateralTokenData(
            underlying,
            uint16(PERCENTAGE_FACTOR - DEFAULT_FEE_LIQUIDATION - DEFAULT_LIQUIDATION_PREMIUM),
            uint16(PERCENTAGE_FACTOR - DEFAULT_FEE_LIQUIDATION - DEFAULT_LIQUIDATION_PREMIUM),
            type(uint40).max,
            0
        );

        borrowedAmount = _borrowedAmount;

        cumulativeIndexLastUpdate = pool.calcLinearCumulative_RAY();
        // pool.setCumulativeIndexNow(cumulativeIndexLastUpdate);

        vm.prank(creditFacade);

        // Existing address case
        creditAccount = creditManager.openCreditAccount(borrowedAmount, USER);

        // Increase block number cause it's forbidden to close credit account in the same block
        vm.roll(block.number + 1);
        // vm.warp(block.timestamp + 100 days);

        // pool.setCumulativeIndexNow(cumulativeIndexAtClose);
    }

    function makeTokenQuoted(address token, uint16 rate, uint96 limit) external {
        require(supportsQuotas, "Test suite does not support quotas");

        vm.startPrank(CONFIGURATOR);
        gauge.addQuotaToken(token, rate, rate);
        poolQuotaKeeper.setTokenLimit(token, limit);

        vm.warp(block.timestamp + 7 days);
        gauge.updateEpoch();

        uint256 tokenMask = creditManager.getTokenMaskOrRevert(token);
        uint256 limitedMask = creditManager.quotedTokensMask();

        creditManager.setQuotedMask(limitedMask | tokenMask);

        vm.stopPrank();
    }
}
