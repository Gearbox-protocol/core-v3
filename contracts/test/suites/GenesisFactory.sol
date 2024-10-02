// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AddressProviderV3ACLMock} from "../mocks/core/AddressProviderV3ACLMock.sol";
import {AccountFactoryV3} from "../../core/AccountFactoryV3.sol";
import {GearStakingV3} from "../../core/GearStakingV3.sol";
import {BotListV3} from "../../core/BotListV3.sol";
import {PriceFeedConfig} from "../interfaces/ICreditConfig.sol";
import {IContractsRegister} from "../../interfaces/base/IContractsRegister.sol";
import {GearStakingV3} from "../../core/GearStakingV3.sol";

import "../interfaces/IAddressProviderV3.sol";
import {BotListV3} from "../../core/BotListV3.sol";
import {PriceOracleV3} from "../../core/PriceOracleV3.sol";

contract GenesisFactory is Ownable {
    AddressProviderV3ACLMock public acl;
    PriceOracleV3 public priceOracle;
    BotListV3 public botList;
    AccountFactoryV3 public accountFactory;
    IContractsRegister public contractsRegister;
    GearStakingV3 public gearStaking;

    constructor() {
        acl = new AddressProviderV3ACLMock();
        contractsRegister = IContractsRegister(address(acl));

        priceOracle = new PriceOracleV3(address(acl));
        accountFactory = new AccountFactoryV3(msg.sender);
        botList = new BotListV3(msg.sender);

        ERC20 gearToken = new ERC20("Gearbox", "GEAR");

        gearStaking = new GearStakingV3(msg.sender, address(gearToken), 1);

        acl.addPausableAdmin(msg.sender);
        acl.addUnpausableAdmin(msg.sender);
        acl.transferOwnership(msg.sender);
    }
}
