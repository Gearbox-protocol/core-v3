// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../../interfaces/IAddressProviderV3.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PoolV3} from "../../pool/PoolV3.sol";
import {LinearInterestRateModelV3} from "../../pool/LinearInterestRateModelV3.sol";

import {GaugeV3} from "../../governance/GaugeV3.sol";
import {PoolQuotaKeeperV3} from "../../pool/PoolQuotaKeeperV3.sol";
import {
    IPoolV3DeployConfig, LinearIRMV3DeployParams, GaugeRate, PoolQuotaLimit
} from "../interfaces/ICreditConfig.sol";
import {TokensTestSuite} from "./TokensTestSuite.sol";

import "../lib/constants.sol";

contract PoolFactory is Test {
    PoolV3 public pool;
    PoolQuotaKeeperV3 public poolQuotaKeeper;
    GaugeV3 public gauge;

    constructor(
        address addressProvider,
        IPoolV3DeployConfig config,
        address underlying,
        bool supportQuotas,
        TokensTestSuite tokensTestSuite
    ) {
        // uint16 U_1,
        // uint16 U_2,
        // uint16 R_base,
        // uint16 R_slope1,
        // uint16 R_slope2,
        // uint16 R_slope3,
        // bool _isBorrowingMoreU2Forbidden
        LinearIRMV3DeployParams memory irmParams = config.irm();
        LinearInterestRateModelV3 irm = new LinearInterestRateModelV3(
            irmParams.U_1,
            irmParams.U_2,
            irmParams.R_base,
            irmParams.R_slope1,
            irmParams.R_slope2,
            irmParams.R_slope3,
            irmParams._isBorrowingMoreU2Forbidden
        );

        // address addressProvider_,
        // address underlyingToken_,
        // address interestRateModel_,
        // uint256 totalDebtLimit_,
        // string memory namePrefix_,
        // string memory symbolPrefix_
        pool = new PoolV3({
           addressProvider_: addressProvider,
           underlyingToken_: underlying,
           interestRateModel_: address(irm),
           totalDebtLimit_: type(uint256).max,
           name_: config.name(),
           symbol_: config.symbol()
     } );

        if (supportQuotas) {
            address gearStaking = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_GEAR_STAKING, 3_00);

            gauge = new GaugeV3(address(pool), gearStaking);
            vm.prank(CONFIGURATOR);
            gauge.setFrozenEpoch(false);

            vm.label(address(gauge), string.concat("GaugeV3-", config.symbol()));

            poolQuotaKeeper = new PoolQuotaKeeperV3(payable(address(pool)));

            vm.prank(CONFIGURATOR);
            poolQuotaKeeper.setGauge(address(gauge));

            vm.prank(CONFIGURATOR);
            pool.setPoolQuotaKeeper(address(poolQuotaKeeper));

            vm.label(address(poolQuotaKeeper), string.concat("PoolQuotaKeeperV3-", config.symbol()));

            GaugeRate[] memory gaugeRates = config.gaugeRates();

            uint256 len = gaugeRates.length;

            unchecked {
                for (uint256 i; i < len; ++i) {
                    GaugeRate memory gaugeRate = gaugeRates[i];
                    address token = tokensTestSuite.addressOf(gaugeRate.token);

                    vm.prank(CONFIGURATOR);
                    gauge.addQuotaToken(token, gaugeRate.minRate, gaugeRate.maxRate);
                }
            }

            PoolQuotaLimit[] memory quotaLimits = config.quotaLimits();
            len = quotaLimits.length;

            unchecked {
                for (uint256 i; i < len; ++i) {
                    address token = tokensTestSuite.addressOf(quotaLimits[i].token);

                    vm.startPrank(CONFIGURATOR);
                    poolQuotaKeeper.setTokenLimit(token, quotaLimits[i].limit);
                    poolQuotaKeeper.setTokenQuotaIncreaseFee(token, quotaLimits[i].quotaIncreaseFee);
                    vm.stopPrank();
                }
            }
        }
    }
}
