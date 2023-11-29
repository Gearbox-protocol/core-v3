// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IntegrationTestHelper} from "../helpers/IntegrationTestHelper.sol";
import {AdapterAttacker} from "./AdapterAttacker.sol";
import {TargetAttacker} from "./TargetAttacker.sol";

// SUITES
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

import "../lib/constants.sol";
import "forge-std/Vm.sol";

contract GearboxInstance is IntegrationTestHelper {
    address public targetAttacker;
    address public adapterAttacker;

    function _setUp() public {
        _setupCore();

        _deployMockCreditAndPool();

        vm.startPrank(CONFIGURATOR);
        gauge.addQuotaToken(tokenTestSuite.addressOf(Tokens.LINK), 500, 500);
        poolQuotaKeeper.setTokenLimit(tokenTestSuite.addressOf(Tokens.LINK), type(uint96).max);
        creditConfigurator.makeTokenQuoted(tokenTestSuite.addressOf(Tokens.LINK));

        gauge.addQuotaToken(tokenTestSuite.addressOf(Tokens.USDC), 500, 500);
        poolQuotaKeeper.setTokenLimit(tokenTestSuite.addressOf(Tokens.USDC), type(uint96).max);
        creditConfigurator.makeTokenQuoted(tokenTestSuite.addressOf(Tokens.USDC));

        gauge.addQuotaToken(tokenTestSuite.addressOf(Tokens.WETH), 500, 500);
        poolQuotaKeeper.setTokenLimit(tokenTestSuite.addressOf(Tokens.WETH), type(uint96).max);
        creditConfigurator.makeTokenQuoted(tokenTestSuite.addressOf(Tokens.WETH));
        vm.stopPrank();

        targetAttacker =
            address(new TargetAttacker(address(creditManager), address(priceOracle), address(tokenTestSuite)));
        adapterAttacker = address(new AdapterAttacker(address(creditManager), address(targetAttacker)));

        vm.prank(CONFIGURATOR);
        creditConfigurator.allowAdapter(address(adapterAttacker));
    }

    function mf() external {
        vm.roll(block.number + 1);
    }

    function getVm() external pure returns (Vm) {
        return vm;
    }
}
