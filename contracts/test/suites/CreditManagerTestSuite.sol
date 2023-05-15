// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {CreditManagerV3} from "../../credit/CreditManagerV3.sol";
import {CreditManagerOpts, CollateralToken} from "../../credit/CreditConfiguratorV3.sol";

import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {WithdrawalManager} from "../../support/WithdrawalManager.sol";
import {AccountFactoryV3} from "../../core/AccountFactoryV3.sol";

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

    constructor(ICreditConfig creditConfig, bool internalSuite, bool _supportsQuotas, uint8 accountFactoryVer)
        PoolDeployer(
            creditConfig.tokenTestSuite(),
            creditConfig.underlying(),
            creditConfig.wethToken(),
            10 * creditConfig.getAccountAmount(),
            creditConfig.getPriceFeeds(),
            accountFactoryVer
        )
    {
        supportsQuotas = _supportsQuotas;

        if (supportsQuotas) {
            poolMock.setSupportsQuotas(true);
        }

        creditAccountAmount = creditConfig.getAccountAmount();

        tokenTestSuite = creditConfig.tokenTestSuite();

        creditManager = internalSuite
            ? new CreditManagerTestInternal(address(addressProvider), address(poolMock))
            : new CreditManagerV3(address(addressProvider), address(poolMock));

        creditFacade = msg.sender;

        creditManager.setCreditConfigurator(CONFIGURATOR);

        vm.startPrank(CONFIGURATOR);
        creditManager.setCreditFacade(creditFacade);

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

        assertEq(creditManager.creditConfigurator(), CONFIGURATOR, "Configurator wasn't set");

        if (supportsQuotas) {
            poolQuotaKeeper.addCreditManager(address(creditManager));
        }

        if (accountFactoryVer == 2) {
            AccountFactoryV3(address(af)).addCreditManager(address(creditManager), 1);
        }

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
        returns (
            uint256 borrowedAmount,
            uint256 cumulativeIndexLastUpdate,
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
            uint256 cumulativeIndexLastUpdate,
            uint256 cumulativeIndexAtClose,
            address creditAccount
        )
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

        cumulativeIndexLastUpdate = RAY;
        poolMock.setCumulative_RAY(cumulativeIndexLastUpdate);

        vm.prank(creditFacade);

        // Existing address case
        creditAccount = creditManager.openCreditAccount(borrowedAmount, USER, false);

        // Increase block number cause it's forbidden to close credit account in the same block
        vm.roll(block.number + 1);

        cumulativeIndexAtClose = (cumulativeIndexLastUpdate * 12) / 10;
        poolMock.setCumulative_RAY(cumulativeIndexAtClose);
    }

    function makeTokenQuoted(address token, uint16 rate, uint96 limit) external {
        require(supportsQuotas, "Test suite does not support quotas");

        vm.startPrank(CONFIGURATOR);
        gaugeMock.addQuotaToken(token, rate);
        poolQuotaKeeper.setTokenLimit(token, limit);

        gaugeMock.updateEpoch();

        uint256 tokenMask = creditManager.getTokenMaskOrRevert(token);
        uint256 limitedMask = creditManager.quotedTokenMask();

        creditManager.setQuotedMask(limitedMask | tokenMask);

        vm.stopPrank();
    }
}
