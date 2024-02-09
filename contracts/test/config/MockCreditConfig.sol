// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {TokensTestSuite} from "../suites/TokensTestSuite.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import {NetworkDetector} from "@gearbox-protocol/sdk-gov/contracts/NetworkDetector.sol";
import {Contracts} from "@gearbox-protocol/sdk-gov/contracts/SupportedContracts.sol";
import "forge-std/console.sol";
import {CreditManagerOpts} from "../../credit/CreditConfiguratorV3.sol";

import {
    LinearIRMV3DeployParams,
    PoolV3DeployParams,
    CreditManagerV3DeployParams,
    GaugeRate,
    PoolQuotaLimit,
    IPoolV3DeployConfig,
    CollateralTokenHuman
} from "../interfaces/ICreditConfig.sol";
import {ITokenTestSuite} from "../interfaces/ITokenTestSuite.sol";

import "../lib/constants.sol";
import "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

contract MockCreditConfig is Test, IPoolV3DeployConfig {
    string public id;
    string public symbol;
    string public name;

    uint128 public minDebt;
    uint128 public maxDebt;
    uint256 public chainId;

    Tokens public underlying;
    bool public constant supportsQuotas = true;

    PoolV3DeployParams _poolParams;

    LinearIRMV3DeployParams _irm = LinearIRMV3DeployParams({
        U_1: 80_00,
        U_2: 90_00,
        R_base: 0,
        R_slope1: 5,
        R_slope2: 20,
        R_slope3: 100_00,
        _isBorrowingMoreU2Forbidden: true
    });

    GaugeRate[] _gaugeRates;
    PoolQuotaLimit[] _quotaLimits;
    CreditManagerV3DeployParams[] _creditManagers;

    constructor(TokensTestSuite tokenTestSuite_, Tokens _underlying) {
        NetworkDetector nd = new NetworkDetector();
        chainId = nd.chainId();

        underlying = _underlying;
        // underlying = tokenTestSuite_.addressOf(_underlying);
        id = string(abi.encodePacked("mock-test-", tokenTestSuite_.symbols(_underlying)));
        symbol = string(abi.encodePacked("d", tokenTestSuite_.symbols(_underlying)));
        name = string(abi.encodePacked("diesel", tokenTestSuite_.symbols(_underlying)));

        uint256 accountAmount = getAccountAmount();

        _poolParams = PoolV3DeployParams({withdrawalFee: 0, totalDebtLimit: type(uint256).max});

        // uint8 decimals = ERC20(tokenTestSuite_.addressOf(_underlying)).decimals();

        minDebt = uint128(accountAmount / 2); //150_000 * (10 ** decimals));
        maxDebt = uint128(10 * accountAmount);

        CreditManagerV3DeployParams storage cp = _creditManagers.push();

        cp.minDebt = minDebt;
        cp.maxDebt = maxDebt;
        cp.feeInterest = DEFAULT_FEE_INTEREST;
        cp.feeLiquidation = DEFAULT_FEE_LIQUIDATION;
        cp.liquidationPremium = DEFAULT_LIQUIDATION_PREMIUM;
        cp.feeLiquidationExpired = DEFAULT_FEE_LIQUIDATION_EXPIRED;
        cp.liquidationPremiumExpired = DEFAULT_LIQUIDATION_PREMIUM_EXPIRED;
        cp.whitelisted = false;
        cp.expirable = false;
        cp.skipInit = false;
        cp.poolLimit = type(uint256).max;
        cp.name = string.concat("Mock Credit Manager ", tokenTestSuite_.symbols(_underlying));

        pushCollateralToken(_underlying, cp.collateralTokens);
    }

    function pushCollateralToken(Tokens _underlying, CollateralTokenHuman[] storage cth) private {
        CollateralTokenHuman[8] memory collateralTokenOpts = [
            CollateralTokenHuman({token: Tokens.USDC, lt: 90_00}),
            CollateralTokenHuman({token: Tokens.USDT, lt: 88_00}),
            CollateralTokenHuman({token: Tokens.DAI, lt: 83_00}),
            CollateralTokenHuman({token: Tokens.WETH, lt: 83_00}),
            CollateralTokenHuman({token: Tokens.LINK, lt: 73_00}),
            CollateralTokenHuman({token: Tokens.CRV, lt: 73_00}),
            CollateralTokenHuman({token: Tokens.CVX, lt: 73_00}),
            CollateralTokenHuman({token: Tokens.STETH, lt: 73_00})
        ];

        uint256 len = collateralTokenOpts.length;

        for (uint256 i = 0; i < len; i++) {
            if (collateralTokenOpts[i].token == _underlying) continue;
            cth.push(collateralTokenOpts[i]);
        }
    }

    function getAccountAmount() public view override returns (uint256) {
        return (underlying == Tokens.DAI)
            ? DAI_ACCOUNT_AMOUNT
            : (underlying == Tokens.USDC) ? USDC_ACCOUNT_AMOUNT : WETH_ACCOUNT_AMOUNT;
    }

    // GETTERS

    function poolParams() external view override returns (PoolV3DeployParams memory) {
        return _poolParams;
    }

    function irm() external view override returns (LinearIRMV3DeployParams memory) {
        return _irm;
    }

    function gaugeRates() external view override returns (GaugeRate[] memory) {
        return _gaugeRates;
    }

    function quotaLimits() external view override returns (PoolQuotaLimit[] memory) {
        return _quotaLimits;
    }

    function creditManagers() external view override returns (CreditManagerV3DeployParams[] memory) {
        return _creditManagers;
    }
}
