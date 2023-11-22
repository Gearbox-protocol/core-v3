// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IntegrationTestHelper} from "../helpers/IntegrationTestHelper.sol";
import {AdapterMock} from "../mocks/core/AdapterMock.sol";
import {TargetContractMock} from "../mocks/core/TargetContractMock.sol";

// SUITES
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

import "../lib/constants.sol";
import "forge-std/Vm.sol";

contract GearboxInstance is IntegrationTestHelper {
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

        targetMock = new TargetContractMock();
        adapterMock = new AdapterMock(address(creditManager), address(targetMock));

        vm.prank(CONFIGURATOR);
        creditConfigurator.allowAdapter(address(adapterMock));
    }

    function mf() external {
        vm.roll(block.number + 1);
    }

    function getVm() external pure returns (Vm) {
        return vm;
    }
}
