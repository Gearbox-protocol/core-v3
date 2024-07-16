// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.23;

import "../interfaces/IAddressProviderV3.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PoolV3} from "../../pool/PoolV3.sol";
import {LinearInterestRateModelV3} from "../../pool/LinearInterestRateModelV3.sol";

import {GaugeV3} from "../../pool/GaugeV3.sol";
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
        bool, /* supportQuotas */
        TokensTestSuite tokensTestSuite
    ) {
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

        address acl = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_ACL, NO_VERSION_CONTROL);
        address contractsRegister =
            IAddressProviderV3(addressProvider).getAddressOrRevert(AP_CONTRACTS_REGISTER, NO_VERSION_CONTROL);

        pool = new PoolV3({
            acl_: acl,
            contractsRegister_: contractsRegister,
            underlyingToken_: underlying,
            treasury_: IAddressProviderV3(addressProvider).getAddressOrRevert(AP_TREASURY, NO_VERSION_CONTROL),
            interestRateModel_: address(irm),
            totalDebtLimit_: type(uint256).max,
            name_: config.name(),
            symbol_: config.symbol()
        });

        poolQuotaKeeper = new PoolQuotaKeeperV3(payable(address(pool)));

        vm.prank(CONFIGURATOR);
        pool.setPoolQuotaKeeper(address(poolQuotaKeeper));

        vm.label(address(poolQuotaKeeper), string.concat("PoolQuotaKeeperV3-", config.symbol()));

        address gearStaking = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_GEAR_STAKING, 3_10);
        gauge = new GaugeV3(address(poolQuotaKeeper), gearStaking);
        vm.prank(CONFIGURATOR);
        gauge.setFrozenEpoch(false);

        vm.label(address(gauge), string.concat("GaugeV3-", config.symbol()));

        vm.prank(CONFIGURATOR);
        poolQuotaKeeper.setGauge(address(gauge));

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
