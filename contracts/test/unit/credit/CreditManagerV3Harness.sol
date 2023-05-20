pragma solidity ^0.8.17;

import {CreditManagerV3, CreditAccountInfo} from "../../../credit/CreditManagerV3.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import {CollateralDebtData, CollateralCalcTask} from "../../../interfaces/ICreditManagerV3.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

contract CreditManagerV3Harness is CreditManagerV3 {
    using EnumerableSet for EnumerableSet.AddressSet;

    constructor(address _addressProvider, address _pool) CreditManagerV3(_addressProvider, _pool) {}

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

    function setDebt(address creditAccount, uint256 debt) external {
        creditAccountInfo[creditAccount].debt = debt;
    }

    function setCreditAccountInfoMap(
        address creditAccount,
        uint256 debt,
        uint256 cumulativeIndexLastUpdate,
        uint256 cumulativeQuotaInterest,
        uint256 enabledTokensMask,
        uint16 flags,
        address borrower
    ) external {
        creditAccountInfo[creditAccount].debt = debt;
        creditAccountInfo[creditAccount].cumulativeIndexLastUpdate = cumulativeIndexLastUpdate;
        creditAccountInfo[creditAccount].cumulativeQuotaInterest = cumulativeQuotaInterest;
        creditAccountInfo[creditAccount].enabledTokensMask = enabledTokensMask;
        creditAccountInfo[creditAccount].flags = flags;
        creditAccountInfo[creditAccount].borrower = borrower;
    }

    function batchTokensTransfer(address creditAccount, address to, bool convertToETH, uint256 enabledTokensMask)
        external
    {
        _batchTokensTransfer(creditAccount, to, convertToETH, enabledTokensMask);
    }

    function safeTokenTransfer(address creditAccount, address token, address to, uint256 amount, bool convertToETH)
        external
    {
        _safeTokenTransfer(creditAccount, token, to, amount, convertToETH);
    }

    function checkEnabledTokenLength(uint256 enabledTokensMask) external view {
        _checkEnabledTokenLength(enabledTokensMask);
    }

    function collateralTokensByMaskCalcLT(uint256 tokenMask, bool calcLT)
        external
        view
        returns (address token, uint16 liquidationThreshold)
    {
        return _collateralTokensByMask(tokenMask, calcLT);
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
            task: task
        });
    }

    function hasWithdrawals(address creditAccount) external view returns (bool) {
        return _hasWithdrawals(creditAccount);
    }

    function saveEnabledTokensMask(address creditAccount, uint256 enabledTokensMask) external {
        _saveEnabledTokensMask(creditAccount, enabledTokensMask);
    }

    function getQuotedTokensData(address creditAccount, uint256 enabledTokensMask, address _poolQuotaKeeper)
        external
        view
        returns (
            address[] memory quotaTokens,
            uint256 outstandingQuotaInterest,
            uint256[] memory quotas,
            uint16[] memory lts,
            uint256 quotedMask
        )
    {
        return _getQuotedTokensData(creditAccount, enabledTokensMask, _poolQuotaKeeper);
    }
}
