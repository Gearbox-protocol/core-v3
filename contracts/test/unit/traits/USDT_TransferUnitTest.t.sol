// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {USDT_Transfer} from "../../../traits/USDT_Transfer.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TestHelper} from "../../lib/helper.sol";

contract USDT_TransferUnitTest is USDT_Transfer, TestHelper {
    using Math for uint256;

    uint256 public basisPointsRate;

    uint256 public maximumFee;

    constructor() USDT_Transfer(address(this)) {}

    /// @dev U:[UTT_01]: amountUSDTWithFee computes value correctly [fuzzing]
    function test_U_UTT_01_fuzzing_amountUSDTWithFee_computes_value_correctly(uint256 amount, uint8 fee, uint256 maxFee)
        public
    {
        uint256 decimals = 6;
        uint256 tenBillionsUSDT = 10 ** 10 * (10 ** decimals);
        uint256 oneCent = (10 ** decimals) / 100;
        vm.assume(amount < tenBillionsUSDT);
        vm.assume(fee < 100_00); // fee could not be more than 100%
        vm.assume(maxFee < 100 * (10 ** decimals)); // we assume that transfer will cost could not exceed $100

        basisPointsRate = fee;
        maximumFee = maxFee;

        uint256 value = _amountUSDTMinusFee(_amountUSDTWithFee(amount));
        uint256 diff = Math.max(amount, value) - Math.min(amount, value);
        assertTrue(diff < oneCent, "Incorrect computation");
    }
}
