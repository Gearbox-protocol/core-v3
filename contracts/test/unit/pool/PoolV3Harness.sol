// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {PoolV3} from "../../../pool/PoolV3.sol";
import {ENTERED, NOT_ENTERED} from "../../../traits/ReentrancyGuardTrait.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

contract PoolV3Harness is PoolV3 {
    uint16 _transferFee;

    constructor(
        address addressProvider_,
        address underlyingToken_,
        address interestRateModel_,
        uint256 totalDebtLimit_,
        string memory name_,
        string memory symbol_
    ) PoolV3(addressProvider_, underlyingToken_, interestRateModel_, totalDebtLimit_, name_, symbol_) {}

    // ------- //
    // GENERAL //
    // ------- //

    function hackReentrancyStatus(bool entered) external {
        _reentrancyStatus = entered ? ENTERED : NOT_ENTERED;
    }

    function hackExpectedLiquidityLU(uint256 value) external {
        _expectedLiquidityLU = uint128(value);
    }

    // --------- //
    // BORROWING //
    // --------- //

    function hackTotalBorrowed(uint256 value) external {
        _totalDebt.borrowed = uint128(value);
    }

    function hackCreditManagerBorrowed(address creditManager, uint256 value) external {
        _creditManagerDebt[creditManager].borrowed = uint128(value);
    }

    // ------------- //
    // INTEREST RATE //
    // ------------- //

    function hackBaseInterestRate(uint256 value) external {
        _baseInterestRate = uint128(value);
        lastBaseInterestUpdate = uint40(block.timestamp);
    }

    function hackBaseInterestIndexLU(uint256 value) external {
        _baseInterestIndexLU = uint128(value);
    }

    function calcBaseInterestAccrued() external view returns (uint256) {
        return _calcBaseInterestAccrued();
    }

    function updateBaseInterest(
        int256 expectedLiquidityDelta,
        int256 availableLiquidityDelta,
        bool checkOptimalBorrowing
    ) external {
        _updateBaseInterest(expectedLiquidityDelta, availableLiquidityDelta, checkOptimalBorrowing);
    }

    // ------ //
    // QUOTAS //
    // ------ //

    function hackQuotaRevenue(uint256 value) external {
        _quotaRevenue = uint96(value);
        lastQuotaRevenueUpdate = uint40(block.timestamp);
    }

    function calcQuotaRevenueAccrued() external view returns (uint256) {
        return _calcQuotaRevenueAccrued();
    }

    // ------------- //
    // TRANSFER FEES //
    // ------------- //

    function hackTransferFee(uint256 value) external {
        _transferFee = uint16(value);
    }

    function _amountWithFee(uint256 amount) internal view override returns (uint256) {
        return amount * PERCENTAGE_FACTOR / (PERCENTAGE_FACTOR - _transferFee);
    }

    function _amountMinusFee(uint256 amount) internal view override returns (uint256) {
        return amount * (PERCENTAGE_FACTOR - _transferFee) / PERCENTAGE_FACTOR;
    }
}
