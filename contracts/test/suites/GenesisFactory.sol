// SPDX-License-Identifier: BUSL-1.1
// Gearbox. Generalized leverage protocol that allows to take leverage and then use it across other DeFi protocols and platforms in a composable way.
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AddressProviderV3} from "../../core/AddressProviderV3.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";
import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";
import {DataCompressor} from "@gearbox-protocol/core-v2/contracts/core/DataCompressor.sol";
import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";
import {AccountFactoryV3} from "../../core/AccountFactoryV3.sol";
import "../../interfaces/IAddressProviderV3.sol";
import {WithdrawalManager} from "../../support/WithdrawalManager.sol";

import {WETHGateway} from "../../support/WETHGateway.sol";
import {PriceOracle, PriceFeedConfig} from "@gearbox-protocol/core-v2/contracts/oracles/PriceOracle.sol";
import {GearToken} from "@gearbox-protocol/core-v2/contracts/tokens/GearToken.sol";

contract GenesisFactory is Ownable {
    AddressProviderV3 public addressProvider;
    ACL public acl;
    PriceOracle public priceOracle;

    constructor(address wethToken, address treasury, uint8 accountFactoryVer) {
        acl = new ACL(); // T:[GD-1]
        addressProvider = new AddressProviderV3(address(acl)); // T:[GD-1]
        addressProvider.setAddress(AP_WETH_TOKEN, wethToken, false); // T:[GD-1]
        addressProvider.setAddress(AP_TREASURY, treasury, false); // T:[GD-1]

        ContractsRegister contractsRegister = new ContractsRegister(
            address(addressProvider)
        ); // T:[GD-1]
        addressProvider.setAddress(AP_CONTRACTS_REGISTER, address(contractsRegister), true); // T:[GD-1]

        DataCompressor dataCompressor = new DataCompressor(
            address(addressProvider)
        ); // T:[GD-1]
        addressProvider.setAddress(AP_DATA_COMPRESSOR, address(dataCompressor), true); // T:[GD-1]

        PriceFeedConfig[] memory config;
        priceOracle = new PriceOracle(address(addressProvider), config); // T:[GD-1]
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

        addressProvider.setAddress(AP_ACCOUNT_FACTORY, accountFactory, true); // T:[GD-1]

        WETHGateway wethGateway = new WETHGateway(address(addressProvider)); // T:[GD-1]
        addressProvider.setAddress(AP_WETH_GATEWAY, address(wethGateway), true); // T:[GD-1]

        WithdrawalManager wm = new WithdrawalManager(address(addressProvider), 1 days);
        addressProvider.setAddress(AP_WITHDRAWAL_MANAGER, address(wm), true);

        GearToken gearToken = new GearToken(address(this)); // T:[GD-1]
        addressProvider.setAddress(AP_GEAR_TOKEN, address(gearToken), false); // T:[GD-1]
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
