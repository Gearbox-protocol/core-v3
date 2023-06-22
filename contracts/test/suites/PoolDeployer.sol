// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../../interfaces/IAddressProviderV3.sol";
import {IPriceOracleV2Ext} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracleV2.sol";
import {PriceFeedConfig} from "@gearbox-protocol/core-v2/contracts/oracles/PriceOracleV2.sol";
import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";
import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";
import {GenesisFactory} from "./GenesisFactory.sol";
import {WithdrawalManagerV3} from "../../core/WithdrawalManagerV3.sol";
import {BotListV3} from "../../core/BotListV3.sol";

import {PoolV3} from "../../pool/PoolV3.sol";

import {GaugeV3} from "../../governance/GaugeV3.sol";
import {PoolQuotaKeeperV3} from "../../pool/PoolQuotaKeeperV3.sol";

import "../lib/constants.sol";

import {ITokenTestSuite} from "../interfaces/ITokenTestSuite.sol";

import {PoolFactory} from "./PoolFactory.sol";

contract PoolDeployer is Test {
    IAddressProviderV3 public addressProvider;
    GenesisFactory public gp;
    AccountFactory public af;
    PoolV3 public pool;
    PoolQuotaKeeperV3 public poolQuotaKeeper;
    GaugeV3 public gauge;
    ContractsRegister public cr;
    WithdrawalManagerV3 public withdrawalManager;
    BotListV3 public botList;
    ACL public acl;

    IPriceOracleV2Ext public priceOracle;

    address public underlying;

    constructor(
        ITokenTestSuite tokenTestSuite,
        address _underlying,
        address wethToken,
        uint256 initialBalance,
        PriceFeedConfig[] memory priceFeeds,
        uint8 accountFactoryVersion,
        bool supportQuotas
    ) {
        new Roles();

        gp = new GenesisFactory(wethToken, DUMB_ADDRESS, accountFactoryVersion);

        gp.acl().claimOwnership();

        gp.acl().addPausableAdmin(CONFIGURATOR);
        gp.acl().addUnpausableAdmin(CONFIGURATOR);

        gp.acl().transferOwnership(address(gp));
        gp.claimACLOwnership();

        gp.addPriceFeeds(priceFeeds);
        gp.acl().claimOwnership();

        addressProvider = gp.addressProvider();
        af = AccountFactory(addressProvider.getAddressOrRevert(AP_ACCOUNT_FACTORY, NO_VERSION_CONTROL));

        priceOracle = IPriceOracleV2Ext(addressProvider.getAddressOrRevert(AP_PRICE_ORACLE, 2));

        acl = ACL(addressProvider.getAddressOrRevert(AP_ACL, 0));

        withdrawalManager =
            WithdrawalManagerV3(payable(addressProvider.getAddressOrRevert(AP_WITHDRAWAL_MANAGER, 3_00)));

        botList = BotListV3(payable(addressProvider.getAddressOrRevert(AP_BOT_LIST, 3_00)));

        underlying = _underlying;

        acl.transferOwnership(CONFIGURATOR);

        vm.prank(CONFIGURATOR);
        acl.claimOwnership();

        PoolFactory pf = new PoolFactory(address(addressProvider), _underlying, supportQuotas);

        pool = pf.pool();
        gauge = pf.gauge();
        poolQuotaKeeper = pf.poolQuotaKeeper();

        tokenTestSuite.mint(_underlying, INITIAL_LP, initialBalance);

        tokenTestSuite.approve(_underlying, INITIAL_LP, address(pool));

        vm.prank(INITIAL_LP);
        pool.deposit(initialBalance, INITIAL_LP);

        cr = ContractsRegister(addressProvider.getAddressOrRevert(AP_CONTRACTS_REGISTER, 1));

        vm.prank(CONFIGURATOR);
        cr.addPool(address(pool));

        // if (supportQuotas) {
        //     address gearStaking = gp.addressProvider().getAddressOrRevert(AP_GEAR_STAKING, 3_00);

        //     gauge = new GaugeV3(address(pool), gearStaking);

        //     vm.label(address(gauge), "Gauge");

        //     poolQuotaKeeper = new PoolQuotaKeeperV3(payable(address(pool)));
        //     poolQuotaKeeper.setGauge(address(gauge));
        //     pool.setPoolQuotaKeeper(address(poolQuotaKeeper));

        //     vm.label(address(poolQuotaKeeper), "PoolQuotaKeeper");
        // }
    }
}
