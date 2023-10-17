// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {
    IGearStakingV3, MultiVote, EPOCHS_TO_WITHDRAW, VotingContractStatus
} from "../../../interfaces/IGearStakingV3.sol";

contract GearStakingMock is IGearStakingV3 {
    uint256 public constant version = 3_00;

    uint16 public getCurrentEpoch;

    function setCurrentEpoch(uint16 epoch) external {
        getCurrentEpoch = epoch;
    }

    function firstEpochTimestamp() external view returns (uint256) {}

    function deposit(uint96 amount, MultiVote[] calldata votes) external {}

    function depositWithPermit(
        uint96 amount,
        MultiVote[] calldata votes,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {}

    function multivote(MultiVote[] calldata votes) external {}

    function withdraw(uint96 amount, address to, MultiVote[] calldata votes) external {}

    function claimWithdrawals(address to) external {}

    function migrate(uint96 amount, MultiVote[] calldata votesBefore, MultiVote[] calldata votesAfter) external {}

    function depositOnMigration(uint96 amount, address to, MultiVote[] calldata votes) external {}

    //
    // GETTERS
    //

    /// @dev GEAR token address
    function gear() external view returns (address) {}

    /// @dev The total amount staked by the user in staked GEAR
    function balanceOf(address user) external view returns (uint256) {}

    /// @dev The amount available to the user for voting or withdrawal
    function availableBalance(address user) external view returns (uint256) {}

    /// @dev Returns the amounts withdrawable now and over the next 4 epochs
    function getWithdrawableAmounts(address user)
        external
        view
        returns (uint256 withdrawableNow, uint256[EPOCHS_TO_WITHDRAW] memory withdrawableInEpochs)
    {}

    function allowedVotingContract(address) external view returns (VotingContractStatus) {}

    function setVotingContractStatus(address votingContract, VotingContractStatus status) external {}

    function successor() external view returns (address) {}

    function setSuccessor(address newSuccessor) external {}

    function migrator() external view returns (address) {}

    function setMigrator(address newMigrator) external {}
}
