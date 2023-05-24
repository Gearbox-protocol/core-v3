// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {ControllerTimelock} from "../../../support/risk-controller/ControllerTimelock.sol";
import {Policy} from "../../../support/risk-controller/PolicyManager.sol";
import {GeneralMock} from "../../mocks/GeneralMock.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

import {ICreditManagerV3} from "../../../interfaces/ICreditManagerV3.sol";
import {ICreditFacade} from "../../../interfaces/ICreditFacade.sol";
import {ICreditConfigurator} from "../../../interfaces/ICreditConfiguratorV3.sol";
import {IPoolV3} from "../../../interfaces/IPoolV3.sol";
import {PoolV3} from "../../../pool/PoolV3.sol";
import {ILPPriceFeed} from "../../../interfaces/ILPPriceFeed.sol";
import {IControllerTimelockEvents, IControllerTimelockErrors} from "../../../interfaces/IControllerTimelock.sol";

// TEST
import "../../lib/constants.sol";
import {Test} from "forge-std/Test.sol";

// MOCKS
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

contract ControllerTimelockTest is Test, IControllerTimelockEvents, IControllerTimelockErrors {
    AddressProviderV3ACLMock public addressProvider;

    ControllerTimelock public controllerTimelock;

    address admin;
    address vetoAdmin;

    function setUp() public {
        admin = makeAddr("ADMIN");
        vetoAdmin = makeAddr("VETO_ADMIN");

        vm.prank(CONFIGURATOR);
        addressProvider = new AddressProviderV3ACLMock();
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
            pool, abi.encodeWithSelector(IPoolV3.creditManagerBorrowed.selector, creditManager), abi.encode(1234)
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

        vm.mockCall(pool, abi.encodeWithSelector(IPoolV3.creditManagerBorrowed.selector, creditManager), abi.encode(0));

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

    /// @dev [RCT-2]: setLPPriceFeedLimiter works correctly
    function test_RCT_02_setLPPriceFeedLimiter_works_correctly() public {
        address lpPriceFeed = address(new GeneralMock());

        vm.prank(CONFIGURATOR);
        controllerTimelock.setGroup(lpPriceFeed, "LP_PRICE_FEED");

        vm.mockCall(lpPriceFeed, abi.encodeWithSelector(ILPPriceFeed.lowerBound.selector), abi.encode(5));

        bytes32 POLICY_CODE = keccak256(abi.encode("LP_PRICE_FEED", "LP_PRICE_FEED_LIMITER"));

        Policy memory policy = Policy({
            enabled: false,
            flags: 1,
            exactValue: 7,
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
        controllerTimelock.setLPPriceFeedLimiter(lpPriceFeed, 7);

        // VERIFY THAT POLICY CHECKS ARE PERFORMED
        vm.expectRevert(ParameterChecksFailedException.selector);
        vm.prank(admin);
        controllerTimelock.setLPPriceFeedLimiter(lpPriceFeed, 8);

        // VERIFY THAT THE FUNCTION IS QUEUED AND EXECUTED CORRECTLY
        bytes32 txHash =
            keccak256(abi.encode(lpPriceFeed, "setLimiter(uint256)", abi.encode(7), block.timestamp + 1 days));

        vm.expectEmit(true, false, false, true);
        emit QueueTransaction(
            txHash, lpPriceFeed, "setLimiter(uint256)", abi.encode(7), uint40(block.timestamp + 1 days)
        );

        vm.prank(admin);
        controllerTimelock.setLPPriceFeedLimiter(lpPriceFeed, 7);

        vm.expectCall(lpPriceFeed, abi.encodeWithSelector(ILPPriceFeed.setLimiter.selector, 7));

        vm.warp(block.timestamp + 1 days);

        vm.prank(admin);
        controllerTimelock.executeTransaction(txHash);

        (bool queued,,,,) = controllerTimelock.queuedTransactions(txHash);

        assertTrue(!queued, "Transaction is still queued after execution");
    }

    /// @dev [RCT-3]: setMaxDebtPerBlockMultiplier works correctly
    function test_RCT_03_setMaxDebtPerBlockMultiplier_works_correctly() public {
        (address creditManager, address creditFacade, address creditConfigurator, address pool) = _makeMocks();

        bytes32 POLICY_CODE = keccak256(abi.encode("CM", "MAX_DEBT_PER_BLOCK_MULTIPLIER"));

        vm.mockCall(
            creditFacade, abi.encodeWithSelector(ICreditFacade.maxDebtPerBlockMultiplier.selector), abi.encode(3)
        );

        Policy memory policy = Policy({
            enabled: false,
            flags: 1,
            exactValue: 4,
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
        controllerTimelock.setMaxDebtPerBlockMultiplier(creditManager, 4);

        // VERIFY THAT POLICY CHECKS ARE PERFORMED
        vm.expectRevert(ParameterChecksFailedException.selector);
        vm.prank(admin);
        controllerTimelock.setMaxDebtPerBlockMultiplier(creditManager, 5);

        // VERIFY THAT THE FUNCTION IS QUEUED AND EXECUTED CORRECTLY
        bytes32 txHash = keccak256(
            abi.encode(
                creditConfigurator, "setMaxDebtPerBlockMultiplier(uint8)", abi.encode(4), block.timestamp + 1 days
            )
        );

        vm.expectEmit(true, false, false, true);
        emit QueueTransaction(
            txHash,
            creditConfigurator,
            "setMaxDebtPerBlockMultiplier(uint8)",
            abi.encode(4),
            uint40(block.timestamp + 1 days)
        );

        vm.prank(admin);
        controllerTimelock.setMaxDebtPerBlockMultiplier(creditManager, 4);

        vm.expectCall(
            creditConfigurator, abi.encodeWithSelector(ICreditConfigurator.setMaxDebtPerBlockMultiplier.selector, 4)
        );

        vm.warp(block.timestamp + 1 days);

        vm.prank(admin);
        controllerTimelock.executeTransaction(txHash);

        (bool queued,,,,) = controllerTimelock.queuedTransactions(txHash);

        assertTrue(!queued, "Transaction is still queued after execution");
    }

    /// @dev [RCT-4]: setDebtLimits works correctly
    function test_RCT_04_setDebtLimits_works_correctly() public {
        (address creditManager, address creditFacade, address creditConfigurator, address pool) = _makeMocks();

        bytes32 POLICY_CODE_1 = keccak256(abi.encode("CM", "MIN_DEBT"));
        bytes32 POLICY_CODE_2 = keccak256(abi.encode("CM", "MAX_DEBT"));

        vm.mockCall(creditFacade, abi.encodeWithSelector(ICreditFacade.debtLimits.selector), abi.encode(10, 20));

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
        controllerTimelock.setPolicy(POLICY_CODE_1, policy);

        policy = Policy({
            enabled: false,
            flags: 1,
            exactValue: 16,
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
        controllerTimelock.setPolicy(POLICY_CODE_2, policy);

        // VERIFY THAT THE FUNCTION IS ONLY CALLABLE BY ADMIN
        vm.expectRevert(CallerNotAdminException.selector);
        vm.prank(USER);
        controllerTimelock.setDebtLimits(creditManager, 15, 16);

        // VERIFY THAT POLICY CHECKS ARE PERFORMED
        vm.expectRevert(ParameterChecksFailedException.selector);
        vm.prank(admin);
        controllerTimelock.setDebtLimits(creditManager, 5, 16);

        vm.expectRevert(ParameterChecksFailedException.selector);
        vm.prank(admin);
        controllerTimelock.setDebtLimits(creditManager, 15, 5);

        // VERIFY THAT THE FUNCTION IS QUEUED AND EXECUTED CORRECTLY
        bytes32 txHash = keccak256(
            abi.encode(creditConfigurator, "setLimits(uint128,uint128)", abi.encode(15, 16), block.timestamp + 1 days)
        );

        vm.expectEmit(true, false, false, true);
        emit QueueTransaction(
            txHash,
            creditConfigurator,
            "setLimits(uint128,uint128)",
            abi.encode(15, 16),
            uint40(block.timestamp + 1 days)
        );

        vm.prank(admin);
        controllerTimelock.setDebtLimits(creditManager, 15, 16);

        vm.expectCall(creditConfigurator, abi.encodeWithSelector(ICreditConfigurator.setLimits.selector, 15, 16));

        vm.warp(block.timestamp + 1 days);

        vm.prank(admin);
        controllerTimelock.executeTransaction(txHash);

        (bool queued,,,,) = controllerTimelock.queuedTransactions(txHash);

        assertTrue(!queued, "Transaction is still queued after execution");
    }

    /// @dev [RCT-5]: setCreditManagerDebtLimit works correctly
    function test_RCT_05_setCreditManagerDebtLimit_works_correctly() public {
        (address creditManager, address creditFacade, address creditConfigurator, address pool) = _makeMocks();

        bytes32 POLICY_CODE = keccak256(abi.encode("CM", "CREDIT_MANAGER_DEBT_LIMIT"));

        vm.mockCall(pool, abi.encodeWithSelector(IPoolV3.creditManagerLimit.selector, creditManager), abi.encode(1e18));

        Policy memory policy = Policy({
            enabled: false,
            flags: 1,
            exactValue: 2e18,
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
        controllerTimelock.setCreditManagerDebtLimit(creditManager, 2e18);

        // VERIFY THAT POLICY CHECKS ARE PERFORMED
        vm.expectRevert(ParameterChecksFailedException.selector);
        vm.prank(admin);
        controllerTimelock.setCreditManagerDebtLimit(creditManager, 1e18);

        // VERIFY THAT THE FUNCTION IS QUEUED AND EXECUTED CORRECTLY
        bytes32 txHash = keccak256(
            abi.encode(
                pool,
                "setCreditManagerLimit(address,uint256)",
                abi.encode(creditManager, 2e18),
                block.timestamp + 1 days
            )
        );

        vm.expectEmit(true, false, false, true);
        emit QueueTransaction(
            txHash,
            pool,
            "setCreditManagerLimit(address,uint256)",
            abi.encode(creditManager, 2e18),
            uint40(block.timestamp + 1 days)
        );

        vm.prank(admin);
        controllerTimelock.setCreditManagerDebtLimit(creditManager, 2e18);

        vm.expectCall(pool, abi.encodeWithSelector(PoolV3.setCreditManagerLimit.selector, creditManager, 2e18));

        vm.warp(block.timestamp + 1 days);

        vm.prank(admin);
        controllerTimelock.executeTransaction(txHash);

        (bool queued,,,,) = controllerTimelock.queuedTransactions(txHash);

        assertTrue(!queued, "Transaction is still queued after execution");
    }

    /// @dev [RCT-6]: rampLiquidationThreshold works correctly
    function test_RCT_06_rampLiquidationThreshold_works_correctly() public {
        (address creditManager, address creditFacade, address creditConfigurator, address pool) = _makeMocks();

        address token = makeAddr("TOKEN");

        vm.prank(CONFIGURATOR);
        controllerTimelock.setGroup(token, "TOKEN");

        bytes32 POLICY_CODE = keccak256(abi.encode("CM", "TOKEN", "TOKEN_LT"));

        vm.mockCall(
            creditManager, abi.encodeWithSelector(ICreditManagerV3.liquidationThresholds.selector), abi.encode(5000)
        );

        Policy memory policy = Policy({
            enabled: false,
            flags: 1,
            exactValue: 6000,
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
        controllerTimelock.rampLiquidationThreshold(
            creditManager, token, 6000, uint40(block.timestamp + 14 days), 7 days
        );

        // VERIFY THAT POLICY CHECKS ARE PERFORMED
        vm.expectRevert(ParameterChecksFailedException.selector);
        vm.prank(admin);
        controllerTimelock.rampLiquidationThreshold(
            creditManager, token, 5000, uint40(block.timestamp + 14 days), 7 days
        );

        // VERIFY THAT EXTRA CHECKS ARE PERFORMED
        vm.expectRevert(ParameterChecksFailedException.selector);
        vm.prank(admin);
        controllerTimelock.rampLiquidationThreshold(
            creditManager, token, 6000, uint40(block.timestamp + 14 days), 1 days
        );

        vm.expectRevert(ParameterChecksFailedException.selector);
        vm.prank(admin);
        controllerTimelock.rampLiquidationThreshold(
            creditManager, token, 6000, uint40(block.timestamp + 1 days / 2), 7 days
        );

        // VERIFY THAT THE FUNCTION IS QUEUED AND EXECUTED CORRECTLY
        bytes32 txHash = keccak256(
            abi.encode(
                creditConfigurator,
                "rampLiquidationThreshold(address,uint16,uint40,uint24)",
                abi.encode(token, 6000, block.timestamp + 14 days, 7 days),
                block.timestamp + 1 days
            )
        );

        vm.expectEmit(true, false, false, true);
        emit QueueTransaction(
            txHash,
            creditConfigurator,
            "rampLiquidationThreshold(address,uint16,uint40,uint24)",
            abi.encode(token, 6000, block.timestamp + 14 days, 7 days),
            uint40(block.timestamp + 1 days)
        );

        vm.prank(admin);
        controllerTimelock.rampLiquidationThreshold(
            creditManager, token, 6000, uint40(block.timestamp + 14 days), 7 days
        );

        vm.expectCall(
            creditConfigurator,
            abi.encodeWithSelector(
                ICreditConfigurator.rampLiquidationThreshold.selector,
                token,
                6000,
                uint40(block.timestamp + 14 days),
                7 days
            )
        );

        vm.warp(block.timestamp + 1 days);

        vm.prank(admin);
        controllerTimelock.executeTransaction(txHash);

        (bool queued,,,,) = controllerTimelock.queuedTransactions(txHash);

        assertTrue(!queued, "Transaction is still queued after execution");
    }

    /// @dev [RCT-7]: cancelTransaction works correctly
    function test_RCT_07_cancelTransaction_works_correctly() public {
        (address creditManager, address creditFacade, address creditConfigurator, address pool) = _makeMocks();

        bytes32 POLICY_CODE = keccak256(abi.encode("CM", "EXPIRATION_DATE"));

        vm.mockCall(
            creditFacade, abi.encodeWithSelector(ICreditFacade.expirationDate.selector), abi.encode(block.timestamp)
        );

        vm.mockCall(pool, abi.encodeWithSelector(IPoolV3.creditManagerBorrowed.selector, creditManager), abi.encode(0));

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

        // VERIFY THAT THE FUNCTION IS QUEUED AND EXECUTED CORRECTLY
        bytes32 txHash = keccak256(
            abi.encode(
                creditConfigurator,
                "setExpirationDate(uint40)",
                abi.encode(block.timestamp + 5),
                block.timestamp + 1 days
            )
        );

        vm.prank(admin);
        controllerTimelock.setExpirationDate(creditManager, uint40(block.timestamp + 5));

        vm.expectRevert(CallerNotVetoAdminException.selector);

        vm.prank(admin);
        controllerTimelock.cancelTransaction(txHash);

        vm.expectEmit(true, false, false, false);
        emit CancelTransaction(txHash);

        vm.prank(vetoAdmin);
        controllerTimelock.cancelTransaction(txHash);

        (bool queued,,,,) = controllerTimelock.queuedTransactions(txHash);

        assertTrue(!queued, "Transaction is still queued after cancelling");

        vm.expectRevert(TxNotQueuedException.selector);
        vm.prank(admin);
        controllerTimelock.executeTransaction(txHash);
    }

    /// @dev [RCT-8]: configuration functions work correctly
    function test_RCT_08_cancelTransaction_works_correctly() public {
        vm.expectRevert(CallerNotConfiguratorException.selector);
        vm.prank(USER);
        controllerTimelock.setAdmin(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        vm.prank(USER);
        controllerTimelock.setVetoAdmin(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        vm.prank(USER);
        controllerTimelock.setDelay(5);

        vm.expectEmit(true, false, false, false);
        emit SetAdmin(DUMB_ADDRESS);

        vm.prank(CONFIGURATOR);
        controllerTimelock.setAdmin(DUMB_ADDRESS);

        assertEq(controllerTimelock.admin(), DUMB_ADDRESS, "Admin address was not set");

        vm.expectEmit(true, false, false, false);
        emit SetVetoAdmin(DUMB_ADDRESS);

        vm.prank(CONFIGURATOR);
        controllerTimelock.setVetoAdmin(DUMB_ADDRESS);

        assertEq(controllerTimelock.vetoAdmin(), DUMB_ADDRESS, "Veto admin address was not set");

        vm.expectEmit(false, false, false, true);
        emit SetDelay(5);

        vm.prank(CONFIGURATOR);
        controllerTimelock.setDelay(5);

        assertEq(controllerTimelock.delay(), 5, "Delay was not set");
    }

    /// @dev [RCT-9]: executeTransaction works correctly
    function test_RCT_09_executeTransaction_works_correctly() public {
        (address creditManager, address creditFacade, address creditConfigurator, address pool) = _makeMocks();

        bytes32 POLICY_CODE = keccak256(abi.encode("CM", "EXPIRATION_DATE"));

        vm.mockCall(
            creditFacade, abi.encodeWithSelector(ICreditFacade.expirationDate.selector), abi.encode(block.timestamp)
        );

        vm.mockCall(pool, abi.encodeWithSelector(IPoolV3.creditManagerBorrowed.selector, creditManager), abi.encode(0));

        uint40 expirationDate = uint40(block.timestamp + 2 days);

        Policy memory policy = Policy({
            enabled: false,
            flags: 1,
            exactValue: expirationDate,
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

        // VERIFY THAT THE FUNCTION IS QUEUED AND EXECUTED CORRECTLY
        bytes32 txHash = keccak256(
            abi.encode(
                creditConfigurator, "setExpirationDate(uint40)", abi.encode(expirationDate), block.timestamp + 1 days
            )
        );

        vm.prank(admin);
        controllerTimelock.setExpirationDate(creditManager, expirationDate);

        vm.expectRevert(CallerNotAdminException.selector);

        vm.prank(USER);
        controllerTimelock.executeTransaction(txHash);

        vm.expectRevert(TxExecutedOutsideTimeWindowException.selector);
        vm.prank(admin);
        controllerTimelock.executeTransaction(txHash);

        vm.warp(block.timestamp + 20 days);

        vm.expectRevert(TxExecutedOutsideTimeWindowException.selector);
        vm.prank(admin);
        controllerTimelock.executeTransaction(txHash);

        vm.warp(block.timestamp - 10 days);

        vm.mockCallRevert(
            creditConfigurator,
            abi.encodeWithSelector(ICreditConfigurator.setExpirationDate.selector, expirationDate),
            abi.encode("error")
        );

        vm.expectRevert(TxExecutionRevertedException.selector);
        vm.prank(admin);
        controllerTimelock.executeTransaction(txHash);

        vm.clearMockedCalls();

        vm.expectEmit(true, false, false, false);
        emit ExecuteTransaction(txHash);

        vm.prank(admin);
        controllerTimelock.executeTransaction(txHash);
    }

    /// @dev [RCT-10]: forbidContract works correctly
    function test_RCT_10_forbidContract_works_correctly() public {
        (address creditManager, address creditFacade, address creditConfigurator, address pool) = _makeMocks();

        bytes32 POLICY_CODE = keccak256(abi.encode("CM", "FORBID_CONTRACT"));

        Policy memory policy = Policy({
            enabled: false,
            flags: 0,
            exactValue: 0,
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

        // VERIFY THAT THE FUNCTION CANNOT BE CALLED WITHOUT RESPECTIVE POLICY
        vm.expectRevert(ParameterChecksFailedException.selector);
        vm.prank(admin);
        controllerTimelock.forbidContract(creditManager, DUMB_ADDRESS);

        vm.prank(CONFIGURATOR);
        controllerTimelock.setPolicy(POLICY_CODE, policy);

        // VERIFY THAT THE FUNCTION IS ONLY CALLABLE BY ADMIN
        vm.expectRevert(CallerNotAdminException.selector);
        vm.prank(USER);
        controllerTimelock.forbidContract(creditManager, DUMB_ADDRESS);

        // VERIFY THAT THE FUNCTION IS QUEUED AND EXECUTED CORRECTLY
        bytes32 txHash = keccak256(
            abi.encode(
                creditConfigurator, "forbidContract(address)", abi.encode(DUMB_ADDRESS), block.timestamp + 1 days
            )
        );

        vm.expectEmit(true, false, false, true);
        emit QueueTransaction(
            txHash,
            creditConfigurator,
            "forbidContract(address)",
            abi.encode(DUMB_ADDRESS),
            uint40(block.timestamp + 1 days)
        );

        vm.prank(admin);
        controllerTimelock.forbidContract(creditManager, DUMB_ADDRESS);

        vm.expectCall(
            creditConfigurator, abi.encodeWithSelector(ICreditConfigurator.forbidContract.selector, DUMB_ADDRESS)
        );

        vm.warp(block.timestamp + 1 days);

        vm.prank(admin);
        controllerTimelock.executeTransaction(txHash);

        (bool queued,,,,) = controllerTimelock.queuedTransactions(txHash);

        assertTrue(!queued, "Transaction is still queued after execution");
    }
}
