// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {AddressProvider} from "@gearbox-protocol/core-v2/contracts/core/AddressProvider.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";
import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";
import {DieselToken} from "@gearbox-protocol/core-v2/contracts/tokens/DieselToken.sol";

import {IPool4626} from "../../interfaces/IPool4626.sol";
import {TestPoolService} from "@gearbox-protocol/core-v2/contracts/test/mocks/pool/TestPoolService.sol";
import {Tokens} from "../config/Tokens.sol";

import {LinearInterestRateModel} from "../../pool/LinearInterestRateModel.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditManagerMock} from "../mocks/credit/CreditManagerMock.sol";
import {WETHMock} from "@gearbox-protocol/core-v2/contracts/test/mocks/token/WETHMock.sol";
import {ERC20FeeMock} from "../mocks/token/ERC20FeeMock.sol";

import "../lib/constants.sol";
import {ITokenTestSuite} from "../interfaces/ITokenTestSuite.sol";
import {Pool4626} from "../../pool/Pool4626.sol";
import {PoolQuotaKeeper} from "../../pool/PoolQuotaKeeper.sol";
import {GaugeMock} from "../mocks/pool/GaugeMock.sol";

import {PoolServiceMock} from "../mocks/pool/PoolServiceMock.sol";
import {Test} from "forge-std/Test.sol";

uint256 constant liquidityProviderInitBalance = 100 ether;
uint256 constant addLiquidity = 10 ether;
uint256 constant removeLiquidity = 5 ether;
uint16 constant referral = 12333;

/// @title PoolServiceTestSuite
/// @notice Deploys contract for unit testing of PoolService.sol
contract PoolQuotaKeeperTestSuite is Test {
    ACL public acl;
    WETHMock public weth;

    AddressProvider public addressProvider;
    ContractsRegister public cr;

    PoolServiceMock public pool4626;
    CreditManagerMock public cmMock;
    IERC20 public underlying;

    PoolQuotaKeeper public poolQuotaKeeper;
    GaugeMock public gaugeMock;

    address public treasury;

    constructor(ITokenTestSuite _tokenTestSuite, address _underlying) {
        vm.startPrank(CONFIGURATOR);

        acl = new ACL();
        weth = WETHMock(payable(_tokenTestSuite.wethToken()));
        addressProvider = new AddressProvider();
        addressProvider.setACL(address(acl));
        addressProvider.setTreasuryContract(DUMB_ADDRESS2);
        cr = new ContractsRegister(address(addressProvider));
        addressProvider.setContractsRegister(address(cr));
        treasury = DUMB_ADDRESS2;
        addressProvider.setWethToken(address(weth));

        underlying = IERC20(_underlying);

        _tokenTestSuite.mint(_underlying, USER, liquidityProviderInitBalance);
        _tokenTestSuite.mint(_underlying, INITIAL_LP, liquidityProviderInitBalance);

        pool4626 = new PoolServiceMock(address(addressProvider), _underlying);

        poolQuotaKeeper = new PoolQuotaKeeper(address(pool4626));

        // vm.prank(CONFIGURATOR);
        pool4626.setPoolQuotaManager(address(poolQuotaKeeper));

        gaugeMock = new GaugeMock(address(pool4626));

        // vm.prank(CONFIGURATOR);
        poolQuotaKeeper.setGauge(address(gaugeMock));

        vm.stopPrank();

        vm.startPrank(CONFIGURATOR);

        cmMock = new CreditManagerMock(address(addressProvider), address(pool4626));

        cr.addPool(address(pool4626));
        cr.addCreditManager(address(cmMock));

        vm.label(address(pool4626), "Pool");

        vm.stopPrank();
    }
}
