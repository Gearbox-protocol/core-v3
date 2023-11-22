// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GearboxInstance} from "./Deployer.sol";
import {MulticallGenerator} from "./MulticallGenerator.sol";
import {MulticallParser} from "./MulticallParser.sol";
import "../../interfaces/ICreditFacadeV3Multicall.sol";

import {IPriceOracleV3} from "../../interfaces/IPriceOracleV3.sol";
import {ICreditManagerV3, CollateralCalcTask} from "../../interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3, ICreditFacadeV3Multicall} from "../../interfaces/ICreditFacadeV3.sol";
import {IPoolQuotaKeeperV3} from "../../interfaces/IPoolQuotaKeeperV3.sol";
import {MultiCall} from "../../interfaces/ICreditFacadeV3.sol";
import {MultiCallBuilder} from "../lib/MultiCallBuilder.sol";

// SUITES
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

import "forge-std/Test.sol";
import "../lib/constants.sol";
import "forge-std/console.sol";
import "forge-std/Vm.sol";

contract MulticallGeneratorTest is GearboxInstance {
    MulticallGenerator mcg;
    MulticallParser mp;

    function setUp() public {
        _setUp();

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

        mcg = new MulticallGenerator(address(creditManager));
        mp = new MulticallParser(creditManager);

        uint256 cTokensQty = creditManager.collateralTokensCount();

        vm.startPrank(USER);
        for (uint256 i; i < cTokensQty; ++i) {
            (address token,) = creditManager.collateralTokenByMask(1 << i);
            IERC20(token).approve(address(creditManager), type(uint256).max);
            tokenTestSuite.mint(token, USER, type(uint80).max);
        }
        vm.stopPrank();
    }

    function test_mcg01_generateMultiCall() public {
        address creditAccount = creditFacade.openCreditAccount(USER, new MultiCall[](0), 0);
        mcg.setCreditAccount(creditAccount);

        uint256 successCases;

        for (uint256 j = 0; j < 3; ++j) {
            console.log("");
            console.log("============ MULTICALL #%s ============", j);
            MultiCall[] memory calls = mcg.generateRandomMulticalls(j, ALL_PERMISSIONS);
            mp.print(calls);

            vm.startPrank(USER);
            try creditFacade.multicall(creditAccount, calls) {
                console.log("success!");
                ++successCases;
            } catch {
                console.log("Error!");
            }

            vm.stopPrank();
        }
        console.log("Success cases: %s of 100", successCases);
    }
}
