// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {EPOCHS_TO_WITHDRAW} from "../libraries/Constants.sol";
import {IVersion} from "./base/IVersion.sol";

/// @notice Voting contract status
///         * `NOT_ALLOWED` - can neither vote or unvote
///         * `ALLOWED` - can both vote and unvote
///         * `UNVOTE_ONLY` - can only unvote
enum VotingContractStatus {
    NOT_ALLOWED,
    ALLOWED,
    UNVOTE_ONLY
}

/// @notice Multi vote
/// @param  votingContract Contract to submit a vote to
/// @param  voteAmount Amount of staked GEAR to vote with
/// @param  isIncrease Whether to add or remove votes
/// @param  extraData Data to pass to the voting contract
struct MultiVote {
    address votingContract;
    uint96 voteAmount;
    bool isIncrease;
    bytes extraData;
}

/// @title Gear staking V3 interface
interface IGearStakingV3 is IVersion {
    // ------ //
    // EVENTS //
    // ------ //

    /// @notice Emitted when the user deposits GEAR into staking contract
    event DepositGear(address indexed user, uint256 amount);

    /// @notice Emitted when the user migrates GEAR into a successor contract
    event MigrateGear(address indexed user, address indexed successor, uint256 amount);

    /// @notice Emitted when the user starts a withdrawal from staked contract
    event ScheduleGearWithdrawal(address indexed user, uint256 amount);

    /// @notice Emitted when the user claims a mature withdrawal from staked contract
    event ClaimGearWithdrawal(address indexed user, address to, uint256 amount);

    /// @notice Emitted when the configurator adds or removes a voting contract
    event SetVotingContractStatus(address indexed votingContract, VotingContractStatus status);

    /// @notice Emitted when the new successor contract is set
    event SetSuccessor(address indexed successor);

    /// @notice Emitted when the new migrator contract is set
    event SetMigrator(address indexed migrator);

    // ------- //
    // GETTERS //
    // ------- //

    function gear() external view returns (address);

    function firstEpochTimestamp() external view returns (uint256);

    function getCurrentEpoch() external view returns (uint16);

    function balanceOf(address user) external view returns (uint256);

    function availableBalance(address user) external view returns (uint256);

    function getWithdrawableAmounts(address user)
        external
        view
        returns (uint256 withdrawableNow, uint256[EPOCHS_TO_WITHDRAW] memory withdrawableInEpochs);

    // ------------------ //
    // STAKING AND VOTING //
    // ------------------ //

    function deposit(uint96 amount, MultiVote[] calldata votes) external;

    function depositWithPermit(
        uint96 amount,
        MultiVote[] calldata votes,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function multivote(MultiVote[] calldata votes) external;

    function withdraw(uint96 amount, address to, MultiVote[] calldata votes) external;

    function claimWithdrawals(address to) external;

    function migrate(uint96 amount, MultiVote[] calldata votesBefore, MultiVote[] calldata votesAfter) external;

    function depositOnMigration(uint96 amount, address onBehalfOf, MultiVote[] calldata votes) external;

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function allowedVotingContract(address) external view returns (VotingContractStatus);

    function setVotingContractStatus(address votingContract, VotingContractStatus status) external;

    function successor() external view returns (address);

    function setSuccessor(address newSuccessor) external;

    function migrator() external view returns (address);

    function setMigrator(address newMigrator) external;
}
