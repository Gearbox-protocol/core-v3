// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AddressProviderV3ACLMock} from "../mocks/core/AddressProviderV3ACLMock.sol";
import {AccountFactoryV3} from "../../core/AccountFactoryV3.sol";
import {GearStakingV3} from "../../core/GearStakingV3.sol";
import {PriceFeedConfig} from "../interfaces/ICreditConfig.sol";

import "../interfaces/IAddressProviderV3.sol";
import {BotListV3} from "../../core/BotListV3.sol";
import {PriceOracleV3} from "../../core/PriceOracleV3.sol";

contract GenesisFactory is Ownable {
    AddressProviderV3ACLMock public addressProvider;
    PriceOracleV3 public priceOracle;

    constructor(address wethToken, address treasury) {
        addressProvider = new AddressProviderV3ACLMock();
        addressProvider.setAddress(AP_WETH_TOKEN, wethToken, false);
        addressProvider.setAddress(AP_TREASURY, treasury, false);
        addressProvider.setAddress(AP_ACL, address(addressProvider), false);
        addressProvider.setAddress(AP_CONTRACTS_REGISTER, address(addressProvider), false);

        priceOracle = new PriceOracleV3(address(addressProvider));
        addressProvider.setAddress(AP_PRICE_ORACLE, address(priceOracle), true);

        AccountFactoryV3 accountFactory = new AccountFactoryV3(msg.sender);
        addressProvider.setAddress(AP_ACCOUNT_FACTORY, address(accountFactory), true);

        BotListV3 botList = new BotListV3(msg.sender);
        addressProvider.setAddress(AP_BOT_LIST, address(botList), true);

        ERC20 gearToken = new ERC20("Gearbox", "GEAR");
        addressProvider.setAddress(AP_GEAR_TOKEN, address(gearToken), false);

        GearStakingV3 gearStaking = new GearStakingV3(msg.sender, address(gearToken), 1);
        addressProvider.setAddress(AP_GEAR_STAKING, address(gearStaking), true);

        addressProvider.addPausableAdmin(msg.sender);
        addressProvider.addUnpausableAdmin(msg.sender);
        addressProvider.transferOwnership(msg.sender);
    }
}
