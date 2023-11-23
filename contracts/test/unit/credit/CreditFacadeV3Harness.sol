// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../../../interfaces/ICreditFacadeV3.sol";
import {CreditFacadeV3} from "../../../credit/CreditFacadeV3.sol";
import {ManageDebtAction} from "../../../interfaces/ICreditManagerV3.sol";
import {BalanceWithMask} from "../../../libraries/BalancesLogic.sol";

contract CreditFacadeV3Harness is CreditFacadeV3 {
    constructor(address _creditManager, address _degenNFT, bool _expirable)
        CreditFacadeV3(_creditManager, _degenNFT, _expirable)
    {}

    function setReentrancy(uint8 _status) external {
        _reentrancyStatus = _status;
    }

    function setCumulativeLoss(uint128 newLoss) external {
        lossParams.currentCumulativeLoss = newLoss;
    }

    function multicallInt(address creditAccount, MultiCall[] calldata calls, uint256 enabledTokensMask, uint256 flags)
        external
        returns (FullCheckParams memory fullCheckParams)
    {
        return _multicall(creditAccount, calls, enabledTokensMask, flags, 0);
    }

    function applyPriceOnDemandInt(MultiCall[] calldata calls) external returns (uint256 remainingCalls) {
        return _applyOnDemandPriceUpdates(calls);
    }

    function fullCollateralCheckInt(
        address creditAccount,
        uint256 enabledTokensMaskBefore,
        FullCheckParams memory fullCheckParams,
        BalanceWithMask[] memory forbiddenBalances,
        uint256 forbiddenTokensMask
    ) external {
        _fullCollateralCheck(
            creditAccount, enabledTokensMaskBefore, fullCheckParams, forbiddenBalances, forbiddenTokensMask
        );
    }

    function revertIfNoPermission(uint256 flags, uint256 permission) external pure {
        _revertIfNoPermission(flags, permission);
    }

    function revertIfOutOfBorrowingLimit(uint256 amount) external {
        _revertIfOutOfBorrowingLimit(amount);
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

    function revertIfOutOfDebtLimits(uint256 debt) external view {
        _revertIfOutOfDebtLimits(debt);
    }

    function isExpired() external view returns (bool) {
        return _isExpired();
    }

    function setCurrentCumulativeLoss(uint128 _currentCumulativeLoss) external {
        lossParams.currentCumulativeLoss = _currentCumulativeLoss;
    }
}
