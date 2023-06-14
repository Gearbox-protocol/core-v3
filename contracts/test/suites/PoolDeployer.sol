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

import {CreditManagerOpts, CollateralToken} from "../../credit/CreditConfiguratorV3.sol";
import {PoolV3} from "../../pool/PoolV3.sol";
import {LinearInterestRateModelV3} from "../../pool/LinearInterestRateModelV3.sol";

import {GaugeV3} from "../../governance/GaugeV3.sol";
import {PoolQuotaKeeperV3} from "../../pool/PoolQuotaKeeperV3.sol";

import "../lib/constants.sol";

import {ITokenTestSuite} from "../interfaces/ITokenTestSuite.sol";

struct PoolOpts {
    address addressProvider; // address of addressProvider contract
    address underlying; // address of underlying token for pool and creditManager
    uint256 U_optimal; // linear interest model parameter
    uint256 R_base; // linear interest model parameter
    uint256 R_slope1; // linear interest model parameter
    uint256 R_slope2; // linear interest model parameter
    uint256 expectedLiquidityLimit; // linear interest model parameter
    uint256 withdrawFee; // withdrawFee
}

struct PoolCreditOpts {
    PoolOpts poolOpts;
    CreditManagerOpts creditOpts;
}

/// @title CreditManagerTestSuite
/// @notice Deploys contract for unit testing of CreditManagerV3.sol
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

        cr = ContractsRegister(addressProvider.getAddressOrRevert(AP_CONTRACTS_REGISTER, 1));

        withdrawalManager =
            WithdrawalManagerV3(payable(addressProvider.getAddressOrRevert(AP_WITHDRAWAL_MANAGER, 3_00)));

        botList = BotListV3(payable(addressProvider.getAddressOrRevert(AP_BOT_LIST, 3_00)));

        underlying = _underlying;

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
            address(gp.addressProvider()),
            underlying,
            address(irm),
            type(uint256).max,
            supportQuotas,
            "d",
            "diesel"
        );

        tokenTestSuite.mint(_underlying, INITIAL_LP, initialBalance);

        tokenTestSuite.approve(_underlying, INITIAL_LP, address(pool));

        vm.prank(INITIAL_LP);
        pool.deposit(initialBalance, INITIAL_LP);

        cr.addPool(address(pool));

        if (supportQuotas) {
            poolQuotaKeeper = new PoolQuotaKeeperV3(payable(address(pool)));

            address gearStaking = gp.addressProvider().getAddressOrRevert(AP_GEAR_STAKING, 3_00);

            gauge = new GaugeV3(address(pool), gearStaking);

            vm.label(address(gauge), "Gauge");

            poolQuotaKeeper.setGauge(address(gauge));

            pool.setPoolQuotaKeeper(address(poolQuotaKeeper));
        }

        acl.transferOwnership(CONFIGURATOR);

        vm.startPrank(CONFIGURATOR);

        acl.claimOwnership();

        vm.stopPrank();
    }
}
