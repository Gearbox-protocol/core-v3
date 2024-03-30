// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";

import {CreditHandler} from "../handlers/CreditHandler.sol";
import {InvariantTestBase} from "./InvariantTestBase.sol";

contract IsolatedCreditInvariantTest is InvariantTestBase {
    CreditHandler creditHandler;

    function setUp() public override {
        _deployCore();
        _deployTokensAndPriceFeeds();
        _deployPool("DAI");
        _deployCreditManager("DAI");

        // NOTE: seed pool with liquidity
        deal(address(tokens["DAI"]), address(this), 30_000_000e18);
        tokens["DAI"].approve(address(_getPool("Diesel DAI v3")), 30_000_000e18);
        _getPool("Diesel DAI v3").deposit(30_000_000e18, address(this));

        // NOTE: testing in a single point in time
        creditHandler = new CreditHandler(_getCreditManager("DAI v3"), 0 days);
        address[] memory owners = _generateAddrs("Owner", 5);
        for (uint256 i; i < owners.length; ++i) {
            vm.prank(owners[i]);
            creditHandler.creditFacade().openCreditAccount(owners[i], new MultiCall[](0), 0);
            deal(address(tokens["DAI"]), owners[i], 2_500_000e18);
            deal(address(tokens["WETH"]), owners[i], 1_000e18);
            deal(address(tokens["WBTC"]), owners[i], 50e8);
            deal(address(tokens["LINK"]), owners[i], 100_000e18);
        }

        Selector[] memory selectors = new Selector[](9);
        selectors[0] = Selector(creditHandler.addCollateral.selector, 3);
        selectors[1] = Selector(creditHandler.withdrawCollateral.selector, 3);
        selectors[2] = Selector(creditHandler.increaseDebt.selector, 3);
        selectors[3] = Selector(creditHandler.decreaseDebt.selector, 3);
        selectors[4] = Selector(creditHandler.addAndRepay.selector, 3);
        selectors[5] = Selector(creditHandler.borrowAndWithdraw.selector, 3);
        selectors[6] = Selector(creditHandler.increaseQuota.selector, 4);
        selectors[7] = Selector(creditHandler.decreaseQuota.selector, 4);
        selectors[8] = Selector(creditHandler.swapCollateral.selector, 4);
        _addFuzzingTarget(address(creditHandler), selectors);
    }

    function invariant_isolated_credit() public {
        _assert_credit_invariant_01(creditHandler);
        _assert_credit_invariant_02(creditHandler);
        _assert_credit_invariant_03(creditHandler);
        _assert_credit_invariant_04(creditHandler);
        _assert_credit_invariant_05(creditHandler);
    }
}
