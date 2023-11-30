// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {CreditManagerV3, CreditAccountInfo} from "../../../credit/CreditManagerV3.sol";
import {USDT_Transfer} from "../../../traits/USDT_Transfer.sol";

import {CollateralDebtData, CollateralCalcTask, CollateralTokenData} from "../../../interfaces/ICreditManagerV3.sol";
import {IPoolV3} from "../../../interfaces/IPoolV3.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

contract CreditManagerV3Harness is CreditManagerV3, USDT_Transfer {
    using EnumerableSet for EnumerableSet.AddressSet;

    bool _enableTransferFee;

    constructor(address _addressProvider, address _pool, string memory _name, bool enableTransferFee)
        CreditManagerV3(_addressProvider, _pool, _name)
        USDT_Transfer(IPoolV3(_pool).underlyingToken())
    {
        _enableTransferFee = enableTransferFee;
    }

    function setReentrancy(uint8 _status) external {
        _reentrancyStatus = _status;
    }

    function setDebt(address creditAccount, CreditAccountInfo memory _creditAccountInfo) external {
        creditAccountInfo[creditAccount] = _creditAccountInfo;
    }

    function approveSpender(address token, address targetContract, address creditAccount, uint256 amount) external {
        _approveSpender(token, targetContract, creditAccount, amount);
    }

    function getTargetContractOrRevert() external view returns (address targetContract) {
        return _getTargetContractOrRevert();
    }

    function addToCAList(address creditAccount) external {
        creditAccountsSet.add(creditAccount);
    }

    function setBorrower(address creditAccount, address borrower) external {
        creditAccountInfo[creditAccount].borrower = borrower;
    }

    function setLastDebtUpdate(address creditAccount, uint64 lastDebtUpdate) external {
        creditAccountInfo[creditAccount].lastDebtUpdate = lastDebtUpdate;
    }

    function setDebt(address creditAccount, uint256 debt) external {
        creditAccountInfo[creditAccount].debt = debt;
    }

    function setCreditAccountInfoMap(
        address creditAccount,
        uint256 debt,
        uint256 cumulativeIndexLastUpdate,
        uint128 cumulativeQuotaInterest,
        uint128 quotaFees,
        uint256 enabledTokensMask,
        uint16 flags,
        address borrower
    ) external {
        creditAccountInfo[creditAccount].debt = debt;
        creditAccountInfo[creditAccount].cumulativeIndexLastUpdate = cumulativeIndexLastUpdate;
        creditAccountInfo[creditAccount].cumulativeQuotaInterest = cumulativeQuotaInterest;
        creditAccountInfo[creditAccount].quotaFees = quotaFees;
        creditAccountInfo[creditAccount].enabledTokensMask = enabledTokensMask;
        creditAccountInfo[creditAccount].flags = flags;
        creditAccountInfo[creditAccount].borrower = borrower;
    }

    function collateralTokenByMaskCalcLT(uint256 tokenMask, bool calcLT)
        external
        view
        returns (address token, uint16 liquidationThreshold)
    {
        return _collateralTokenByMask(tokenMask, calcLT);
    }

    /// @dev Calculates collateral and debt parameters
    function calcDebtAndCollateralFC(address creditAccount, CollateralCalcTask task)
        external
        view
        returns (CollateralDebtData memory collateralDebtData)
    {
        uint256[] memory collateralHints;

        collateralDebtData = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMaskOf(creditAccount),
            collateralHints: collateralHints,
            minHealthFactor: PERCENTAGE_FACTOR,
            task: task,
            useSafePrices: false
        });
    }

    function saveEnabledTokensMask(address creditAccount, uint256 enabledTokensMask) external {
        _saveEnabledTokensMask(creditAccount, enabledTokensMask);
    }

    function getQuotedTokensData(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256[] memory collateralHints,
        address _poolQuotaKeeper
    )
        external
        view
        returns (
            address[] memory quotaTokens,
            uint256 outstandingQuotaInterest,
            uint256[] memory quotas,
            uint256 quotedMask
        )
    {
        return _getQuotedTokensData(creditAccount, enabledTokensMask, collateralHints, _poolQuotaKeeper);
    }

    function getCollateralTokensData(uint256 tokenMask) external view returns (CollateralTokenData memory) {
        return collateralTokensData[tokenMask];
    }

    function setCollateralTokensCount(uint8 _collateralTokensCount) external {
        collateralTokensCount = _collateralTokensCount;
    }

    function _amountWithFee(uint256 amount) internal view override returns (uint256) {
        return _enableTransferFee ? _amountUSDTWithFee(amount) : amount;
    }

    function _amountMinusFee(uint256 amount) internal view override returns (uint256) {
        return _enableTransferFee ? _amountUSDTMinusFee(amount) : amount;
    }
}
