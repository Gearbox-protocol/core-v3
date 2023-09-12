// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {USDT_Transfer} from "../../../traits/USDT_Transfer.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TestHelper} from "../../lib/helper.sol";
import "forge-std/console.sol";

contract USDT_TransferUnitTest is USDT_Transfer, TestHelper {
    using Math for uint256;

    uint256 public basisPointsRate;

    uint256 public maximumFee;

    constructor() USDT_Transfer(address(this)) {}

    /// @dev U:[UTT_01]: amountUSDTWithFee computes value correctly [fuzzing]
    /// forge-config: default.fuzz.runs = 200000
    function test_U_UTT_01_fuzzing_amountUSDTWithFee_computes_value_correctly(
        uint256 amount,
        uint16 fee,
        uint256 maxFee
    ) public {
        uint256 decimals = 6;
        uint256 tenBillionsUSDT = 10 ** 10 * (10 ** decimals);

        amount = amount % tenBillionsUSDT;
        fee = fee % 100_00;
        maxFee = maxFee % (100 * (10 ** decimals));

        basisPointsRate = fee;
        maximumFee = maxFee;

        uint256 value = _amountUSDTMinusFee(_amountUSDTWithFee(amount));

        assertEq(value, amount, "Incorrect fee");
    }

    /// @dev U:[UTT_02]: amountUSDTWithFee without maxFee [fuzzing]
    /// forge-config: default.fuzz.runs = 200000
    function test_U_UTT_02_fuzzing_amountUSDTWithFee_computes_value_correctly_without_max_fee(
        uint256 amount,
        uint16 fee
    ) public {
        uint256 decimals = 6;
        uint256 tenBillionsUSDT = 10 ** 10 * (10 ** decimals);

        amount = amount % tenBillionsUSDT;
        fee = fee % 100_00;

        basisPointsRate = fee;
        maximumFee = amount;

        uint256 value = _amountUSDTMinusFee(_amountUSDTWithFee(amount));

        assertEq(value, amount, "Incorrect fee");
    }
}
