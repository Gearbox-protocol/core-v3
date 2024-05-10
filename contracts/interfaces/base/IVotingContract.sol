// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";

/// @title Voting contract interface
/// @notice Generic interface for a contract that can be voted for in `GearStakingV3` contract
/// @dev `vote` and `unvote` must implement votes accounting since it's not performed on the staking contract side
interface IVotingContract is IVersion {
    function vote(address user, uint96 votes, bytes calldata extraData) external;
    function unvote(address user, uint96 votes, bytes calldata extraData) external;
}