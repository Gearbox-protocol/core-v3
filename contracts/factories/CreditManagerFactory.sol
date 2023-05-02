// SPDX-License-Identifier: BUSL-1.1
// Gearbox. Generalized leverage protocol that allows to take leverage and then use it across other DeFi protocols and platforms in a composable way.
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/utils/Create2.sol";

import {CreditManagerV3} from "../credit/CreditManagerV3.sol";
import {CreditFacadeV3} from "../credit/CreditFacadeV3.sol";
import {CreditConfigurator, CreditManagerOpts} from "../credit/CreditConfiguratorV3.sol";

/// @title CreditManagerFactory
/// @notice Deploys 3 core interdependent contracts: CreditManage, CreditFacadeV3 and CredigConfigurator
///         and setup them by following options
contract CreditManagerFactory {
    CreditManagerV3 public creditManager;
    CreditFacadeV3 public creditFacade;
    CreditConfigurator public creditConfigurator;

    constructor(address _pool, CreditManagerOpts memory opts, bytes32 salt) {
        creditManager = new CreditManagerV3(_pool, opts.withdrawManager);
        creditFacade = new CreditFacadeV3(
            address(creditManager),
            opts.degenNFT,
            opts.expirable
        );

        bytes memory configuratorByteCode =
            abi.encodePacked(type(CreditConfigurator).creationCode, abi.encode(creditManager, creditFacade, opts));

        creditConfigurator = CreditConfigurator(Create2.computeAddress(salt, keccak256(configuratorByteCode)));

        creditManager.setCreditConfigurator(address(creditConfigurator));

        Create2.deploy(0, salt, configuratorByteCode);

        require(address(creditConfigurator.creditManager()) == address(creditManager), "Incorrect CM");
    }
}
