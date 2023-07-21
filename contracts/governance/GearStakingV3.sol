// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {AP_GEAR_TOKEN, IAddressProviderV3, NO_VERSION_CONTROL} from "../interfaces/IAddressProviderV3.sol";
import {IVotingContractV3} from "../interfaces/IVotingContractV3.sol";
import {
    IGearStakingV3,
    UserVoteLockData,
    WithdrawalData,
    MultiVote,
    VotingContractStatus,
    EPOCHS_TO_WITHDRAW,
    EPOCH_LENGTH
} from "../interfaces/IGearStakingV3.sol";

import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

contract GearStakingV3 is ACLNonReentrantTrait, IGearStakingV3 {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice Address of the GEAR token
    address public immutable override gear;

    /// @notice Timestamp of the first epoch of voting
    uint256 immutable firstEpochTimestamp;

    /// @notice Mapping of user address to their total staked tokens and tokens available for voting
    mapping(address => UserVoteLockData) internal voteLockData;

    /// @notice Mapping of user address to their future withdrawal amounts
    mapping(address => WithdrawalData) internal withdrawalData;

    /// @notice Mapping of address to their status as allowed voting contract
    mapping(address => VotingContractStatus) public allowedVotingContract;

    /// @notice Address of a new GearStaking contract that can be migrated to
    address public successor;

    /// @notice Address of the previous GearStaking contract that is migrated from
    address public migrator;

    constructor(address _addressProvider, uint256 _firstEpochTimestamp) ACLNonReentrantTrait(_addressProvider) {
        gear = IAddressProviderV3(_addressProvider).getAddressOrRevert(AP_GEAR_TOKEN, NO_VERSION_CONTROL); // U:[GS-01]
        firstEpochTimestamp = _firstEpochTimestamp; // U:[GS-01]
    }

    /// @dev Reverts on the function being called by non-migrator
    modifier migratorOnly() {
        if (msg.sender != migrator) revert CallerNotMigratorException();
        _;
    }

    /// @notice Deposits an amount of GEAR into staked GEAR. Optionally, performs a sequence of vote changes according to
    ///         the passed `votes` array
    /// @param amount Amount of GEAR to deposit into staked GEAR
    /// @param votes Array of MultVote structs:
    ///              * votingContract - contract to submit a vote to
    ///              * voteAmount - amount of staked GEAR to add to or remove from a vote
    ///              * isIncrease - whether to add or remove votes
    ///              * extraData - data specific to the voting contract that is decoded on recipient side
    function deposit(uint96 amount, MultiVote[] calldata votes) external nonReentrant {
        _deposit(amount, msg.sender, votes); // U: [GS-02]
    }

    /// @dev Internal implementation for deposits. Used in `deposit` and `depositOnMigration`
    function _deposit(uint96 amount, address to, MultiVote[] calldata votes) internal {
        IERC20(gear).safeTransferFrom(msg.sender, address(this), amount);

        UserVoteLockData storage vld = voteLockData[to];

        vld.totalStaked += amount;
        vld.available += amount;

        emit DepositGear(to, amount);

        _multivote(to, votes);
    }

    /// @notice Performs a sequence of vote changes according to the passed array
    /// @param votes Array of MultVote structs:
    ///              * votingContract - contract to submit a vote to
    ///              * voteAmount - amount of staked GEAR to add to or remove from a vote
    ///              * isIncrease - whether to add or remove votes
    ///              * extraData - data specific to the voting contract that is decoded on recipient side
    function multivote(MultiVote[] calldata votes) external nonReentrant {
        _multivote(msg.sender, votes); // U: [GS-04]
    }

    /// @notice Schedules a withdrawal from staked GEAR into GEAR, which can be claimed in 4 epochs.
    ///         If there are any withdrawals available to claim, they are also claimed.
    ///         Optionally, performs a sequence of vote changes according to
    ///         the passed `votes` array.
    /// @param amount Amount of staked GEAR to withdraw into GEAR
    /// @param to Address to send claimable GEAR, if any
    /// @param votes Array of MultVote structs:
    ///              * votingContract - contract to submit a vote to
    ///              * voteAmount - amount of staked GEAR to add to or remove from a vote
    ///              * isIncrease - whether to add or remove votes
    ///              * extraData - data specific to the voting contract that is decoded on recipient side
    function withdraw(uint96 amount, address to, MultiVote[] calldata votes) external nonReentrant {
        _multivote(msg.sender, votes); // U: [GS-03]

        _processPendingWithdrawals(msg.sender, to);

        voteLockData[msg.sender].available -= amount; // U: [GS-03]
        withdrawalData[msg.sender].withdrawalsPerEpoch[EPOCHS_TO_WITHDRAW - 1] += amount; // U: [GS-03]

        emit ScheduleGearWithdrawal(msg.sender, amount); // U: [GS-03]
    }

    /// @notice Claims all of the caller's withdrawals that are mature
    /// @param to Address to send claimable GEAR, if any
    function claimWithdrawals(address to) external nonReentrant {
        _processPendingWithdrawals(msg.sender, to); // U: [GS-05]
    }

    /// @notice Migrates the user's staked GEAR to a `successor` GearStaking contract without waiting for the withdrawal delay
    /// @dev Assumes that this contract is set as `migrator` in the successor contract, otherwise this would revert
    /// @param amount Amount of staked GEAR to migrate
    /// @param votesBefore Votes to apply before sending GEAR to the successor contract
    /// @param votesAfter Votes to apply in the new contract after sending GEAR
    function migrate(uint96 amount, MultiVote[] calldata votesBefore, MultiVote[] calldata votesAfter)
        external
        override
        nonReentrant
        nonZeroAddress(successor) // U: [GS-07]
    {
        _multivote(msg.sender, votesBefore); // U: [GS-07]

        UserVoteLockData storage vld = voteLockData[msg.sender];

        vld.available -= amount; // U: [GS-07]
        vld.totalStaked -= amount; // U: [GS-07]

        IERC20(gear).approve(successor, uint256(amount));
        IGearStakingV3(successor).depositOnMigration(amount, msg.sender, votesAfter); // U: [GS-07]

        emit MigrateGear(msg.sender, successor, amount); // U: [GS-07]
    }

    /// @notice Performs a deposit on user's behalf from the migrator (usually the previous GearStaking contract)
    /// @param amount Amount of GEAR to deposit
    /// @param onBehalfOf User on whose behalf to deposit
    /// @param votes Array of votes to apply after migrating
    function depositOnMigration(uint96 amount, address onBehalfOf, MultiVote[] calldata votes)
        external
        override
        nonReentrant
        migratorOnly // U: [GS-07]
    {
        _deposit(amount, onBehalfOf, votes); // U: [GS-07]
    }

    /// @notice Refreshes the user's withdrawal struct, shifting the withdrawal amounts based
    ///         on the number of epochs that passed since the last update. If there are any mature withdrawals,
    ///         sends the corresponding amounts to the user
    function _processPendingWithdrawals(address user, address to) internal {
        uint16 epochNow = getCurrentEpoch();

        WithdrawalData memory wd = withdrawalData[user];

        if (epochNow > wd.epochLastUpdate) {
            uint16 epochDiff = epochNow - wd.epochLastUpdate;
            uint256 totalClaimable;

            // Epochs one, two, three and four in the struct are always relative
            // to epochLastUpdate, so the amounts are "shifted" by the number of epochs that passed
            // since epochLastUpdate, on each update. If some amount shifts beyond epoch one, it is mature,
            // so GEAR is sent to the user.
            unchecked {
                for (uint256 i = 0; i < EPOCHS_TO_WITHDRAW; ++i) {
                    if (i < epochDiff) {
                        totalClaimable += wd.withdrawalsPerEpoch[i];
                    }

                    wd.withdrawalsPerEpoch[i] =
                        (i + epochDiff < EPOCHS_TO_WITHDRAW) ? wd.withdrawalsPerEpoch[i + epochDiff] : 0;
                }
            }

            if (totalClaimable != 0) {
                IERC20(gear).safeTransfer(to, totalClaimable);
                voteLockData[user].totalStaked -= totalClaimable.toUint96();

                emit ClaimGearWithdrawal(user, to, totalClaimable);
            }

            wd.epochLastUpdate = epochNow;
            withdrawalData[user] = wd;
        }
    }

    /// @dev Performs a sequence of vote changes based on the passed array
    function _multivote(address user, MultiVote[] calldata votes) internal {
        uint256 len = votes.length;
        if (len == 0) return;

        UserVoteLockData storage vld = voteLockData[user];

        for (uint256 i = 0; i < len;) {
            MultiVote calldata currentVote = votes[i];

            if (currentVote.isIncrease) {
                if (allowedVotingContract[currentVote.votingContract] != VotingContractStatus.ALLOWED) {
                    revert VotingContractNotAllowedException(); // U: [GS-04A]
                }

                IVotingContractV3(currentVote.votingContract).vote(user, currentVote.voteAmount, currentVote.extraData);
                vld.available -= currentVote.voteAmount;
            } else {
                if (allowedVotingContract[currentVote.votingContract] == VotingContractStatus.NOT_ALLOWED) {
                    revert VotingContractNotAllowedException(); // U: [GS-04A]
                }

                IVotingContractV3(currentVote.votingContract).unvote(
                    user, currentVote.voteAmount, currentVote.extraData
                );
                vld.available += currentVote.voteAmount;
            }

            unchecked {
                ++i;
            }
        }
    }

    //
    // GETTERS
    //

    /// @notice Returns the current global voting epoch
    function getCurrentEpoch() public view returns (uint16) {
        if (block.timestamp < firstEpochTimestamp) return 0; // U:[GS-01]
        unchecked {
            return uint16((block.timestamp - firstEpochTimestamp) / EPOCH_LENGTH) + 1; // U:[GS-01]
        }
    }

    /// @notice Returns the total amount of GEAR the user staked into staked GEAR
    function balanceOf(address user) external view returns (uint256) {
        return voteLockData[user].totalStaked;
    }

    /// @notice Returns the balance available for voting or withdrawal
    function availableBalance(address user) external view returns (uint256) {
        return voteLockData[user].available;
    }

    /// @notice Returns the amounts withdrawable now and over the next 4 epochs
    function getWithdrawableAmounts(address user)
        external
        view
        returns (uint256 withdrawableNow, uint256[EPOCHS_TO_WITHDRAW] memory withdrawableInEpochs)
    {
        WithdrawalData storage wd = withdrawalData[user];

        uint16 epochDiff = getCurrentEpoch() - wd.epochLastUpdate;
        unchecked {
            for (uint256 i = 0; i < EPOCHS_TO_WITHDRAW; ++i) {
                if (i < epochDiff) {
                    withdrawableNow += wd.withdrawalsPerEpoch[i];
                }

                withdrawableInEpochs[i] =
                    (i + epochDiff < EPOCHS_TO_WITHDRAW) ? wd.withdrawalsPerEpoch[i + epochDiff] : 0;
            }
        }
    }

    //
    // CONFIGURATION
    //

    /// @notice Sets the status of contract as an allowed voting contract
    /// @param votingContract Address to set the status for
    /// @param status The new status of the contract:
    ///               * NOT_ALLOWED - cannot vote or unvote
    ///               * ALLOWED - can both vote and unvote
    ///               * UNVOTE_ONLY - can only unvote
    function setVotingContractStatus(address votingContract, VotingContractStatus status) external configuratorOnly {
        if (status == allowedVotingContract[votingContract]) return;
        allowedVotingContract[votingContract] = status; // U: [GS-06]

        emit SetVotingContractStatus(votingContract, status); // U: [GS-06]
    }

    /// @notice Sets a new successor contract
    /// @dev Successor is a new GearStaking contract where staked GEAR can be migrated to without
    ///      waiting for the normal withdrawal delay. This is used to upgrade GearStaking contracts
    ///      when new functionality is added
    /// @param newSuccessor Address of the new successor contract
    function setSuccessor(address newSuccessor) external configuratorOnly {
        if (successor != newSuccessor) {
            successor = newSuccessor; // U: [GS-08]

            emit SetSuccessor(newSuccessor); // U: [GS-08]
        }
    }

    /// @notice Sets a new migrator contract
    /// @dev Migrator is a contract that can deposit GEAR on behalf of the user. This is usually set to the old GearStaking
    ///      contract when updating GearStaking, in order for users to carry over their staked GEAR without waiting for withdrawal delay
    /// @param newMigrator Address of the new successor contract
    function setMigrator(address newMigrator) external configuratorOnly {
        if (migrator != newMigrator) {
            migrator = newMigrator; // U: [GS-09]

            emit SetMigrator(newMigrator); // U: [GS-09]
        }
    }
}
