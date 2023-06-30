// SPDX-License-Identifier: BUSL-1.1
// Gearbox. Generalized leverage protocol that allows to take leverage and then use it across other DeFi protocols and platforms in a composable way.
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AddressProviderV3} from "../../core/AddressProviderV3.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";
import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";
import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";
import {AccountFactoryV3} from "../../core/AccountFactoryV3.sol";
import {GearStakingV3} from "../../governance/GearStakingV3.sol";

import "../../interfaces/IAddressProviderV3.sol";
import {WithdrawalManagerV3} from "../../core/WithdrawalManagerV3.sol";
import {BotListV3} from "../../core/BotListV3.sol";
import {PriceOracleV2, PriceFeedConfig} from "@gearbox-protocol/core-v2/contracts/oracles/PriceOracleV2.sol";
import {GearToken} from "@gearbox-protocol/core-v2/contracts/tokens/GearToken.sol";

contract GenesisFactory is Ownable {
    AddressProviderV3 public addressProvider;
    ACL public acl;
    PriceOracleV2 public priceOracle;

    constructor(address wethToken, address treasury, uint256 accountFactoryVer) {
        acl = new ACL(); // T:[GD-1]
        addressProvider = new AddressProviderV3(address(acl)); // T:[GD-1]
        addressProvider.setAddress(AP_WETH_TOKEN, wethToken, false); // T:[GD-1]
        addressProvider.setAddress(AP_TREASURY, treasury, false); // T:[GD-1]

        ContractsRegister contractsRegister = new ContractsRegister(
            address(addressProvider)
        ); // T:[GD-1]
        addressProvider.setAddress(AP_CONTRACTS_REGISTER, address(contractsRegister), true); // T:[GD-1]

        PriceFeedConfig[] memory config;
        priceOracle = new PriceOracleV2(address(addressProvider), config); // T:[GD-1]
        addressProvider.setAddress(AP_PRICE_ORACLE, address(priceOracle), true); // T:[GD-1]

        address accountFactory;

        if (accountFactoryVer == 1) {
            AccountFactory af = new AccountFactory(
                                    address(addressProvider)
                                    );
            af.addCreditAccount();
            af.addCreditAccount();

            accountFactory = address(af);
        } else {
            accountFactory = address(new  AccountFactoryV3( address(addressProvider))); // T:[GD-1]
        }

        addressProvider.setAddress(AP_ACCOUNT_FACTORY, accountFactory, false); // T:[GD-1]

        WithdrawalManagerV3 wm = new WithdrawalManagerV3(address(addressProvider), 1 days);
        addressProvider.setAddress(AP_WITHDRAWAL_MANAGER, address(wm), true);

        BotListV3 botList = new BotListV3(address(addressProvider));
        addressProvider.setAddress(AP_BOT_LIST, address(botList), true);

        GearToken gearToken = new GearToken(address(this)); // T:[GD-1]
        addressProvider.setAddress(AP_GEAR_TOKEN, address(gearToken), false); // T:[GD-1]

        GearStakingV3 gearStaking = new GearStakingV3(address(addressProvider), 1);
        addressProvider.setAddress(AP_GEAR_STAKING, address(gearStaking), true);

        gearToken.transferOwnership(msg.sender); // T:[GD-1]
        acl.transferOwnership(msg.sender); // T:[GD-1]
    }

    function addPriceFeeds(PriceFeedConfig[] memory priceFeeds)
        external
        onlyOwner // T:[GD-3]
    {
        for (uint256 i = 0; i < priceFeeds.length; ++i) {
            priceOracle.addPriceFeed(priceFeeds[i].token, priceFeeds[i].priceFeed); // T:[GD-4]
        }

        acl.transferOwnership(msg.sender); // T:[GD-4]
    }

    function claimACLOwnership() external onlyOwner {
        acl.claimOwnership();
    }
}
