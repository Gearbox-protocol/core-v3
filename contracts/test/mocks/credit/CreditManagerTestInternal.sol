// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CreditManagerV3, ClosureAction} from "../../../credit/CreditManagerV3.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import {IPoolQuotaKeeper} from "../../../interfaces/IPoolQuotaKeeper.sol";
import {CollateralTokenData} from "../../../interfaces/ICreditManagerV3.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

/// @title Credit Manager Internal
/// @notice It encapsulates business logic for managing credit accounts
///
/// More info: https://dev.gearbox.fi/developers/credit/credit_manager
contract CreditManagerTestInternal is CreditManagerV3 {
    using SafeERC20 for IERC20;
    using Address for address payable;

    /// @dev Constructor
    /// @param _poolService Address of pool service
    constructor(address _poolService, address _withdrawalManager) CreditManagerV3(_poolService, _withdrawalManager) {}

    function setCumulativeDropAtFastCheck(address creditAccount, uint16 value) external {
        // cumulativeDropAtFastCheckRAY[creditAccount] = value;
    }

    // function calcNewCumulativeIndex(
    //     uint256 borrowedAmount,
    //     uint256 delta,
    //     uint256 cumulativeIndexNow,
    //     uint256 cumulativeIndexOpen,
    //     bool isIncrease
    // ) external pure returns (uint256 newCumulativeIndex) {
    //     newCumulativeIndex =
    //         _calcNewCumulativeIndex(borrowedAmount, delta, cumulativeIndexNow, cumulativeIndexOpen, isIncrease);
    // }

    // function calcClosePaymentsPure(
    //     uint256 totalValue,
    //     ClosureAction closureActionType,
    //     uint256 borrowedAmount,
    //     uint256 borrowedAmountWithInterest
    // ) external view returns (uint256 amountToPool, uint256 remainingFunds, uint256 profit, uint256 loss) {
    //     return calcClosePayments(totalValue, closureActionType, borrowedAmount, borrowedAmountWithInterest);
    // }

    function transferAssetsTo(address creditAccount, address to, bool convertWETH, uint256 enabledTokensMask)
        external
    {
        _transferAssetsTo(creditAccount, to, convertWETH, enabledTokensMask);
    }

    function safeTokenTransfer(address creditAccount, address token, address to, uint256 amount, bool convertToETH)
        external
    {
        _safeTokenTransfer(creditAccount, token, to, amount, convertToETH);
    }

    // function disableToken(address creditAccount, address token) external override {
    //     _disableToken(creditAccount, token);
    // }

    // function getCreditAccountParameters(address creditAccount)
    //     external
    //     view
    //     returns (uint256 borrowedAmount, uint256 cumulativeIndexLastUpdate, uint256 cumulativeIndexNow)
    // {
    //     return _getCreditAccountParameters(creditAccount);
    // }

    function collateralTokensInternal() external view returns (address[] memory collateralTokensAddr) {
        uint256 len = collateralTokensCount;
        collateralTokensAddr = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            (collateralTokensAddr[i],) = collateralTokens(i);
        }
    }

    function collateralTokensDataExt(uint256 tokenMask) external view returns (CollateralTokenData memory) {
        return collateralTokensData[tokenMask];
    }

    function setenabledTokensMask(address creditAccount, uint256 enabledTokensMask) external {
        creditAccountInfo[creditAccount].enabledTokensMask = enabledTokensMask;
    }

    function getSlotBytes(uint256 slotNum) external view returns (bytes32 slotVal) {
        assembly {
            slotVal := sload(slotNum)
        }
    }
}
