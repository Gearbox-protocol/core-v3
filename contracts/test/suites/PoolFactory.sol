// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../../interfaces/IAddressProviderV3.sol";

import {PoolV3} from "../../pool/PoolV3.sol";
import {LinearInterestRateModelV3} from "../../pool/LinearInterestRateModelV3.sol";

import {GaugeV3} from "../../governance/GaugeV3.sol";
import {PoolQuotaKeeperV3} from "../../pool/PoolQuotaKeeperV3.sol";

import "../lib/constants.sol";

contract PoolFactory is Test {
    PoolV3 public pool;
    PoolQuotaKeeperV3 public poolQuotaKeeper;
    GaugeV3 public gauge;

    constructor(address addressProvider, address underlying, bool supportQuotas) {
        ///    uint16 U_1,
        // uint16 U_2,
        // uint16 R_base,
        // uint16 R_slope1,
        // uint16 R_slope2,
        // uint16 R_slope3,
        // bool _isBorrowingMoreU2Forbidden
        LinearInterestRateModelV3 irm = new LinearInterestRateModelV3(70_00, 85_00, 0, 15_00, 30_00, 120_00, true);

        // //   address addressProvider_,
        //     address underlyingToken_,
        //     address interestRateModel_,
        //     uint256 totalDebtLimit_,
        //     bool supportsQuotas_,
        //     string memory namePrefix_,
        //     string memory symbolPrefix_
        pool = new PoolV3(
            addressProvider,
            underlying,
            address(irm),
            type(uint256).max,
            supportQuotas,
            "d",
            "diesel"
        );

        if (supportQuotas) {
            address gearStaking = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_GEAR_STAKING, 3_00);

            gauge = new GaugeV3(address(pool), gearStaking);

            vm.label(address(gauge), "Gauge");

            poolQuotaKeeper = new PoolQuotaKeeperV3(payable(address(pool)));

            vm.prank(CONFIGURATOR);
            poolQuotaKeeper.setGauge(address(gauge));

            vm.prank(CONFIGURATOR);
            pool.setPoolQuotaKeeper(address(poolQuotaKeeper));

            vm.label(address(poolQuotaKeeper), "PoolQuotaKeeper");
        }
    }
}
