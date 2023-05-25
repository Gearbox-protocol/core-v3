// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {PolicyManager, Policy} from "../../../support/risk-controller/PolicyManager.sol";
import {PolicyManagerInternal} from "../../mocks/support/PolicyManagerInternal.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// TEST
import "../../lib/constants.sol";

// MOCKS
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {Test} from "forge-std/Test.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

contract PolicyManagerTest is Test {
    AddressProviderV3ACLMock public addressProvider;

    PolicyManagerInternal public policyManager;

    function setUp() public {
        vm.prank(CONFIGURATOR);
        addressProvider = new AddressProviderV3ACLMock();

        policyManager = new PolicyManagerInternal(address(addressProvider));
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev [PM-1]: setPolicy and getPolicy work correctly
    function test_PM_01_setPolicy_getPolicy_setGroup_getGroup_work_correctly() public {
        Policy memory policy = Policy({
            enabled: false,
            flags: 2 + 4 + 16,
            exactValue: 15,
            minValue: 10,
            maxValue: 20,
            referencePoint: 0,
            referencePointUpdatePeriod: 1 days,
            referencePointTimestampLU: 0,
            minPctChange: 1,
            maxPctChange: 2,
            minChange: 3,
            maxChange: 4
        });

        vm.expectRevert(CallerNotConfiguratorException.selector);
        vm.prank(USER);
        policyManager.setPolicy(bytes32(uint256(1)), policy);

        vm.prank(CONFIGURATOR);
        policyManager.setPolicy(bytes32(uint256(1)), policy);

        Policy memory policy2 = policyManager.getPolicy(bytes32(uint256(1)));

        assertTrue(policy2.enabled, "Enabled not set by setPolicy");

        assertEq(policy2.flags, 22, "Flags are incorrect");

        assertEq(policy2.exactValue, 15, "exactValue is incorrect");

        assertEq(policy2.minValue, 10, "minValue is incorrect");

        assertEq(policy2.maxValue, 20, "maxValue is incorrect");

        assertEq(policy2.referencePoint, 0, "referencePoint is incorrect");

        assertEq(policy2.referencePointUpdatePeriod, 1 days, "referencePointUpdatePeriod is incorrect");

        assertEq(policy2.referencePointTimestampLU, 0, "referencePointTimestampLU is incorrect");

        assertEq(policy2.minPctChange, 1, "minPctChange is incorrect");

        assertEq(policy2.maxPctChange, 2, "maxPctChange is incorrect");

        assertEq(policy2.minChange, 3, "minChange is incorrect");

        assertEq(policy2.maxChange, 4, "maxChange is incorrect");

        vm.expectRevert(CallerNotConfiguratorException.selector);
        vm.prank(USER);
        policyManager.setGroup(DUMB_ADDRESS, "GROUP");

        vm.prank(CONFIGURATOR);
        policyManager.setGroup(DUMB_ADDRESS, "GROUP");

        assertEq(policyManager.getGroup(DUMB_ADDRESS), "GROUP");
    }

    /// @dev [PM-2]: checkPolicy fails on disabled policy
    function test_PM_02_checkPolicy_false_on_disabled() public {
        Policy memory policy = Policy({
            enabled: false,
            flags: 2 + 4 + 16,
            exactValue: 15,
            minValue: 10,
            maxValue: 20,
            referencePoint: 0,
            referencePointUpdatePeriod: 1 days,
            referencePointTimestampLU: 0,
            minPctChange: 1,
            maxPctChange: 2,
            minChange: 3,
            maxChange: 4
        });

        vm.prank(CONFIGURATOR);
        policyManager.setPolicy(bytes32(uint256(1)), policy);

        vm.prank(CONFIGURATOR);
        policyManager.disablePolicy(bytes32(uint256(1)));

        assertTrue(!policyManager.checkPolicy(bytes32(uint256(1)), 0, 1));
    }

    /// @dev [PM-3]: checkPolicy exactValue works correctly
    function test_PM_03_checkPolicy_exactValue_works_correctly(uint256 newValue) public {
        Policy memory policy = Policy({
            enabled: false,
            flags: 1,
            exactValue: 15,
            minValue: 0,
            maxValue: 0,
            referencePoint: 0,
            referencePointUpdatePeriod: 0,
            referencePointTimestampLU: 0,
            minPctChange: 0,
            maxPctChange: 0,
            minChange: 0,
            maxChange: 0
        });

        vm.prank(CONFIGURATOR);
        policyManager.setPolicy(bytes32(uint256(1)), policy);

        assertTrue(newValue == 15 || !policyManager.checkPolicy(bytes32(uint256(1)), 0, newValue));
    }

    /// @dev [PM-4]: checkPolicy minValue works correctly
    function test_PM_04_checkPolicy_minValue_works_correctly(uint256 minValue, uint256 newValue) public {
        Policy memory policy = Policy({
            enabled: false,
            flags: 2,
            exactValue: 0,
            minValue: minValue,
            maxValue: 0,
            referencePoint: 0,
            referencePointUpdatePeriod: 0,
            referencePointTimestampLU: 0,
            minPctChange: 0,
            maxPctChange: 0,
            minChange: 0,
            maxChange: 0
        });

        vm.prank(CONFIGURATOR);
        policyManager.setPolicy(bytes32(uint256(1)), policy);

        assertTrue(newValue >= minValue || !policyManager.checkPolicy(bytes32(uint256(1)), 0, newValue));
    }

    /// @dev [PM-5]: checkPolicy maxValue works correctly
    function test_PM_05_checkPolicy_maxValue_works_correctly(uint256 maxValue, uint256 newValue) public {
        Policy memory policy = Policy({
            enabled: false,
            flags: 4,
            exactValue: 0,
            minValue: 0,
            maxValue: maxValue,
            referencePoint: 0,
            referencePointUpdatePeriod: 0,
            referencePointTimestampLU: 0,
            minPctChange: 0,
            maxPctChange: 0,
            minChange: 0,
            maxChange: 0
        });

        vm.prank(CONFIGURATOR);
        policyManager.setPolicy(bytes32(uint256(1)), policy);

        assertTrue(newValue <= maxValue || !policyManager.checkPolicy(bytes32(uint256(1)), 0, newValue));
    }

    /// @dev [PM-6]: checkPolicy correctly sets reference point and timestampLU
    function test_PM_06_checkPolicy_correctly_sets_reference_point() public {
        Policy memory policy = Policy({
            enabled: false,
            flags: 8,
            exactValue: 0,
            minValue: 0,
            maxValue: 0,
            referencePoint: 0,
            referencePointUpdatePeriod: 1 days,
            referencePointTimestampLU: 0,
            minPctChange: 0,
            maxPctChange: 0,
            minChange: 0,
            maxChange: 0
        });

        vm.prank(CONFIGURATOR);
        policyManager.setPolicy(bytes32(uint256(1)), policy);

        policyManager.checkPolicy(bytes32(uint256(1)), 20, 20);

        Policy memory policy2 = policyManager.getPolicy(bytes32(uint256(1)));

        assertEq(policy2.referencePoint, 20, "Incorrect reference point");

        assertEq(policy2.referencePointTimestampLU, block.timestamp, "Incorrect timestamp LU");
    }

    /// @dev [PM-7]: checkPolicy minChange works correctly
    function test_PM_07_checkPolicy_minChange_works_correctly(
        uint256 oldValue,
        uint256 newValue1,
        uint256 newValue2,
        uint256 newValue3,
        uint256 minChange
    ) public {
        Policy memory policy = Policy({
            enabled: false,
            flags: 8,
            exactValue: 0,
            minValue: 0,
            maxValue: 0,
            referencePoint: 0,
            referencePointUpdatePeriod: 1 days,
            referencePointTimestampLU: 0,
            minPctChange: 0,
            maxPctChange: 0,
            minChange: minChange,
            maxChange: 0
        });

        vm.prank(CONFIGURATOR);
        policyManager.setPolicy(bytes32(uint256(1)), policy);

        uint256 diff = newValue1 > oldValue ? newValue1 - oldValue : oldValue - newValue1;

        assertTrue(!policyManager.checkPolicy(bytes32(uint256(1)), oldValue, newValue1) || diff >= minChange);

        vm.warp(block.timestamp + 1);

        diff = newValue2 > oldValue ? newValue2 - oldValue : oldValue - newValue2;

        assertTrue(!policyManager.checkPolicy(bytes32(uint256(1)), newValue1, newValue2) || diff >= minChange);

        vm.warp(block.timestamp + 1 days);

        diff = newValue3 > newValue2 ? newValue3 - newValue2 : newValue2 - newValue3;

        assertTrue(!policyManager.checkPolicy(bytes32(uint256(1)), newValue2, newValue3) || diff >= minChange);

        Policy memory policy2 = policyManager.getPolicy(bytes32(uint256(1)));

        assertEq(policy2.referencePoint, newValue2, "Incorrect reference point");

        assertEq(policy2.referencePointTimestampLU, block.timestamp, "Incorrect timestamp LU");
    }

    /// @dev [PM-8]: checkPolicy maxChange works correctly
    function test_PM_08_checkPolicy_maxChange_works_correctly(
        uint256 oldValue,
        uint256 newValue1,
        uint256 newValue2,
        uint256 newValue3,
        uint256 maxChange
    ) public {
        Policy memory policy = Policy({
            enabled: false,
            flags: 16,
            exactValue: 0,
            minValue: 0,
            maxValue: 0,
            referencePoint: 0,
            referencePointUpdatePeriod: 1 days,
            referencePointTimestampLU: 0,
            minPctChange: 0,
            maxPctChange: 0,
            minChange: 0,
            maxChange: maxChange
        });

        vm.prank(CONFIGURATOR);
        policyManager.setPolicy(bytes32(uint256(1)), policy);

        uint256 diff = newValue1 > oldValue ? newValue1 - oldValue : oldValue - newValue1;

        assertTrue(!policyManager.checkPolicy(bytes32(uint256(1)), oldValue, newValue1) || diff <= maxChange);

        vm.warp(block.timestamp + 1);

        diff = newValue2 > oldValue ? newValue2 - oldValue : oldValue - newValue2;

        assertTrue(!policyManager.checkPolicy(bytes32(uint256(1)), newValue1, newValue2) || diff <= maxChange);

        vm.warp(block.timestamp + 1 days);

        diff = newValue3 > newValue2 ? newValue3 - newValue2 : newValue2 - newValue3;

        assertTrue(!policyManager.checkPolicy(bytes32(uint256(1)), newValue2, newValue3) || diff <= maxChange);

        Policy memory policy2 = policyManager.getPolicy(bytes32(uint256(1)));

        assertEq(policy2.referencePoint, newValue2, "Incorrect reference point");

        assertEq(policy2.referencePointTimestampLU, block.timestamp, "Incorrect timestamp LU");
    }

    /// @dev [PM-9]: checkPolicy minPctChange works correctly
    function test_PM_09_checkPolicy_minPctChange_works_correctly(
        uint256 oldValue,
        uint256 newValue1,
        uint256 newValue2,
        uint256 newValue3,
        uint16 minPctChange
    ) public {
        vm.assume(oldValue > 0);
        vm.assume(newValue2 > 0);

        vm.assume(oldValue < type(uint128).max);
        vm.assume(newValue1 < type(uint128).max);
        vm.assume(newValue2 < type(uint128).max);
        vm.assume(newValue3 < type(uint128).max);

        Policy memory policy = Policy({
            enabled: false,
            flags: 32,
            exactValue: 0,
            minValue: 0,
            maxValue: 0,
            referencePoint: 0,
            referencePointUpdatePeriod: 1 days,
            referencePointTimestampLU: 0,
            minPctChange: minPctChange,
            maxPctChange: 0,
            minChange: 0,
            maxChange: 0
        });

        vm.prank(CONFIGURATOR);
        policyManager.setPolicy(bytes32(uint256(1)), policy);

        uint256 pctDiff =
            (newValue1 > oldValue ? newValue1 - oldValue : oldValue - newValue1) * PERCENTAGE_FACTOR / oldValue;

        assertTrue(!policyManager.checkPolicy(bytes32(uint256(1)), oldValue, newValue1) || pctDiff >= minPctChange);
        vm.warp(block.timestamp + 1);

        pctDiff = (newValue2 > oldValue ? newValue2 - oldValue : oldValue - newValue2) * PERCENTAGE_FACTOR / oldValue;

        assertTrue(!policyManager.checkPolicy(bytes32(uint256(1)), newValue1, newValue2) || pctDiff >= minPctChange);

        vm.warp(block.timestamp + 1 days);

        pctDiff =
            (newValue3 > newValue2 ? newValue3 - newValue2 : newValue2 - newValue3) * PERCENTAGE_FACTOR / newValue2;

        assertTrue(!policyManager.checkPolicy(bytes32(uint256(1)), newValue2, newValue3) || pctDiff >= minPctChange);

        Policy memory policy2 = policyManager.getPolicy(bytes32(uint256(1)));

        assertEq(policy2.referencePoint, newValue2, "Incorrect reference point");

        assertEq(policy2.referencePointTimestampLU, block.timestamp, "Incorrect timestamp LU");
    }

    /// @dev [PM-10]: checkPolicy maxPctChange works correctly
    function test_PM_10_checkPolicy_maxPctChange_works_correctly(
        uint256 oldValue,
        uint256 newValue1,
        uint256 newValue2,
        uint256 newValue3,
        uint16 maxPctChange
    ) public {
        vm.assume(oldValue > 0);
        vm.assume(newValue2 > 0);

        vm.assume(oldValue < type(uint128).max);
        vm.assume(newValue1 < type(uint128).max);
        vm.assume(newValue2 < type(uint128).max);
        vm.assume(newValue3 < type(uint128).max);

        Policy memory policy = Policy({
            enabled: false,
            flags: 64,
            exactValue: 0,
            minValue: 0,
            maxValue: 0,
            referencePoint: 0,
            referencePointUpdatePeriod: 1 days,
            referencePointTimestampLU: 0,
            minPctChange: 0,
            maxPctChange: maxPctChange,
            minChange: 0,
            maxChange: 0
        });

        vm.prank(CONFIGURATOR);
        policyManager.setPolicy(bytes32(uint256(1)), policy);

        uint256 pctDiff =
            (newValue1 > oldValue ? newValue1 - oldValue : oldValue - newValue1) * PERCENTAGE_FACTOR / oldValue;

        assertTrue(!policyManager.checkPolicy(bytes32(uint256(1)), oldValue, newValue1) || pctDiff <= maxPctChange);
        vm.warp(block.timestamp + 1);

        pctDiff = (newValue2 > oldValue ? newValue2 - oldValue : oldValue - newValue2) * PERCENTAGE_FACTOR / oldValue;

        assertTrue(!policyManager.checkPolicy(bytes32(uint256(1)), newValue1, newValue2) || pctDiff <= maxPctChange);

        vm.warp(block.timestamp + 1 days);

        pctDiff =
            (newValue3 > newValue2 ? newValue3 - newValue2 : newValue2 - newValue3) * PERCENTAGE_FACTOR / newValue2;

        assertTrue(!policyManager.checkPolicy(bytes32(uint256(1)), newValue2, newValue3) || pctDiff <= maxPctChange);

        Policy memory policy2 = policyManager.getPolicy(bytes32(uint256(1)));

        assertEq(policy2.referencePoint, newValue2, "Incorrect reference point");

        assertEq(policy2.referencePointTimestampLU, block.timestamp, "Incorrect timestamp LU");
    }
}
