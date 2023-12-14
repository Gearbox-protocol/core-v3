// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {BitMask, UNDERLYING_TOKEN_MASK} from "../../libraries/BitMask.sol";
import {Random} from "./Random.sol";

import "../../interfaces/ICreditFacadeV3Multicall.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GearboxInstance} from "./Deployer.sol";

import {IPriceOracleV3} from "../../interfaces/IPriceOracleV3.sol";
import {ICreditManagerV3, CollateralCalcTask} from "../../interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3, ICreditFacadeV3Multicall} from "../../interfaces/ICreditFacadeV3.sol";
import {IPoolQuotaKeeperV3} from "../../interfaces/IPoolQuotaKeeperV3.sol";
import {MultiCall} from "../../interfaces/ICreditFacadeV3.sol";
import {MultiCallBuilder} from "../lib/MultiCallBuilder.sol";
import {AdapterAttacker} from "./AdapterAttacker.sol";
import {TargetAttacker} from "./TargetAttacker.sol";

import "forge-std/Test.sol";
import "../lib/constants.sol";
import "forge-std/console.sol";
import "forge-std/Vm.sol";

// function onDemandPriceUpdate(address token, bool reserve, bytes calldata data) external;
// for this function we'll use Mock which can update the price without any signature

// function storeExpectedBalances(BalanceDelta[] calldata balanceDeltas) external;
// This is specific case which will be tested separatedly

// function compareBalances() external;
// This is specific case which will be tested separatedly

