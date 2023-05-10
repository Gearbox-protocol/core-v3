// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IncorrectParameterException} from "../../../interfaces/IExceptions.sol";
import {CreditAccountHelper} from "../../../libraries/CreditAccountHelper.sol";
import {ICreditAccount} from "../../../interfaces/ICreditAccount.sol";

import {CreditAccount} from "../../../core/CreditAccount.sol";

import {TestHelper} from "../../lib/helper.sol";
import "forge-std/console.sol";

/// @title CreditAccountHelper logic test
/// @notice [CAH]: Unit tests for credit account helper
contract CreditAccountHelperTest is TestHelper {
    /// @notice U:[CL-1]: `calcIndex` reverts for zero value
    function test_CL_01_calcIndex_reverts_for_zero_value() public {}
}
