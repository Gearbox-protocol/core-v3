// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {USDT_Transfer} from "../../../traits/USDT_Transfer.sol";
import {TestHelper} from "../../lib/helper.sol";

contract USDT_TransferUnitTest is USDT_Transfer, TestHelper {
    uint256 constant SCALE = 10 ** 18;

    uint256 public basisPointsRate;
    uint256 public maximumFee;

    constructor() USDT_Transfer(address(this)) {}

    /// @notice U:[UTT-1]: `amountUSDTWithFee` and `amountUSDTMinusFee` work correctly
    /// forge-config: default.fuzz.runs = 50000
    function testFuzz_U_UTT_01_amountUSDTWithFee_amountUSDTMinusFee_work_correctly(
        uint256 amount,
        uint256 feeRate,
        uint256 maxFee
    ) public {
        amount = bound(amount, 0, 10 ** 10) * SCALE; // up to 10B USDT
        basisPointsRate = bound(feeRate, 0, 100); // up to 1%
        maximumFee = bound(maxFee, 0, 1000) * SCALE; // up to 1000 USDT

        // direction checks
        assertGe(_amountUSDTWithFee(amount), amount, "amountWithFee less than amount");
        assertLe(_amountUSDTMinusFee(amount), amount, "amountMinusFee greater than amount");

        // maximum fee checks
        assertLe(_amountUSDTWithFee(amount), amount + maximumFee, "amountWithFee fee greater than maximum");
        assertGe(_amountUSDTMinusFee(amount) + maximumFee, amount, "amountMinusFee fee greater than maximum");

        // inversion checks
        assertEq(_amountUSDTMinusFee(_amountUSDTWithFee(amount)), amount, "amountMinusFee not inverse of amountWithFee");
        assertEq(_amountUSDTWithFee(_amountUSDTMinusFee(amount)), amount, "amountWithFee not inverse of amountMinusFee");
    }
}
