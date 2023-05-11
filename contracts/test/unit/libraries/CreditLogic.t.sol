// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IncorrectParameterException} from "../../../interfaces/IExceptions.sol";
import {CreditLogic} from "../../../libraries/CreditLogic.sol";

import {TestHelper} from "../../lib/helper.sol";
import "forge-std/console.sol";

/// @title BitMask logic test
/// @notice [BM]: Unit tests for bit mask library
contract CreditLogicTest is TestHelper {
    /// @notice U:[CL-1]: `calcIndex` reverts for zero value
    function test_CL_01_calcIndex_reverts_for_zero_value() public {}
}
