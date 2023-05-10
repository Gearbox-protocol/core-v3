// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {ControllerTimelock} from "../../../support/risk-controller/ControllerTimelock.sol";
import {Policy} from "../../../support/risk-controller/PolicyManager.sol";
import {GeneralMock} from "../../mocks/GeneralMock.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

import {ICreditManagerV3} from "../../../interfaces/ICreditManagerV3.sol";
import {ICreditFacade} from "../../../interfaces/ICreditFacade.sol";
import {ICreditConfigurator} from "../../../interfaces/ICreditConfiguratorV3.sol";
import {IPool4626} from "../../../interfaces/IPool4626.sol";
import {IControllerTimelockEvents, IControllerTimelockErrors} from "../../../interfaces/IControllerTimelock.sol";

// TEST
import "../../lib/constants.sol";
import {Test} from "forge-std/Test.sol";

// MOCKS
import {AddressProviderACLMock} from "../../mocks/core/AddressProviderACLMock.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

contract ControllerTimelockTest is Test, IControllerTimelockEvents, IControllerTimelockErrors {
    AddressProviderACLMock public addressProvider;

    ControllerTimelock public controllerTimelock;

    address admin;
    address vetoAdmin;

    function setUp() public {
        admin = makeAddr("ADMIN");
        vetoAdmin = makeAddr("VETO_ADMIN");

        vm.prank(CONFIGURATOR);
        addressProvider = new AddressProviderACLMock();
        controllerTimelock = new ControllerTimelock(address(addressProvider), admin, vetoAdmin);
    }

    function _makeMocks()
        internal
        returns (address creditManager, address creditFacade, address creditConfigurator, address pool)
    {
        creditManager = address(new GeneralMock());
        creditFacade = address(new GeneralMock());
        creditConfigurator = address(new GeneralMock());
        pool = address(new GeneralMock());

        vm.mockCall(
            creditManager, abi.encodeWithSelector(ICreditManagerV3.creditFacade.selector), abi.encode(creditFacade)
        );

        vm.mockCall(
            creditManager,
            abi.encodeWithSelector(ICreditManagerV3.creditConfigurator.selector),
            abi.encode(creditConfigurator)
        );

        vm.mockCall(creditManager, abi.encodeWithSelector(ICreditManagerV3.pool.selector), abi.encode(pool));

        vm.prank(CONFIGURATOR);
        controllerTimelock.setGroup(creditManager, "CM");

        vm.label(creditManager, "CREDIT_MANAGER");
        vm.label(creditFacade, "CREDIT_FACADE");
        vm.label(creditConfigurator, "CREDIT_CONFIGURATOR");
        vm.label(pool, "POOL");
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev [RCT-1]: setExpirationDate works correctly
    function test_RCT_01_setExpirationDate_works_correctly() public {
        (address creditManager, address creditFacade, address creditConfigurator, address pool) = _makeMocks();

        bytes32 POLICY_CODE = keccak256(abi.encode("CM", "EXPIRATION_DATE"));

        vm.mockCall(
            creditFacade, abi.encodeWithSelector(ICreditFacade.expirationDate.selector), abi.encode(block.timestamp)
        );

        vm.mockCall(
            pool, abi.encodeWithSelector(IPool4626.creditManagerBorrowed.selector, creditManager), abi.encode(1234)
        );

        Policy memory policy = Policy({
            enabled: false,
            flags: 1,
            exactValue: block.timestamp + 5,
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
        controllerTimelock.setPolicy(POLICY_CODE, policy);

        // VERIFY THAT THE FUNCTION IS ONLY CALLABLE BY ADMIN
        vm.expectRevert(CallerNotAdminException.selector);
        vm.prank(USER);
        controllerTimelock.setExpirationDate(creditManager, uint40(block.timestamp + 5));

        // VERIFY THAT POLICY CHECKS ARE PERFORMED
        vm.expectRevert(ParameterChecksFailedException.selector);
        vm.prank(admin);
        controllerTimelock.setExpirationDate(creditManager, uint40(block.timestamp + 4));

        // VERIFY THAT EXTRA CHECKS ARE PERFORMED
        vm.expectRevert(ParameterChecksFailedException.selector);
        vm.prank(admin);
        controllerTimelock.setExpirationDate(creditManager, uint40(block.timestamp + 5));

        vm.mockCall(
            pool, abi.encodeWithSelector(IPool4626.creditManagerBorrowed.selector, creditManager), abi.encode(0)
        );

        // VERIFY THAT THE FUNCTION IS QUEUED AND EXECUTED CORRECTLY
        bytes32 txHash = keccak256(
            abi.encode(
                creditConfigurator,
                "setExpirationDate(uint40)",
                abi.encode(block.timestamp + 5),
                block.timestamp + 1 days
            )
        );

        vm.expectEmit(true, false, false, true);
        emit QueueTransaction(
            txHash,
            creditConfigurator,
            "setExpirationDate(uint40)",
            abi.encode(block.timestamp + 5),
            uint40(block.timestamp + 1 days)
        );

        vm.prank(admin);
        controllerTimelock.setExpirationDate(creditManager, uint40(block.timestamp + 5));

        vm.expectCall(
            creditConfigurator,
            abi.encodeWithSelector(ICreditConfigurator.setExpirationDate.selector, block.timestamp + 5)
        );

        vm.warp(block.timestamp + 1 days);

        vm.prank(admin);
        controllerTimelock.executeTransaction(txHash);

        (bool queued,,,,) = controllerTimelock.queuedTransactions(txHash);

        assertTrue(!queued, "Transaction is still queued after execution");
    }
}
