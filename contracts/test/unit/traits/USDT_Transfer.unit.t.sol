// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.23;

import {IncorrectTokenContractException, ZeroAddressException} from "../../../interfaces/IExceptions.sol";
import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";
import {TestHelper} from "../../lib/helper.sol";
import {USDT_TransferHarness} from "./USDT_TransferHarness.sol";

contract USDT_TransferUnitTest is TestHelper {
    uint256 constant SCALE = 10 ** 18;

    uint256 public basisPointsRate;
    uint256 public maximumFee;

    USDT_TransferHarness trait;

    function setUp() public {
        trait = new USDT_TransferHarness(address(this));
    }

    /// @notice U:[UTT-1]: Constructor works as expected
    function test_U_UTT_01_constructor_works_as_expected() public {
        vm.expectRevert(ZeroAddressException.selector);
        new USDT_TransferHarness(address(0));

        ERC20Mock token = new ERC20Mock("Test Token", "TEST", 18);
        vm.expectRevert(IncorrectTokenContractException.selector);
        new USDT_TransferHarness(address(token));
    }

    /// @notice U:[UTT-2]: `amountUSDTWithFee` and `amountUSDTMinusFee` work correctly
    /// forge-config: default.fuzz.runs = 50000
    function testFuzz_U_UTT_02_amountUSDTWithFee_amountUSDTMinusFee_work_correctly(
        uint256 amount,
        uint256 feeRate,
        uint256 maxFee
    ) public {
        amount = bound(amount, 0, 10 ** 10) * SCALE; // up to 10B USDT
        basisPointsRate = bound(feeRate, 0, 100); // up to 1%
        maximumFee = bound(maxFee, 0, 1000) * SCALE; // up to 1000 USDT

        // direction checks
        assertGe(trait.amountUSDTWithFee(amount), amount, "amountWithFee less than amount");
        assertLe(trait.amountUSDTMinusFee(amount), amount, "amountMinusFee greater than amount");

        // maximum fee checks
        assertLe(trait.amountUSDTWithFee(amount), amount + maximumFee, "amountWithFee fee greater than maximum");
        assertGe(trait.amountUSDTMinusFee(amount) + maximumFee, amount, "amountMinusFee fee greater than maximum");

        // inversion checks
        assertEq(
            trait.amountUSDTMinusFee(trait.amountUSDTWithFee(amount)),
            amount,
            "amountMinusFee not inverse of amountWithFee"
        );
        assertEq(
            trait.amountUSDTWithFee(trait.amountUSDTMinusFee(amount)),
            amount,
            "amountWithFee not inverse of amountMinusFee"
        );
    }
}
