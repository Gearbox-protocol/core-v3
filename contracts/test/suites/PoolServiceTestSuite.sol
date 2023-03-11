// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {AddressProvider} from "@gearbox-protocol/core-v2/contracts/core/AddressProvider.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";
import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";
import {DieselToken} from "@gearbox-protocol/core-v2/contracts/tokens/DieselToken.sol";

import {IPool4626, Pool4626Opts} from "../../interfaces/IPool4626.sol";
import {TestPoolService} from "@gearbox-protocol/core-v2/contracts/test/mocks/pool/TestPoolService.sol";
import {Tokens} from "../config/Tokens.sol";

import {LinearInterestRateModel} from "../../pool/LinearInterestRateModel.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditManagerMockForPoolTest} from "../mocks/pool/CreditManagerMockForPoolTest.sol";
import {WETHMock} from "@gearbox-protocol/core-v2/contracts/test/mocks/token/WETHMock.sol";
import {ERC20FeeMock} from "../mocks/token/ERC20FeeMock.sol";

import "../lib/constants.sol";
import {ITokenTestSuite} from "../interfaces/ITokenTestSuite.sol";
import {Pool4626} from "../../pool/Pool4626.sol";
import {PoolQuotaKeeper} from "../../pool/PoolQuotaKeeper.sol";
import {GaugeMock} from "../mocks/pool/GaugeMock.sol";
import {GaugeOpts} from "../../interfaces/IGauge.sol";

import {Pool4626_USDT} from "../../pool/Pool4626_USDT.sol";

uint256 constant liquidityProviderInitBalance = 100 ether;
uint256 constant addLiquidity = 10 ether;
uint256 constant removeLiquidity = 5 ether;
uint16 constant referral = 12333;

/// @title PoolServiceTestSuite
/// @notice Deploys contract for unit testing of PoolService.sol
contract PoolServiceTestSuite {
    CheatCodes evm = CheatCodes(HEVM_ADDRESS);

    ACL public acl;
    WETHMock public weth;

    AddressProvider public addressProvider;
    TestPoolService public poolService;
    Pool4626 public pool4626;
    CreditManagerMockForPoolTest public cmMock;
    IERC20 public underlying;
    DieselToken public dieselToken;
    LinearInterestRateModel public linearIRModel;
    PoolQuotaKeeper public poolQuotaKeeper;
    GaugeMock public gaugeMock;

    address public treasury;

    constructor(ITokenTestSuite _tokenTestSuite, address _underlying, bool is4626, bool supportQuotas) {
        linearIRModel = new LinearInterestRateModel(
            80_00,
            90_00,
            2_00,
            4_00,
            40_00,
            75_00,
            false
        );

        evm.startPrank(CONFIGURATOR);

        acl = new ACL();
        weth = WETHMock(payable(_tokenTestSuite.wethToken()));
        addressProvider = new AddressProvider();
        addressProvider.setACL(address(acl));
        addressProvider.setTreasuryContract(DUMB_ADDRESS2);
        ContractsRegister cr = new ContractsRegister(address(addressProvider));
        addressProvider.setContractsRegister(address(cr));
        treasury = DUMB_ADDRESS2;
        addressProvider.setWethToken(address(weth));

        underlying = IERC20(_underlying);

        _tokenTestSuite.mint(_underlying, USER, liquidityProviderInitBalance);
        _tokenTestSuite.mint(_underlying, INITIAL_LP, liquidityProviderInitBalance);

        address newPool;

        bool isFeeToken = false;

        try ERC20FeeMock(_underlying).basisPointsRate() returns (uint256) {
            isFeeToken = true;
        } catch {}

        if (is4626) {
            Pool4626Opts memory opts = Pool4626Opts({
                addressProvider: address(addressProvider),
                underlyingToken: _underlying,
                interestRateModel: address(linearIRModel),
                expectedLiquidityLimit: type(uint256).max,
                supportsQuotas: supportQuotas
            });
            pool4626 = isFeeToken ? new Pool4626_USDT(opts) : new Pool4626(opts);
            newPool = address(pool4626);

            if (supportQuotas) {
                _deployAndConnectPoolQuotaKeeper();
            }
        } else {
            poolService = new TestPoolService(
                address(addressProvider),
                address(underlying),
                address(linearIRModel),
                type(uint256).max
            );
            newPool = address(poolService);
            dieselToken = DieselToken(poolService.dieselToken());
            evm.label(address(dieselToken), "DieselToken");
        }

        evm.stopPrank();

        evm.prank(USER);
        underlying.approve(newPool, type(uint256).max);

        evm.prank(INITIAL_LP);
        underlying.approve(newPool, type(uint256).max);

        evm.startPrank(CONFIGURATOR);

        cmMock = new CreditManagerMockForPoolTest(newPool);

        cmMock.changePoolService(newPool);

        cr.addPool(newPool);
        cr.addCreditManager(address(cmMock));

        evm.label(newPool, "Pool");

        // evm.label(address(underlying), "UnderlyingToken");

        evm.stopPrank();
    }

    function _deployAndConnectPoolQuotaKeeper() internal {
        poolQuotaKeeper = new PoolQuotaKeeper(address(pool4626));

        // evm.prank(CONFIGURATOR);
        pool4626.connectPoolQuotaManager(address(poolQuotaKeeper));

        GaugeOpts memory gOpts = GaugeOpts({pool: address(pool4626), gearStaking: address(0)});
        gaugeMock = new GaugeMock(gOpts);

        // evm.prank(CONFIGURATOR);
        poolQuotaKeeper.setGauge(address(gaugeMock));
    }
}
