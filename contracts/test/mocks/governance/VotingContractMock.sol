// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVotingContractV3} from "../../../interfaces/IVotingContractV3.sol";

contract VotingContractMock is IVotingContractV3 {
    mapping(address => uint96) public userVotes;

    function vote(address user, uint96 votes, bytes calldata) external {
        userVotes[user] += votes;
    }

    function unvote(address user, uint96 votes, bytes calldata) external {
        userVotes[user] -= votes;
    }
}
