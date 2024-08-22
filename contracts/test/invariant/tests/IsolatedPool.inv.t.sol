// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {PoolHandler} from "../handlers/PoolHandler.sol";
import {InvariantTestBase} from "./InvariantTestBase.sol";

contract IsolatedPoolInvariantTest is InvariantTestBase {
    PoolHandler poolHandler;

    function setUp() public override {
        _deployCore();
        _deployTokensAndPriceFeeds();
        _deployPool("DAI");

        // NOTE: testing in a single point in time
        poolHandler = new PoolHandler(_getPool("Diesel DAI v3"), 0 days);
        address[] memory depositors = _generateAddrs("Depositor", 5);
        for (uint256 i; i < depositors.length; ++i) {
            poolHandler.addDepositor(depositors[i]);
            deal(address(tokens["DAI"]), depositors[i], 10_000_000e18);
        }

        // NOTE: add dummy credit managers
        address[] memory creditManagers = _generateAddrs("Credit manager", 2);
        vm.startPrank(configurator);
        for (uint256 i; i < 2; ++i) {
            vm.mockCall(creditManagers[i], abi.encodeWithSignature("pool()"), abi.encode(address(poolHandler.pool())));
            contractsRegister.addCreditManager(creditManagers[i]);
            poolHandler.pool().setCreditManagerDebtLimit(creditManagers[i], 30_000_000e18);
            deal(address(tokens["DAI"]), creditManagers[i], 5_000_000e18);
        }
        vm.stopPrank();

        Selector[] memory selectors = new Selector[](7);
        selectors[0] = Selector(poolHandler.deposit.selector, 4);
        selectors[1] = Selector(poolHandler.mint.selector, 1);
        selectors[2] = Selector(poolHandler.withdraw.selector, 1);
        selectors[3] = Selector(poolHandler.redeem.selector, 4);
        selectors[4] = Selector(poolHandler.borrow.selector, 5);
        selectors[5] = Selector(poolHandler.repayWithProfit.selector, 3);
        selectors[6] = Selector(poolHandler.repayWithLoss.selector, 2);
        _addFuzzingTarget(address(poolHandler), selectors);
    }

    function invariant_isolated_pool() public {
        _assert_pool_invariant_01(poolHandler);
        _assert_pool_invariant_02(poolHandler);
        _assert_pool_invariant_03(poolHandler);
        _assert_pool_invariant_04(poolHandler);
        _assert_pool_invariant_05(poolHandler);
    }
}
