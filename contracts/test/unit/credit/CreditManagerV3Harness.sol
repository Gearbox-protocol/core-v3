// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.23;

import {CreditManagerV3, CreditAccountInfo} from "../../../credit/CreditManagerV3.sol";
import {USDTFees} from "../../../libraries/USDTFees.sol";
import {IUSDT} from "../../../interfaces/external/IUSDT.sol";

import {CollateralDebtData, CollateralCalcTask, CollateralTokenData} from "../../../interfaces/ICreditManagerV3.sol";
import {IPoolV3} from "../../../interfaces/IPoolV3.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {PERCENTAGE_FACTOR} from "../../../libraries/Constants.sol";

contract CreditManagerV3Harness is CreditManagerV3 {
    using USDTFees for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    bool _enableTransferFee;

    constructor(
        address _pool,
        address _accountFactory,
        address _priceOracle,
        uint8 _maxEnabledTokens,
        uint16 _feeInterest,
        string memory _name,
        bool enableTransferFee
    ) CreditManagerV3(_pool, _accountFactory, _priceOracle, _maxEnabledTokens, _feeInterest, _name) {
        _enableTransferFee = enableTransferFee;
    }

    function setReentrancy(uint8 _status) external {
        _reentrancyStatus = _status;
    }

    function setDebt(address creditAccount, CreditAccountInfo memory info) external {
        _creditAccountInfo[creditAccount] = info;
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
        _creditAccountInfo[creditAccount].borrower = borrower;
    }

    function setLastDebtUpdate(address creditAccount, uint64 lastDebtUpdate) external {
        _creditAccountInfo[creditAccount].lastDebtUpdate = lastDebtUpdate;
    }

    function setDebt(address creditAccount, uint256 debt) external {
        _creditAccountInfo[creditAccount].debt = debt;
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
        _creditAccountInfo[creditAccount].debt = debt;
        _creditAccountInfo[creditAccount].cumulativeIndexLastUpdate = cumulativeIndexLastUpdate;
        _creditAccountInfo[creditAccount].cumulativeQuotaInterest = cumulativeQuotaInterest;
        _creditAccountInfo[creditAccount].quotaFees = quotaFees;
        _creditAccountInfo[creditAccount].enabledTokensMask = enabledTokensMask;
        _creditAccountInfo[creditAccount].flags = flags;
        _creditAccountInfo[creditAccount].borrower = borrower;
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

    function getQuotedTokensData(address creditAccount, uint256 enabledTokensMask, uint256[] memory collateralHints)
        external
        view
        returns (address[] memory quotaTokens, uint256 outstandingQuotaInterest, uint256[] memory quotas)
    {
        return _getQuotedTokensData(creditAccount, enabledTokensMask, collateralHints);
    }

    function getCollateralTokensData(uint256 tokenMask) external view returns (CollateralTokenData memory) {
        return collateralTokensData[tokenMask];
    }

    function setCollateralTokensCount(uint8 _collateralTokensCount) external {
        collateralTokensCount = _collateralTokensCount;
    }

    function _amountWithFee(uint256 amount) internal view override returns (uint256) {
        if (!_enableTransferFee) return amount;
        uint256 basisPointsRate = IUSDT(underlying).basisPointsRate();
        if (basisPointsRate == 0) return amount;
        return amount.amountUSDTWithFee({basisPointsRate: basisPointsRate, maximumFee: IUSDT(underlying).maximumFee()});
    }

    function _amountMinusFee(uint256 amount) internal view override returns (uint256) {
        if (!_enableTransferFee) return amount;
        uint256 basisPointsRate = IUSDT(underlying).basisPointsRate();
        if (basisPointsRate == 0) return amount;
        return amount.amountUSDTMinusFee({basisPointsRate: basisPointsRate, maximumFee: IUSDT(underlying).maximumFee()});
    }
}
