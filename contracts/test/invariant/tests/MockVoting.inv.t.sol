// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {VotingContractStatus} from "../../../interfaces/IGearStakingV3.sol";
import {VotingContractMock} from "../../mocks/governance/VotingContractMock.sol";
import {VotingHandler} from "../handlers/VotingHandler.sol";
import {InvariantTestBase} from "./InvariantTestBase.sol";

contract MockVotingInvariantTest is InvariantTestBase {
    VotingHandler votingHandler;

    function setUp() public override {
        _deployCore();

        votingHandler = new VotingHandler(gearStaking, 30 days);
        address[] memory stakers = _generateAddrs("Staker", 5);
        for (uint256 i; i < stakers.length; ++i) {
            votingHandler.addStaker(stakers[i]);
            deal(gear, stakers[i], 10_000_000e18);
        }

        for (uint256 i; i < 2; ++i) {
            address votingContractMock = address(new VotingContractMock());
            vm.prank(configurator);
            gearStaking.setVotingContractStatus(votingContractMock, VotingContractStatus.ALLOWED);
            votingHandler.addVotingContract(votingContractMock);
        }

        Selector[] memory selectors = new Selector[](5);
        selectors[0] = Selector(votingHandler.deposit.selector, 2);
        selectors[1] = Selector(votingHandler.withdraw.selector, 1);
        selectors[2] = Selector(votingHandler.claimWithdrawals.selector, 1);
        selectors[3] = Selector(votingHandler.vote.selector, 3);
        selectors[4] = Selector(votingHandler.unvote.selector, 3);
        _addFuzzingTarget(address(votingHandler), selectors);
    }

    function invariant_mock_voting() public {
        _assert_voting_invariant_01(votingHandler);
        _assert_voting_invariant_02(votingHandler);
    }
}
