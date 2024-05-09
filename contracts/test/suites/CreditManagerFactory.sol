// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/Create2.sol";

import "../interfaces/IAddressProviderV3.sol";

import {CreditManagerV3} from "../../credit/CreditManagerV3.sol";
import {CreditFacadeV3} from "../../credit/CreditFacadeV3.sol";
import {CreditConfiguratorV3, CreditManagerOpts} from "../../credit/CreditConfiguratorV3.sol";

/// @title CreditManagerFactory
/// @notice Deploys 3 core interdependent contracts: CreditManage, CreditFacadeV3 and CredigConfigurator
///         and setup them by following options
contract CreditManagerFactory {
    CreditManagerV3 public creditManager;
    CreditFacadeV3 public creditFacade;
    CreditConfiguratorV3 public creditConfigurator;

    constructor(address _ap, address _pool, CreditManagerOpts memory opts, bytes32 salt) {
        address acl = IAddressProviderV3(_ap).getAddressOrRevert(AP_ACL, NO_VERSION_CONTROL);
        address weth = IAddressProviderV3(_ap).getAddressOrRevert(AP_WETH_TOKEN, NO_VERSION_CONTROL);
        address accountFactory = IAddressProviderV3(_ap).getAddressOrRevert(AP_ACCOUNT_FACTORY, 3_00);
        address priceOracle = IAddressProviderV3(_ap).getAddressOrRevert(AP_PRICE_ORACLE, 3_10);
        address botList = IAddressProviderV3(_ap).getAddressOrRevert(AP_BOT_LIST, 3_10);

        creditManager = new CreditManagerV3(_pool, accountFactory, priceOracle, opts.name);
        creditFacade = new CreditFacadeV3(acl, address(creditManager), botList, weth, opts.degenNFT, opts.expirable);

        bytes memory configuratorByteCode = abi.encodePacked(
            type(CreditConfiguratorV3).creationCode, abi.encode(acl, creditManager, creditFacade, opts)
        );

        creditConfigurator = CreditConfiguratorV3(Create2.computeAddress(salt, keccak256(configuratorByteCode)));

        creditManager.setCreditConfigurator(address(creditConfigurator));

        Create2.deploy(0, salt, configuratorByteCode);

        require(address(creditConfigurator.creditManager()) == address(creditManager), "Incorrect CM");
    }
}