// Multicall generator is used to
contract MulticallGenerator is Random {
    using BitMask for uint256;

    address adapterAttacker;

    uint8 maxCallDepth = 10;

    uint256 debt;

    ICreditManagerV3 creditManager;
    ICreditFacadeV3 creditFacade;
    IPriceOracleV3 priceOracle;

    address underlying;

    address creditAccount;

    mapping(address => uint96) quotaLimits;

    uint256 permissions;
    bool followPermissions;

    constructor(address _creditManager, address _adapterAttacker) {
        creditManager = ICreditManagerV3(_creditManager);
        creditFacade = ICreditFacadeV3(creditManager.creditFacade());
        priceOracle = IPriceOracleV3(creditManager.priceOracle());
        underlying = creditManager.underlying();
        adapterAttacker = _adapterAttacker;
    }

    function setCreditAccount(address _creditAccount) external {
        creditAccount = _creditAccount;
    }

    function generateRandomMulticalls(uint256 _seed, uint256 _permissions)
        external
        returns (MultiCall[] memory calls)
    {
        setSeed(_seed);
        permissions = _permissions;

        followPermissions = getRandomP() <= pThreshold;

        debt = creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY).debt;

        uint256 len = getRandomInRange(1, maxCallDepth);
        calls = new MultiCall[](len);
        for (uint256 i; i < len; ++i) {
            calls[i] = generateRandomCall();
        }
    }

    // todo: 1. add external call
    // todo: 2. make executable multicalls

    function generateRandomCall() public returns (MultiCall memory call) {
        function() returns (MultiCall memory, bool)[10] memory fns = [
            randomAddCollateral,
            randomUpdateQuota,
            randomSetFullCheckParams,
            randomIncreaseDebt,
            randomDecreaseDebt,
            randomWithdrawCollateral,
            randomEnabledToken,
            randomDisabledToken,
            randomRevokeAdapterAllowances,
            randomExternalCall
        ];

        bool success;
        do {
            (call, success) = fns[getRandomInRange(fns.length)]();
        } while (!success);
    }

    // function addCollateral(address token, uint256 amount) external;
    // here we'll pick any token from CM and any reasonable amount (how to set it)
    function randomAddCollateral() internal returns (MultiCall memory, bool success) {
        if (!followPermissions || (permissions & ADD_COLLATERAL_PERMISSION != 0)) {
            address token = getRandomCollateralToken();

            (, uint256 maxDebt) = creditFacade.debtLimits();
            uint256 reasonableMaxCollateral = IPriceOracleV3(creditManager.priceOracle()).convert({
                amount: maxDebt,
                tokenFrom: underlying,
                tokenTo: token
            });

            uint256 amount = getRandomInRange95(reasonableMaxCollateral);
            return (
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (token, amount))
                }),
                true
            );
        }
    }

    // function addCollateralWithPermit(address token, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
    //     external;
    // TODO: implement later

    // function updateQuota(address token, int96 quotaChange, uint96 minQuota) external;
    // Here we'll pick token from CM
    // quotaChange with be picked with reasonable value [1-maxChange]
    // minQuota with be picker with reasonable value

    function randomUpdateQuota() internal returns (MultiCall memory, bool success) {
        if (!followPermissions || (permissions & UPDATE_QUOTA_PERMISSION != 0)) {
            if (getRandomP() > pThreshold || debt != 0) {
                uint256 quotedTokensMask = creditManager.quotedTokensMask();

                if (quotedTokensMask == 0) {
                    MultiCall memory _call;
                    return (_call, false);
                }

                uint256 collateralTokensCount = creditManager.collateralTokensCount();
                uint256 mask;
                do {
                    // mask is generated in range [1; collateralTokensCount], because
                    // underlying token could not be quoted one
                    mask = 1 << getRandomInRange(1, collateralTokensCount);
                } while (quotedTokensMask & mask == 0);

                address token = creditManager.getTokenByMask(mask);
                uint256 quotaAvailable;
                uint256 quotaCurrent;
                {
                    address pqk = creditManager.poolQuotaKeeper();
                    (,,, uint96 totalQuoted, uint96 limit, bool isActive) =
                        IPoolQuotaKeeperV3(pqk).getTokenQuotaParams(token);

                    (quotaCurrent,) = IPoolQuotaKeeperV3(pqk).getQuota(creditAccount, token);

                    quotaAvailable = isActive && limit > totalQuoted ? limit - totalQuoted : 0;
                }

                int96 quota = int96(uint96(getNextRandomNumber()));

                if (quota < int96(uint96(quotaCurrent))) {
                    quota = type(int96).min;
                }

                uint96 minQuota = uint96(getRandomInRange95(quotaAvailable));

                return (
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (token, int96(quota), minQuota))
                    }),
                    true
                );
            }
        }
    }
    // function setFullCheckParams(uint256[] calldata collateralHints, uint16 minHealthFactor) external;
    // collateralHints will be chosen properly like 1 << i, where i <= collateralTokensCound

    function randomSetFullCheckParams() internal returns (MultiCall memory, bool success) {
        // for test pufposes, it generates values 10-12K in 95% of cases
        uint16 minHealhFactor = uint16(getRandomInRange95(10_000, 12_000));

        uint256 collateralTokensCount = creditManager.collateralTokensCount();
        uint256 len = getRandomInRange(collateralTokensCount);
        uint256[] memory collateralHints = new uint256[](len);

        unchecked {
            for (uint256 i; i < len; ++i) {
                // tests which check that function reverts for incorrect collateral
                // token mask cover this cases, so for invariant testing
                // it's assumed that function reverts for all of them
                collateralHints[i] = 1 << getRandomInRange(collateralTokensCount);
            }
        }

        return (
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.setFullCheckParams, (collateralHints, minHealhFactor))
            }),
            true
        );
    }

    // function increaseDebt(uint256 amount) external
    // Here we'll pick reasonable amount in [0; maxDebt - debt] with probabiliy p and unreasonble with (1-p)
    function randomIncreaseDebt() internal returns (MultiCall memory, bool success) {
        if (!followPermissions || (permissions & INCREASE_DEBT_PERMISSION != 0)) {
            permissions = permissions.disable(INCREASE_DEBT_PERMISSION).disable(DECREASE_DEBT_PERMISSION);

            (, uint256 maxDebt) = creditFacade.debtLimits();

            uint256 reasonableIncreaseDebt = maxDebt - debt;

            uint256 amount = getRandomInRange95(reasonableIncreaseDebt);

            debt += amount;

            return (
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (amount))
                }),
                true
            );
        }
    }

    // function decreaseDebt(uint256 amount) external;
    // Here we'll pick reasonable amount in [0; debt] with probability p and unreasonable with (1-p)
    function randomDecreaseDebt() internal returns (MultiCall memory, bool success) {
        if (!followPermissions || (permissions & DECREASE_DEBT_PERMISSION != 0)) {
            permissions = permissions.disable(INCREASE_DEBT_PERMISSION).disable(DECREASE_DEBT_PERMISSION);

            (uint256 minDebt,) = creditFacade.debtLimits();

            uint256 amount = debt == 0 ? 0 : getRandomInRange95(debt - minDebt);

            debt -= amount < debt ? amount : debt;

            return (
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (amount))
                }),
                true
            );
        }
    }

    // function withdrawCollateral(address token, uint256 amount, address to) external;
    // token wll be picked from CM
    // amoutn will be chosen as reasonable value (1-balance) and unreasonable value with p
    // address to with be picked randomly from [user, creditAccount, creditManager, creditFacade, adapter, ]
    function randomWithdrawCollateral() internal returns (MultiCall memory, bool success) {
        if (!followPermissions || (permissions & WITHDRAW_COLLATERAL_PERMISSION != 0)) {
            address token = getRandomCollateralToken();
            uint256 balance = IERC20(token).balanceOf(creditAccount);

            uint256 amount = getRandomInRange95(balance);
            return (
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (token, amount, USER))
                }),
                true
            );
        }
    }

    // function enableToken(address token) external;
    // Any token on CM will be chosen
    function randomEnabledToken() internal returns (MultiCall memory, bool success) {
        if (!followPermissions || (permissions & ENABLE_TOKEN_PERMISSION != 0)) {
            address token = getRandomCollateralToken();
            return (
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.enableToken, (token))
                }),
                true
            );
        }
    }

    // function disableToken(address token) external;
    // Any token on CM will be chosen
    function randomDisabledToken() internal returns (MultiCall memory, bool success) {
        if (!followPermissions || (permissions & DISABLE_TOKEN_PERMISSION != 0)) {
            address token = getRandomCollateralToken();
            return (
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.disableToken, (token))
                }),
                true
            );
        }
    }

    // function revokeAdapterAllowances(RevocationPair[] calldata revocations) external;
    // any token and revocations with be chosen
    function randomRevokeAdapterAllowances() internal returns (MultiCall memory, bool success) {
        if (!followPermissions || (permissions & REVOKE_ALLOWANCES_PERMISSION != 0)) {}
    }

    function randomExternalCall() internal returns (MultiCall memory, bool success) {
        if (!followPermissions || (permissions & EXTERNAL_CALLS_PERMISSION != 0)) {
            bytes memory targetCalldata = abi.encodeCall(TargetAttacker.act, (seed));

            return (
                MultiCall({
                    target: adapterAttacker,
                    callData: abi.encodeCall(AdapterAttacker.executeAllApprove, (targetCalldata))
                }),
                true
            );
        }
    }

    //
    // INTERNAL
    //
    function getRandomCollateralToken() internal returns (address) {
        return creditManager.getTokenByMask(1 << getRandomCollateralTokenIndex());
    }

    function getRandomCollateralTokenIndex() internal returns (uint8) {
        return uint8(getRandomInRange(creditManager.collateralTokensCount()));
    }
}
