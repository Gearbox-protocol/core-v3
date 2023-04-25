// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {CreditManagerV3} from "../../credit/CreditManagerV3.sol";
import {CreditManagerOpts, CollateralToken} from "../../credit/CreditConfigurator.sol";

import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {WithdrawManager} from "../../support/WithdrawManager.sol";

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

import "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

import "../lib/constants.sol";
import {CreditManagerTestInternal} from "../mocks/credit/CreditManagerTestInternal.sol";
import {PoolDeployer} from "./PoolDeployer.sol";
import {ICreditConfig} from "../interfaces/ICreditConfig.sol";
import {ITokenTestSuite} from "../interfaces/ITokenTestSuite.sol";

import "forge-std/console.sol";

/// @title CreditManagerTestSuite
/// @notice Deploys contract for unit testing of CreditManagerV3.sol
contract CreditManagerTestSuite is PoolDeployer {
    ITokenTestSuite public tokenTestSuite;

    CreditManagerV3 public creditManager;

    IWETH wethToken;

    address creditFacade;
    uint256 creditAccountAmount;

    bool supportsQuotas;

    constructor(ICreditConfig creditConfig, bool internalSuite, bool _supportsQuotas)
        PoolDeployer(
            creditConfig.tokenTestSuite(),
            creditConfig.underlying(),
            creditConfig.wethToken(),
            10 * creditConfig.getAccountAmount(),
            creditConfig.getPriceFeeds()
        )
    {
        supportsQuotas = _supportsQuotas;

        if (supportsQuotas) {
            poolMock.setSupportsQuotas(true);
        }

        creditAccountAmount = creditConfig.getAccountAmount();

        tokenTestSuite = creditConfig.tokenTestSuite();

        creditManager = internalSuite
            ? new CreditManagerTestInternal(address(poolMock), address(withdrawManager))
            : new CreditManagerV3(address(poolMock), address(withdrawManager));

        creditFacade = msg.sender;

        creditManager.setConfigurator(CONFIGURATOR);

        evm.startPrank(CONFIGURATOR);

        creditManager.upgradeCreditFacade(creditFacade);

        creditManager.setParams(
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
                creditManager.setLiquidationThreshold(token, collateralTokens[i].liquidationThreshold);
            }
        }

        evm.stopPrank();

        assertEq(creditManager.creditConfigurator(), CONFIGURATOR, "Configurator wasn't set");

        cr.addCreditManager(address(creditManager));

        if (supportsQuotas) {
            poolQuotaKeeper.addCreditManager(address(creditManager));
            // poolQuotaKeeper.setGauge(CONFIGURATOR);
        }

        // Approve USER & LIQUIDATOR to credit manager
        tokenTestSuite.approve(underlying, USER, address(creditManager));
        tokenTestSuite.approve(underlying, LIQUIDATOR, address(creditManager));

        addressProvider.transferOwnership(CONFIGURATOR);
        acl.transferOwnership(CONFIGURATOR);

        evm.startPrank(CONFIGURATOR);

        acl.claimOwnership();
        addressProvider.claimOwnership();

        evm.stopPrank();
    }

    ///
    /// HELPERS

    /// @dev Opens credit account for testing management functions
    function openCreditAccount()
        external
        returns (
            uint256 borrowedAmount,
            uint256 cumulativeIndexAtOpen,
            uint256 cumulativeIndexAtClose,
            address creditAccount
        )
    {
        return openCreditAccount(creditAccountAmount);
    }

    function openCreditAccount(uint256 _borrowedAmount)
        public
        returns (
            uint256 borrowedAmount,
            uint256 cumulativeIndexAtOpen,
            uint256 cumulativeIndexAtClose,
            address creditAccount
        )
    {
        // Set up real value, which should be configired before CM would be launched
        evm.prank(CONFIGURATOR);
        creditManager.setLiquidationThreshold(
            underlying, uint16(PERCENTAGE_FACTOR - DEFAULT_FEE_LIQUIDATION - DEFAULT_LIQUIDATION_PREMIUM)
        );

        borrowedAmount = _borrowedAmount;

        cumulativeIndexAtOpen = RAY;
        poolMock.setCumulative_RAY(cumulativeIndexAtOpen);

        evm.prank(creditFacade);

        // Existing address case
        creditAccount = creditManager.openCreditAccount(borrowedAmount, USER);

        // Increase block number cause it's forbidden to close credit account in the same block
        evm.roll(block.number + 1);

        cumulativeIndexAtClose = (cumulativeIndexAtOpen * 12) / 10;
        poolMock.setCumulative_RAY(cumulativeIndexAtClose);
    }

    function makeTokenLimited(address token, uint16 rate, uint96 limit) external {
        require(supportsQuotas, "Test suite does not support quotas");

        evm.startPrank(CONFIGURATOR);
        gaugeMock.addQuotaToken(token, rate);
        poolQuotaKeeper.setTokenLimit(token, limit);

        gaugeMock.updateEpoch();

        uint256 tokenMask = creditManager.getTokenMaskOrRevert(token);
        uint256 limitedMask = creditManager.limitedTokenMask();

        creditManager.setLimitedMask(limitedMask | tokenMask);

        evm.stopPrank();
    }
}
