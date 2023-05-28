// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

import {WETHGateway} from "../../../support/WETHGateway.sol";

/// @title WETH gateway unit test
/// @notice U:[WG]: Unit tests for WETH gateway
contract WETHGatewayUnitTest is Test {
    function test_U_WG_01A_constructor_reverts_on_zero_address() public {}

    function test_U_WG_01B_constructor_sets_correct_values() public {}

    function test_U_WG_02_receive_works_correctly() public {}

    function test_U_WG_03A_deposit_reverts_if_called_not_by_credit_manager() public {}

    function test_U_WG_03B_deposit_works_correctly() public {}

    function test_U_WG_04A_claim_is_non_reentrant() public {}

    function test_U_WG_04B_claim_works_correctly() public {}
}
