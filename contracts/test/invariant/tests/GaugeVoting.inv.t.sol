// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {VotingHandler} from "../handlers/VotingHandler.sol";
import {InvariantTestBase} from "./InvariantTestBase.sol";

contract GaugeVotingInvariantTest is InvariantTestBase {
    VotingHandler votingHandler;

    function setUp() public override {
        _deployCore();
        _deployTokensAndPriceFeeds();
        _deployPool("DAI");
        _deployPool("USDC");

        votingHandler = new VotingHandler(gearStaking, 30 days);
        address[] memory stakers = _generateAddrs("Staker", 5);
        for (uint256 i; i < stakers.length; ++i) {
            votingHandler.addStaker(stakers[i]);
            deal(gear, stakers[i], 10_000_000e18);
        }

        votingHandler.addVotingContract(address(_getGauge("Diesel DAI v3")));
        votingHandler.addVotingContract(address(_getGauge("Diesel USDC v3")));
        votingHandler.setGaugeTokens(address(_getGauge("Diesel DAI v3")), _getQuotedTokens("Diesel DAI v3"));
        votingHandler.setGaugeTokens(address(_getGauge("Diesel USDC v3")), _getQuotedTokens("Diesel USDC v3"));

        Selector[] memory selectors = new Selector[](5);
        selectors[0] = Selector(votingHandler.deposit.selector, 2);
        selectors[1] = Selector(votingHandler.withdraw.selector, 1);
        selectors[2] = Selector(votingHandler.claimWithdrawals.selector, 1);
        selectors[3] = Selector(votingHandler.voteGauge.selector, 3);
        selectors[4] = Selector(votingHandler.unvoteGauge.selector, 3);
        _addFuzzingTarget(address(votingHandler), selectors);
    }

    function invariant_gauge_voting() public {
        _assert_voting_invariant_01(votingHandler);
        _assert_voting_invariant_02(votingHandler);
        _assert_voting_invariant_03(votingHandler);
        _assert_voting_invariant_04(votingHandler);
    }
}
