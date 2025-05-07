// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";

import {CreditHandler} from "../handlers/CreditHandler.sol";
import {PoolHandler} from "../handlers/PoolHandler.sol";
import {VotingHandler} from "../handlers/VotingHandler.sol";

import {InvariantTestBase} from "./InvariantTestBase.sol";

contract GlobalInvariantTest is InvariantTestBase {
    VotingHandler votingHandler;
    PoolHandler poolHandler;
    CreditHandler creditHandler;

    function setUp() public override {
        _deployCore();
        _deployTokensAndPriceFeeds();
        _deployPool("DAI");
        _deployCreditManager("DAI");

        votingHandler = new VotingHandler(gearStaking, 30 days);
        address[] memory stakers = _generateAddrs("Staker", 5);
        for (uint256 i; i < stakers.length; ++i) {
            votingHandler.addStaker(stakers[i]);
            deal(gear, stakers[i], 10_000_000e18);
        }
        votingHandler.addVotingContract(address(_getGauge("Diesel DAI v3")));
        votingHandler.setGaugeTokens(address(_getGauge("Diesel DAI v3")), _getQuotedTokens("Diesel DAI v3"));

        poolHandler = new PoolHandler(_getPool("Diesel DAI v3"), 30 days);
        address[] memory depositors = _generateAddrs("Depositor", 5);
        for (uint256 i; i < depositors.length; ++i) {
            poolHandler.addDepositor(depositors[i]);
            deal(address(tokens["DAI"]), depositors[i], 10_000_000e18);
        }

        creditHandler = new CreditHandler(_getCreditManager("DAI v3"), 30 days);
        address[] memory owners = _generateAddrs("Owner", 5);
        for (uint256 i; i < owners.length; ++i) {
            vm.prank(owners[i]);
            creditHandler.creditFacade().openCreditAccount(owners[i], new MultiCall[](0), 0);
            deal(address(tokens["DAI"]), owners[i], 2_500_000e18);
            deal(address(tokens["WETH"]), owners[i], 1_000e18);
            deal(address(tokens["WBTC"]), owners[i], 50e8);
            deal(address(tokens["LINK"]), owners[i], 100_000e18);
        }

        Selector[] memory votingSelectors = new Selector[](5);
        votingSelectors[0] = Selector(votingHandler.deposit.selector, 2);
        votingSelectors[1] = Selector(votingHandler.withdraw.selector, 1);
        votingSelectors[2] = Selector(votingHandler.claimWithdrawals.selector, 1);
        votingSelectors[3] = Selector(votingHandler.voteGauge.selector, 3);
        votingSelectors[4] = Selector(votingHandler.unvoteGauge.selector, 3);
        _addFuzzingTarget(address(votingHandler), votingSelectors);

        Selector[] memory poolSelectors = new Selector[](4);
        poolSelectors[0] = Selector(poolHandler.deposit.selector, 4);
        poolSelectors[1] = Selector(poolHandler.mint.selector, 1);
        poolSelectors[2] = Selector(poolHandler.withdraw.selector, 1);
        poolSelectors[3] = Selector(poolHandler.redeem.selector, 4);
        _addFuzzingTarget(address(poolHandler), poolSelectors);

        Selector[] memory creditSelectors = new Selector[](9);
        creditSelectors[0] = Selector(creditHandler.addCollateral.selector, 3);
        creditSelectors[1] = Selector(creditHandler.withdrawCollateral.selector, 3);
        creditSelectors[2] = Selector(creditHandler.increaseDebt.selector, 3);
        creditSelectors[3] = Selector(creditHandler.decreaseDebt.selector, 3);
        creditSelectors[4] = Selector(creditHandler.addAndRepay.selector, 3);
        creditSelectors[5] = Selector(creditHandler.borrowAndWithdraw.selector, 3);
        creditSelectors[6] = Selector(creditHandler.increaseQuota.selector, 4);
        creditSelectors[7] = Selector(creditHandler.decreaseQuota.selector, 4);
        creditSelectors[6] = Selector(creditHandler.swapCollateral.selector, 4);
        _addFuzzingTarget(address(creditHandler), creditSelectors);
    }

    function invariant_global() public {
        _assert_voting_invariant_01(votingHandler);
        _assert_voting_invariant_02(votingHandler);
        _assert_voting_invariant_03(votingHandler);
        _assert_voting_invariant_04(votingHandler);

        _assert_pool_invariant_01(poolHandler);
        _assert_pool_invariant_02(poolHandler);
        _assert_pool_invariant_03(poolHandler);
        _assert_pool_invariant_04(poolHandler);
        _assert_pool_invariant_05(poolHandler);

        _assert_credit_invariant_01(creditHandler);
        _assert_credit_invariant_02(creditHandler);
        _assert_credit_invariant_03(creditHandler);
        _assert_credit_invariant_04(creditHandler);
        _assert_credit_invariant_05(creditHandler);

        _assert_global_invariant_01(poolHandler, creditHandler);
    }
}
