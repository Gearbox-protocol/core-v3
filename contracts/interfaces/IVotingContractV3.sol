// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

interface IVotingContractV3 {
    function vote(address user, uint96 votes, bytes calldata extraData) external;
    function unvote(address user, uint96 votes, bytes calldata extraData) external;
}
