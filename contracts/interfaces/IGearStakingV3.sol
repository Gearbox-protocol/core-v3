// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

uint256 constant EPOCH_LENGTH = 7 days;

uint256 constant EPOCHS_TO_WITHDRAW = 4;

enum VotingContractStatus {
    NOT_ALLOWED,
    ALLOWED,
    UNVOTE_ONLY
}

struct UserVoteLockData {
    uint96 totalStaked;
    uint96 available;
}

struct WithdrawalData {
    uint96[EPOCHS_TO_WITHDRAW] withdrawalsPerEpoch;
    uint16 epochLastUpdate;
}

struct MultiVote {
    address votingContract;
    uint96 voteAmount;
    bool isIncrease;
    bytes extraData;
}

interface IGearStakingV3Events {
    /// @dev Emits when the user deposits GEAR into staked GEAR
    event DepositGear(address indexed user, uint256 amount);

    /// @dev Emits when the user migrates GEAR into a successor contract
    event MigrateGear(address indexed user, address indexed successor, uint256 amount);

    /// @dev Emits when the user starts a withdrawal from staked GEAR
    event ScheduleGearWithdrawal(address indexed user, uint256 amount);

    /// @dev Emits when the user claims a mature withdrawal from staked GEAR
    event ClaimGearWithdrawal(address indexed user, address to, uint256 amount);

    /// @dev Emits when the configurator adds or removes a voting contract
    event SetVotingContractStatus(address indexed votingContract, VotingContractStatus status);

    /// @dev Emits when the new successor contract is set
    event SetSuccessor(address indexed successor);

    /// @dev Emits when the new migrator contract is set
    event SetMigrator(address indexed migrator);
}

interface IGearStakingV3 is IGearStakingV3Events, IVersion {
    /// @dev Returns the current global voting epoch
    function getCurrentEpoch() external view returns (uint16);

    /// @dev Deposits an amount of GEAR into staked GEAR. Optionally, performs a sequence of vote changes according to
    ///      the passed `votes` array
    /// @param amount Amount of GEAR to deposit into staked GEAR
    /// @param votes Array of MultVote structs:
    ///              * votingContract - contract to submit a vote to
    ///              * voteAmount - amount of staked GEAR to add to or remove from a vote
    ///              * isIncrease - whether to add or remove votes
    ///              * extraData - data specific to the voting contract that is decoded on recipient side
    function deposit(uint96 amount, MultiVote[] calldata votes) external;

    /// @dev Performs a sequence of vote changes according to the passed array
    /// @param votes Array of MultVote structs:
    ///              * votingContract - contract to submit a vote to
    ///              * voteAmount - amount of staked GEAR to add to or remove from a vote
    ///              * isIncrease - whether to add or remove votes
    ///              * extraData - data specific to the voting contract that is decoded on recipient side
    function multivote(MultiVote[] calldata votes) external;

    /// @dev Schedules a withdrawal from staked GEAR into GEAR, which can be claimed in 4 epochs.
    ///      If there are any withdrawals available to claim, they are also claimed.
    ///      Optionally, performs a sequence of vote changes according to
    ///      the passed `votes` array.
    /// @param amount Amount of staked GEAR to withdraw into GEAR
    /// @param to Address to send claimable GEAR, if any
    /// @param votes Array of MultVote structs:
    ///              * votingContract - contract to submit a vote to
    ///              * voteAmount - amount of staked GEAR to add to or remove from a vote
    ///              * isIncrease - whether to add or remove votes
    ///              * extraData - data specific to the voting contract that is decoded on recipient side
    function withdraw(uint96 amount, address to, MultiVote[] calldata votes) external;

    /// @dev Claims all of the caller's withdrawals that are mature
    /// @param to Address to send claimable GEAR, if any
    function claimWithdrawals(address to) external;

    /// @notice Migrates the user's staked GEAR to a `successor` GearStaking contract without waiting for the withdrawal delay
    /// @param amount Amount if staked GEAR to migrate
    /// @param votesBefore Votes to apply before sending GEAR to the successor contract
    /// @param votesAfter Votes to apply in the new contract after sending GEAR
    function migrate(uint96 amount, MultiVote[] calldata votesBefore, MultiVote[] calldata votesAfter) external;

    /// @notice Performs a deposit on user's behalf from the migrator (usually the previous GearStaking contract)
    /// @param amount Amount of GEAR to deposit
    /// @param onBehalfOf Address to deposit to
    /// @param onBehalfOf User on whose behalf to deposit
    /// @param votes Array of votes to apply after migrating
    function depositOnMigration(uint96 amount, address onBehalfOf, MultiVote[] calldata votes) external;

    //
    // GETTERS
    //

    /// @dev GEAR token address
    function gear() external view returns (address);

    /// @dev The total amount staked by the user in staked GEAR
    function balanceOf(address user) external view returns (uint256);

    /// @dev The amount available to the user for voting or withdrawal
    function availableBalance(address user) external view returns (uint256);

    /// @dev Returns the amounts withdrawable now and over the next 4 epochs
    function getWithdrawableAmounts(address user)
        external
        view
        returns (uint256 withdrawableNow, uint256[EPOCHS_TO_WITHDRAW] memory withdrawableInEpochs);

    /// @dev Mapping of address to their status as allowed voting contract
    function allowedVotingContract(address c) external view returns (VotingContractStatus);
}
