// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.23;

import {TokensTestSuite} from "../suites/TokensTestSuite.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import {NetworkDetector} from "@gearbox-protocol/sdk-gov/contracts/NetworkDetector.sol";
import {Contracts} from "@gearbox-protocol/sdk-gov/contracts/SupportedContracts.sol";
import "forge-std/console.sol";

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
import "../../libraries/Constants.sol";

contract MockCreditConfig is Test, IPoolV3DeployConfig {
    string public id = "mock-test-DAI";
    string public symbol = "dDAIv3";
    string public name = "Diesel DAI v3";

    uint256 public chainId;
    Tokens public underlying = Tokens.DAI;
    bool public constant supportsQuotas = true;
    uint256 public constant getAccountAmount = DAI_ACCOUNT_AMOUNT;

    PoolV3DeployParams _poolParams = PoolV3DeployParams({withdrawalFee: 0, totalDebtLimit: type(uint256).max});

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

    constructor() {
        NetworkDetector nd = new NetworkDetector();
        chainId = nd.chainId();

        _gaugeRates.push(GaugeRate({token: Tokens.USDC, minRate: 1, maxRate: 10_000}));
        _gaugeRates.push(GaugeRate({token: Tokens.USDT, minRate: 1, maxRate: 10_000}));
        _gaugeRates.push(GaugeRate({token: Tokens.WETH, minRate: 1, maxRate: 10_000}));
        _gaugeRates.push(GaugeRate({token: Tokens.LINK, minRate: 1, maxRate: 10_000}));
        _gaugeRates.push(GaugeRate({token: Tokens.CRV, minRate: 1, maxRate: 10_000}));
        _gaugeRates.push(GaugeRate({token: Tokens.CVX, minRate: 1, maxRate: 10_000}));
        _gaugeRates.push(GaugeRate({token: Tokens.STETH, minRate: 1, maxRate: 10_000}));

        _quotaLimits.push(PoolQuotaLimit({token: Tokens.USDC, quotaIncreaseFee: 0, limit: uint96(type(int96).max)}));
        _quotaLimits.push(PoolQuotaLimit({token: Tokens.USDT, quotaIncreaseFee: 0, limit: uint96(type(int96).max)}));
        _quotaLimits.push(PoolQuotaLimit({token: Tokens.WETH, quotaIncreaseFee: 0, limit: uint96(type(int96).max)}));
        _quotaLimits.push(PoolQuotaLimit({token: Tokens.LINK, quotaIncreaseFee: 0, limit: uint96(type(int96).max)}));
        _quotaLimits.push(PoolQuotaLimit({token: Tokens.CRV, quotaIncreaseFee: 0, limit: uint96(type(int96).max)}));
        _quotaLimits.push(PoolQuotaLimit({token: Tokens.CVX, quotaIncreaseFee: 0, limit: uint96(type(int96).max)}));
        _quotaLimits.push(PoolQuotaLimit({token: Tokens.STETH, quotaIncreaseFee: 0, limit: uint96(type(int96).max)}));

        CreditManagerV3DeployParams storage cp = _creditManagers.push();

        cp.minDebt = uint128(getAccountAmount / 2);
        cp.maxDebt = uint128(10 * getAccountAmount);
        cp.maxEnabledTokens = DEFAULT_MAX_ENABLED_TOKENS;
        cp.feeInterest = DEFAULT_FEE_INTEREST;
        cp.feeLiquidation = DEFAULT_FEE_LIQUIDATION;
        cp.liquidationPremium = DEFAULT_LIQUIDATION_PREMIUM;
        cp.feeLiquidationExpired = DEFAULT_FEE_LIQUIDATION_EXPIRED;
        cp.liquidationPremiumExpired = DEFAULT_LIQUIDATION_PREMIUM_EXPIRED;
        cp.whitelisted = false;
        cp.expirable = false;
        cp.skipInit = false;
        cp.poolLimit = type(uint256).max;
        cp.name = "Mock Credit Manager DAI";

        CollateralTokenHuman[] storage cts = cp.collateralTokens;
        cts.push(CollateralTokenHuman({token: Tokens.USDC, lt: 90_00}));
        cts.push(CollateralTokenHuman({token: Tokens.USDT, lt: 88_00}));
        cts.push(CollateralTokenHuman({token: Tokens.WETH, lt: 83_00}));
        cts.push(CollateralTokenHuman({token: Tokens.LINK, lt: 73_00}));
        cts.push(CollateralTokenHuman({token: Tokens.CRV, lt: 73_00}));
        cts.push(CollateralTokenHuman({token: Tokens.CVX, lt: 73_00}));
        cts.push(CollateralTokenHuman({token: Tokens.STETH, lt: 73_00}));
    }

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
