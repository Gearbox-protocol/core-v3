// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {AddressProvider} from "@gearbox-protocol/core-v2/contracts/core/AddressProvider.sol";
import {IPriceOracleV2Ext} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import {PriceFeedConfig} from "@gearbox-protocol/core-v2/contracts/oracles/PriceOracle.sol";
import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";
import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";
import {GenesisFactory} from "./GenesisFactory.sol";
import {PoolFactory, PoolOpts} from "@gearbox-protocol/core-v2/contracts/factories/PoolFactory.sol";
import {WithdrawalManager} from "../../support/WithdrawalManager.sol";

import {CreditManagerOpts, CollateralToken} from "../../credit/CreditConfiguratorV3.sol";
import {PoolServiceMock} from "../mocks/pool/PoolServiceMock.sol";
import {GaugeMock} from "../mocks/pool/GaugeMock.sol";
import {PoolQuotaKeeper} from "../../pool/PoolQuotaKeeper.sol";

import "../lib/constants.sol";
import {Test} from "forge-std/Test.sol";

import {ITokenTestSuite} from "../interfaces/ITokenTestSuite.sol";

struct PoolCreditOpts {
    PoolOpts poolOpts;
    CreditManagerOpts creditOpts;
}

/// @title CreditManagerTestSuite
/// @notice Deploys contract for unit testing of CreditManagerV3.sol
contract PoolDeployer is Test {
    AddressProvider public addressProvider;
    GenesisFactory public gp;
    AccountFactory public af;
    PoolServiceMock public poolMock;
    PoolQuotaKeeper public poolQuotaKeeper;
    GaugeMock public gaugeMock;
    ContractsRegister public cr;
    WithdrawalManager public withdrawalManager;
    ACL public acl;

    IPriceOracleV2Ext public priceOracle;

    address public underlying;

    constructor(
        ITokenTestSuite tokenTestSuite,
        address _underlying,
        address wethToken,
        uint256 initialBalance,
        PriceFeedConfig[] memory priceFeeds,
        uint8 accountFactoryVersion
    ) {
        new Roles();

        gp = new GenesisFactory(wethToken, DUMB_ADDRESS, accountFactoryVersion);

        gp.acl().claimOwnership();
        gp.addressProvider().claimOwnership();

        gp.acl().addPausableAdmin(CONFIGURATOR);
        gp.acl().addUnpausableAdmin(CONFIGURATOR);

        gp.acl().transferOwnership(address(gp));
        gp.claimACLOwnership();

        gp.addPriceFeeds(priceFeeds);
        gp.acl().claimOwnership();

        addressProvider = gp.addressProvider();
        af = AccountFactory(addressProvider.getAccountFactory());

        priceOracle = IPriceOracleV2Ext(addressProvider.getPriceOracle());

        acl = ACL(addressProvider.getACL());

        cr = ContractsRegister(addressProvider.getContractsRegister());

        withdrawalManager = new WithdrawalManager(address(addressProvider), 1 days);

        underlying = _underlying;

        poolMock = new PoolServiceMock(
            address(gp.addressProvider()),
            underlying
        );

        tokenTestSuite.mint(_underlying, address(poolMock), initialBalance);

        cr.addPool(address(poolMock));

        poolQuotaKeeper = new PoolQuotaKeeper(payable(address(poolMock)));

        gaugeMock = new GaugeMock(address(poolMock));

        vm.label(address(gaugeMock), "Gauge");

        poolQuotaKeeper.setGauge(address(gaugeMock));

        poolMock.setPoolQuotaKeeper(address(poolQuotaKeeper));

        addressProvider.transferOwnership(CONFIGURATOR);
        acl.transferOwnership(CONFIGURATOR);

        vm.startPrank(CONFIGURATOR);

        acl.claimOwnership();
        addressProvider.claimOwnership();

        vm.stopPrank();
    }
}
