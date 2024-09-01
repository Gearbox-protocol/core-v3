// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../../../interfaces/ICreditFacadeV3.sol";
import {CreditFacadeV3} from "../../../credit/CreditFacadeV3.sol";
import {ManageDebtAction, CollateralDebtData} from "../../../interfaces/ICreditManagerV3.sol";
import {BalanceWithMask} from "../../../libraries/BalancesLogic.sol";

contract CreditFacadeV3Harness is CreditFacadeV3 {
    constructor(address _creditManager, address _botList, address _weth, address _degenNFT, bool _expirable)
        CreditFacadeV3(_creditManager, _botList, _weth, _degenNFT, _expirable)
    {}

    function setReentrancy(uint8 _status) external {
        _reentrancyStatus = _status;
    }

    function multicallInt(address creditAccount, MultiCall[] calldata calls, uint256 enabledTokensMask, uint256 flags)
        external
    {
        _multicall(creditAccount, calls, enabledTokensMask, flags);
    }

    function revertIfNoPermission(uint256 flags, uint256 permission) external pure {
        _revertIfNoPermission(flags, permission);
    }

    function revertIfOutOfDebtPerBlockLimit(uint256 amount) external {
        _revertIfOutOfDebtPerBlockLimit(amount);
    }

    function revertIfNotLiquidatable(address creditAccount) external view returns (CollateralDebtData memory, bool) {
        return _revertIfNotLiquidatable(creditAccount);
    }

    function calcPartialLiquidationPayments(uint256 amount, address token, address priceOracle, bool isExpired)
        external
        view
        returns (uint256, uint256, uint256)
    {
        return _calcPartialLiquidationPayments(amount, token, priceOracle, isExpired);
    }

    function setLastBlockBorrowed(uint64 _lastBlockBorrowed) external {
        lastBlockBorrowed = _lastBlockBorrowed;
    }

    function setTotalBorrowedInBlock(uint128 _totalBorrowedInBlock) external {
        totalBorrowedInBlock = _totalBorrowedInBlock;
    }

    function lastBlockBorrowedInt() external view returns (uint64) {
        return lastBlockBorrowed;
    }

    function totalBorrowedInBlockInt() external view returns (uint128) {
        return totalBorrowedInBlock;
    }

    function revertIfOutOfDebtLimits(uint256 debt, ManageDebtAction action) external view {
        _revertIfOutOfDebtLimits(debt, action);
    }

    function isExpiredInt() external view returns (bool) {
        return _isExpired();
    }
}
