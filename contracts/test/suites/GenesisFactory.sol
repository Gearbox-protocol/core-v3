// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AddressProviderV3} from "../../core/AddressProviderV3.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";
import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";
import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";
import {AccountFactoryV3} from "../../core/AccountFactoryV3.sol";
import {GearStakingV3} from "../../governance/GearStakingV3.sol";
import {PriceFeedConfig} from "../interfaces/ICreditConfig.sol";

import "../../interfaces/IAddressProviderV3.sol";
import {BotListV3} from "../../core/BotListV3.sol";
import {PriceOracleV3} from "../../core/PriceOracleV3.sol";
import {GearToken} from "@gearbox-protocol/core-v2/contracts/tokens/GearToken.sol";

contract GenesisFactory is Ownable {
    AddressProviderV3 public addressProvider;
    ACL public acl;
    PriceOracleV3 public priceOracle;

    constructor(address wethToken, address treasury, uint256 accountFactoryVer) {
        acl = new ACL();
        addressProvider = new AddressProviderV3(address(acl));
        addressProvider.setAddress(AP_WETH_TOKEN, wethToken, false);
        addressProvider.setAddress(AP_TREASURY, treasury, false);

        ContractsRegister contractsRegister = new ContractsRegister(address(addressProvider));
        addressProvider.setAddress(AP_CONTRACTS_REGISTER, address(contractsRegister), false);

        priceOracle = new PriceOracleV3(address(addressProvider));
        addressProvider.setAddress(AP_PRICE_ORACLE, address(priceOracle), true);

        address accountFactory;
        if (accountFactoryVer == 1) {
            AccountFactory af = new AccountFactory(address(addressProvider));
            af.addCreditAccount();
            af.addCreditAccount();

            accountFactory = address(af);
        } else {
            accountFactory = address(new AccountFactoryV3(address(addressProvider)));
        }

        addressProvider.setAddress(AP_ACCOUNT_FACTORY, accountFactory, false);

        BotListV3 botList = new BotListV3(address(addressProvider));
        addressProvider.setAddress(AP_BOT_LIST, address(botList), true);

        GearToken gearToken = new GearToken(address(this));
        addressProvider.setAddress(AP_GEAR_TOKEN, address(gearToken), false);

        GearStakingV3 gearStaking = new GearStakingV3(address(addressProvider), 1);
        addressProvider.setAddress(AP_GEAR_STAKING, address(gearStaking), true);

        gearToken.transferOwnership(msg.sender);
        acl.transferOwnership(msg.sender);
    }

    function addPriceFeeds(PriceFeedConfig[] memory priceFeeds) external onlyOwner {
        uint256 len = priceFeeds.length;
        for (uint256 i; i < len; ++i) {
            priceOracle.setPriceFeed(
                priceFeeds[i].token, priceFeeds[i].priceFeed, priceFeeds[i].stalenessPeriod, priceFeeds[i].trusted
            );
        }
        acl.transferOwnership(msg.sender);
    }

    function claimACLOwnership() external onlyOwner {
        acl.claimOwnership();
    }
}
