// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
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

/// @title Gear staking V3
contract GearStakingV3 is ACLNonReentrantTrait, IGearStakingV3 {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice Address of the GEAR token
    address public immutable override gear;

    /// @notice Timestamp of the first epoch of voting
    uint256 public immutable override firstEpochTimestamp;

    /// @dev Mapping from user to their stake amount and tokens available for voting
    mapping(address => UserVoteLockData) internal voteLockData;

    /// @dev Mapping from user to their future withdrawal amounts
    mapping(address => WithdrawalData) internal withdrawalData;

    /// @notice Mapping from address to its status as allowed voting contract
    mapping(address => VotingContractStatus) public allowedVotingContract;

    /// @notice Address of a new staking contract that can be migrated to
    address public override successor;

    /// @notice Address of the previous staking contract that is migrated from
    address public override migrator;

    constructor(address _addressProvider, uint256 _firstEpochTimestamp) ACLNonReentrantTrait(_addressProvider) {
        gear = IAddressProviderV3(_addressProvider).getAddressOrRevert(AP_GEAR_TOKEN, NO_VERSION_CONTROL); // U:[GS-01]
        firstEpochTimestamp = _firstEpochTimestamp; // U:[GS-01]
    }

    /// @dev Ensures that function is called by migrator
    modifier migratorOnly() {
        if (msg.sender != migrator) revert CallerNotMigratorException();
        _;
    }

    /// @notice Stakes given amount of GEAR, and, optionally, performs a sequence of votes
    /// @param amount Amount of GEAR to stake
    /// @param votes Sequence of votes to perform, see `MultiVote`
    /// @dev Requires approval from `msg.sender` for GEAR to this contract
    function deposit(uint96 amount, MultiVote[] calldata votes) external override nonReentrant {
        _deposit(amount, msg.sender, votes); // U: [GS-02]
    }

    /// @notice Same as `deposit` but uses signed EIP-2612 permit message
    /// @param amount Amount of GEAR to stake
    /// @param votes Sequence of votes to perform, see `MultiVote`
    /// @param deadline Permit deadline
    /// @dev `v`, `r`, `s` must be a valid signature of the permit message from `msg.sender` for GEAR to this contract
    function depositWithPermit(
        uint96 amount,
        MultiVote[] calldata votes,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override nonReentrant {
        try IERC20Permit(gear).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {} // U:[GS-02]
        _deposit(amount, msg.sender, votes); // U:[GS-02]
    }

    /// @dev Implementation of `deposit`
    function _deposit(uint96 amount, address to, MultiVote[] calldata votes) internal {
        IERC20(gear).safeTransferFrom(msg.sender, address(this), amount);

        UserVoteLockData storage vld = voteLockData[to];

        vld.totalStaked += amount;
        vld.available += amount;

        emit DepositGear(to, amount);

        _multivote(to, votes);
    }

    /// @notice Performs a sequence of votes
    /// @param votes Sequence of votes to perform, see `MultiVote`
    function multivote(MultiVote[] calldata votes) external override nonReentrant {
        _multivote(msg.sender, votes); // U: [GS-04]
    }

    /// @notice Unstakes GEAR and schedules withdrawal which can be claimed in 4 epochs, claims available withdrawals,
    ///         and, optionally, performs a sequence of votes.
    /// @param amount Amount of GEAR to unstake
    /// @param to Address to send claimable GEAR, if any
    /// @param votes Sequence of votes to perform, see `MultiVote`
    function withdraw(uint96 amount, address to, MultiVote[] calldata votes) external override nonReentrant {
        _multivote(msg.sender, votes); // U: [GS-03]

        _processPendingWithdrawals(msg.sender, to);

        UserVoteLockData storage vld = voteLockData[msg.sender];

        if (vld.available < amount) revert InsufficientBalanceException();
        unchecked {
            vld.available -= amount; // U: [GS-03]
        }

        withdrawalData[msg.sender].withdrawalsPerEpoch[EPOCHS_TO_WITHDRAW - 1] += amount; // U: [GS-03]

        emit ScheduleGearWithdrawal(msg.sender, amount); // U: [GS-03]
    }

    /// @notice Claims all caller's mature withdrawals
    /// @param to Address to send claimable GEAR, if any
    function claimWithdrawals(address to) external override nonReentrant {
        _processPendingWithdrawals(msg.sender, to); // U: [GS-05]
    }

    /// @notice Migrates the user's staked GEAR to a successor staking contract, bypassing the withdrawal delay
    /// @param amount Amount of staked GEAR to migrate
    /// @param votesBefore Votes to apply before sending GEAR to the successor contract
    /// @param votesBefore Sequence of votes to perform in this contract before sending GEAR to the successor
    /// @param votesAfter Sequence of votes to perform in the successor contract after sending GEAR
    function migrate(uint96 amount, MultiVote[] calldata votesBefore, MultiVote[] calldata votesAfter)
        external
        override
        nonReentrant
        nonZeroAddress(successor) // U: [GS-07]
    {
        _multivote(msg.sender, votesBefore); // U: [GS-07]

        UserVoteLockData storage vld = voteLockData[msg.sender];

        if (vld.available < amount) revert InsufficientBalanceException();
        unchecked {
            vld.available -= amount; // U: [GS-07]
            vld.totalStaked -= amount; // U: [GS-07]
        }

        IERC20(gear).approve(successor, uint256(amount));
        IGearStakingV3(successor).depositOnMigration(amount, msg.sender, votesAfter); // U: [GS-07]

        emit MigrateGear(msg.sender, successor, amount); // U: [GS-07]
    }

    /// @notice Performs a deposit on user's behalf from the migrator (usually the previous staking contract)
    /// @param amount Amount of GEAR to deposit
    /// @param onBehalfOf User on whose behalf to deposit
    /// @param votes Sequence of votes to perform after migration, see `MultiVote`
    function depositOnMigration(uint96 amount, address onBehalfOf, MultiVote[] calldata votes)
        external
        override
        nonReentrant
        migratorOnly // U: [GS-07]
    {
        _deposit(amount, onBehalfOf, votes); // U: [GS-07]
    }

    /// @dev Refreshes the user's withdrawal struct, shifting the withdrawal amounts based on the number of epochs
    ///      that passed since the last update. If there are any mature withdrawals, sends them to the user.
    function _processPendingWithdrawals(address user, address to) internal {
        uint16 epochNow = getCurrentEpoch();

        if (epochNow > withdrawalData[user].epochLastUpdate) {
            WithdrawalData memory wd = withdrawalData[user];

            uint16 epochDiff = epochNow - wd.epochLastUpdate;
            uint256 totalClaimable;

            // Epochs one, two, three and four in the struct are always relative to epochLastUpdate, so the amounts
            // are "shifted" by the number of epochs that passed since then. If some amount shifts beyond epoch one,
            // it becomes mature and the GEAR is sent to the user.
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

    /// @dev Implementation of `multivote`
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

                if (vld.available < currentVote.voteAmount) revert InsufficientBalanceException();
                unchecked {
                    vld.available -= currentVote.voteAmount;
                }

                IVotingContractV3(currentVote.votingContract).vote(user, currentVote.voteAmount, currentVote.extraData);
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

    /// @notice Returns the current global voting epoch
    function getCurrentEpoch() public view override returns (uint16) {
        if (block.timestamp < firstEpochTimestamp) return 0; // U:[GS-01]
        unchecked {
            return uint16((block.timestamp - firstEpochTimestamp) / EPOCH_LENGTH) + 1; // U:[GS-01]
        }
    }

    /// @notice Returns the total amount of user's staked GEAR
    function balanceOf(address user) external view override returns (uint256) {
        return voteLockData[user].totalStaked;
    }

    /// @notice Returns user's balance available for voting or unstaking
    function availableBalance(address user) external view override returns (uint256) {
        return voteLockData[user].available;
    }

    /// @notice Returns user's amounts withdrawable now and over the next 4 epochs
    function getWithdrawableAmounts(address user)
        external
        view
        override
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

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets the status of contract as an allowed voting contract
    /// @param votingContract Address to set the status for
    /// @param status The new status of the contract, see `VotingContractStatus`
    function setVotingContractStatus(address votingContract, VotingContractStatus status)
        external
        override
        configuratorOnly
    {
        if (status == allowedVotingContract[votingContract]) return;
        allowedVotingContract[votingContract] = status; // U: [GS-06]

        emit SetVotingContractStatus(votingContract, status); // U: [GS-06]
    }

    /// @notice Sets a new successor contract
    /// @dev Successor is a new staking contract where staked GEAR can be migrated, bypassing the withdrawal delay.
    ///      This is used to upgrade staking contracts when new functionality is added.
    ///      It must already have this contract set as migrator.
    /// @param newSuccessor Address of the new successor contract
    function setSuccessor(address newSuccessor) external override configuratorOnly {
        if (successor != newSuccessor) {
            if (IGearStakingV3(newSuccessor).migrator() != address(this)) {
                revert IncompatibleSuccessorException(); // U: [GS-08]
            }
            successor = newSuccessor; // U: [GS-08]

            emit SetSuccessor(newSuccessor); // U: [GS-08]
        }
    }

    /// @notice Sets a new migrator contract
    /// @dev Migrator is a contract (usually the previous staking contract) that can deposit GEAR on behalf of users
    ///      during migration in order for them to move their staked GEAR, bypassing the withdrawal delay.
    /// @param newMigrator Address of the new migrator contract
    function setMigrator(address newMigrator) external override configuratorOnly {
        if (migrator != newMigrator) {
            migrator = newMigrator; // U: [GS-09]

            emit SetMigrator(newMigrator); // U: [GS-09]
        }
    }
}
