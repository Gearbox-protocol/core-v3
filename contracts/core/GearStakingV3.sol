// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IGearStakingV3, MultiVote, VotingContractStatus} from "../interfaces/IGearStakingV3.sol";
import {
    CallerNotMigratorException,
    IncompatibleSuccessorException,
    InsufficientBalanceException,
    VotingContractNotAllowedException
} from "../interfaces/IExceptions.sol";
import {IVotingContract} from "../interfaces/base/IVotingContract.sol";

import {EPOCHS_TO_WITHDRAW, EPOCH_LENGTH} from "../libraries/Constants.sol";

import {ReentrancyGuardTrait} from "../traits/ReentrancyGuardTrait.sol";
import {SanityCheckTrait} from "../traits/SanityCheckTrait.sol";

/// @dev Info on user's total stake and stake available for voting or withdrawals
struct UserVoteLockData {
    uint96 totalStaked;
    uint96 available;
}

/// @dev Info on user's withdrawable amounts in each epoch
struct WithdrawalData {
    uint96[EPOCHS_TO_WITHDRAW] withdrawalsPerEpoch;
    uint16 epochLastUpdate;
}

/// @title Gear staking V3
contract GearStakingV3 is IGearStakingV3, Ownable, ReentrancyGuardTrait, SanityCheckTrait {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Address of the GEAR token
    address public immutable override gear;

    /// @notice Timestamp of the first epoch of voting
    uint256 public immutable override firstEpochTimestamp;

    /// @dev Mapping from user to their stake amount and tokens available for voting
    mapping(address => UserVoteLockData) internal _voteLockData;

    /// @dev Mapping from user to their future withdrawal amounts
    mapping(address => WithdrawalData) internal _withdrawalData;

    /// @notice Mapping from address to its status as allowed voting contract
    mapping(address => VotingContractStatus) public override allowedVotingContract;

    /// @notice Address of the new staking contract that can be migrated to
    address public override successor;

    /// @notice Address of the previous staking contract that is migrated from
    address public override migrator;

    /// @dev Ensures that function is called by migrator
    modifier migratorOnly() {
        if (msg.sender != migrator) revert CallerNotMigratorException();
        _;
    }

    /// @notice Constructor
    /// @param  owner_ Contract owner
    /// @param  gear_ GEAR token address
    /// @param  firstEpochTimestamp_ Timestamp at which the first epoch should start.
    ///         Setting this too far into the future poses a risk of locking user deposits.
    /// @custom:tests U:[GS-1]
    constructor(address owner_, address gear_, uint256 firstEpochTimestamp_) {
        gear = gear_;
        firstEpochTimestamp = firstEpochTimestamp_;
        transferOwnership(owner_);
    }

    /// @notice Stakes given amount of GEAR, and, optionally, performs a sequence of votes
    /// @param  amount Amount of GEAR to stake
    /// @param  votes Sequence of votes to perform, see `multivote`
    /// @dev    Requires approval from `msg.sender` for GEAR to this contract
    /// @custom:tests U:[GS-2]
    function deposit(uint96 amount, MultiVote[] calldata votes) external override nonReentrant {
        _deposit(amount, msg.sender);
        _multivote(msg.sender, votes);
    }

    /// @notice Same as `deposit` but uses signed EIP-2612 permit message
    /// @param  amount Amount of GEAR to stake
    /// @param  votes Sequence of votes to perform, see `multivote`
    /// @param  deadline Permit deadline
    /// @dev    `v`, `r`, `s` must be a valid signature of the permit message from `msg.sender` for GEAR to this contract
    /// @custom:tests U:[GS-2]
    function depositWithPermit(
        uint96 amount,
        MultiVote[] calldata votes,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override nonReentrant {
        try IERC20Permit(gear).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        _deposit(amount, msg.sender);
        _multivote(msg.sender, votes);
    }

    /// @notice Performs a sequence of votes
    /// @param  votes Sequence of votes to perform, see `MultiVote`
    /// @dev    Reverts if `votes` contains voting contracts that are not allowed for voting/unvoting
    /// @dev    Reverts if at any point user's available stake is insufficient to cast a vote
    /// @custom:expects Voting contract correctly performs votes accounting and does not allow user to uncast more votes
    ///         than they've previously casted
    /// @custom:tests U:[GS-4], U:[GS-4A]
    function multivote(MultiVote[] calldata votes) external override nonReentrant {
        _multivote(msg.sender, votes);
    }

    /// @notice Unstakes GEAR and schedules withdrawal which can be claimed in 4 epochs.
    ///         Prior to this, claims available withdrawals and optionally performs a sequence of votes.
    /// @param  amount Amount of GEAR to unstake
    /// @param  to Address to send claimable GEAR, if any
    /// @param  votes Sequence of votes to perform, see `multivote`
    /// @dev    Reverts if caller's available stake is less than `amount`
    /// @custom:tests U:[GS-3]
    function withdraw(uint96 amount, address to, MultiVote[] calldata votes) external override nonReentrant {
        _multivote(msg.sender, votes);

        // after this, user's `epochLastUpdate` always equals current epoch
        _processPendingWithdrawals(msg.sender, to);

        UserVoteLockData storage vld = _voteLockData[msg.sender];
        if (vld.available < amount) revert InsufficientBalanceException();
        unchecked {
            vld.available -= amount;
        }

        _withdrawalData[msg.sender].withdrawalsPerEpoch[EPOCHS_TO_WITHDRAW - 1] += amount;

        emit ScheduleGearWithdrawal(msg.sender, amount);
    }

    /// @notice Claims all caller's mature withdrawals
    /// @param  to Address to send claimable GEAR, if any
    /// @custom:tests U:[GS-5]
    function claimWithdrawals(address to) external override nonReentrant {
        _processPendingWithdrawals(msg.sender, to);
    }

    /// @notice Migrates the user's staked GEAR to a successor staking contract, bypassing the withdrawal delay
    /// @param  amount Amount of staked GEAR to migrate
    /// @param  votesBefore Votes to apply before sending GEAR to the successor contract
    /// @param  votesBefore Sequence of votes to perform in this contract before sending GEAR to the successor
    /// @param  votesAfter Sequence of votes to perform in the successor contract after sending GEAR
    /// @dev    Reverts if caller's available stake is less than `amount`
    /// @dev    Reverts if successor contract is not set
    /// @custom:tests U:[GS-7]
    function migrate(uint96 amount, MultiVote[] calldata votesBefore, MultiVote[] calldata votesAfter)
        external
        override
        nonReentrant
        nonZeroAddress(successor)
    {
        _multivote(msg.sender, votesBefore);

        UserVoteLockData storage vld = _voteLockData[msg.sender];
        if (vld.available < amount) revert InsufficientBalanceException();
        unchecked {
            vld.available -= amount;
            vld.totalStaked -= amount;
        }

        IERC20(gear).approve(successor, uint256(amount));
        IGearStakingV3(successor).depositOnMigration(amount, msg.sender, votesAfter);

        emit MigrateGear(msg.sender, successor, amount);
    }

    /// @notice Performs a deposit on user's behalf from the migrator (usually the previous staking contract)
    /// @param  amount Amount of GEAR to deposit
    /// @param  onBehalfOf User on whose behalf to deposit
    /// @param  votes Sequence of votes to perform after migration, see `MultiVote`
    /// @dev    Reverts if caller is not migrator
    /// @custom:tests [U:GS-7]
    function depositOnMigration(uint96 amount, address onBehalfOf, MultiVote[] calldata votes)
        external
        override
        nonReentrant
        migratorOnly
    {
        _deposit(amount, onBehalfOf);
        _multivote(onBehalfOf, votes);
    }

    /// @dev Implementation of `deposit`
    function _deposit(uint96 amount, address to) internal {
        IERC20(gear).safeTransferFrom(msg.sender, address(this), amount);

        UserVoteLockData storage vld = _voteLockData[to];
        vld.totalStaked += amount;
        vld.available += amount;

        emit DepositGear(to, amount);
    }

    /// @dev Refreshes the user's withdrawal struct, shifting the withdrawal amounts based on the number of epochs
    ///      that passed since the last update. If there are any mature withdrawals, sends them to the user.
    function _processPendingWithdrawals(address user, address to) internal {
        uint16 epochNow = getCurrentEpoch();
        if (epochNow == _withdrawalData[user].epochLastUpdate) return;

        WithdrawalData memory wd = _withdrawalData[user];

        uint16 epochDiff = epochNow - wd.epochLastUpdate;
        uint256 totalClaimable;

        // epochs in the struct are relative to `epochLastUpdate`, so the amounts are "shifted" by the number of epochs
        // that passed since then, and, if some amount shifts beyond epoch one, it becomes mature and is sent to user
        unchecked {
            for (uint256 i; i < EPOCHS_TO_WITHDRAW; ++i) {
                if (i < epochDiff) totalClaimable += wd.withdrawalsPerEpoch[i];

                wd.withdrawalsPerEpoch[i] =
                    (i + epochDiff < EPOCHS_TO_WITHDRAW) ? wd.withdrawalsPerEpoch[i + epochDiff] : 0;
            }
        }

        if (totalClaimable != 0) {
            IERC20(gear).safeTransfer(to, totalClaimable);
            _voteLockData[user].totalStaked -= totalClaimable.toUint96();
            emit ClaimGearWithdrawal(user, to, totalClaimable);
        }

        wd.epochLastUpdate = epochNow;
        _withdrawalData[user] = wd;
    }

    /// @dev Implementation of `multivote`
    function _multivote(address user, MultiVote[] calldata votes) internal {
        uint256 len = votes.length;
        if (len == 0) return;

        UserVoteLockData storage vld = _voteLockData[user];

        for (uint256 i; i < len; ++i) {
            MultiVote calldata currentVote = votes[i];

            if (currentVote.isIncrease) {
                if (allowedVotingContract[currentVote.votingContract] != VotingContractStatus.ALLOWED) {
                    revert VotingContractNotAllowedException();
                }

                if (vld.available < currentVote.voteAmount) revert InsufficientBalanceException();
                unchecked {
                    vld.available -= currentVote.voteAmount;
                }

                IVotingContract(currentVote.votingContract).vote(user, currentVote.voteAmount, currentVote.extraData);
            } else {
                if (allowedVotingContract[currentVote.votingContract] == VotingContractStatus.NOT_ALLOWED) {
                    revert VotingContractNotAllowedException();
                }

                IVotingContract(currentVote.votingContract).unvote(user, currentVote.voteAmount, currentVote.extraData);
                vld.available += currentVote.voteAmount;
            }
        }
    }

    /// @notice Returns the current global voting epoch
    function getCurrentEpoch() public view override returns (uint16) {
        if (block.timestamp < firstEpochTimestamp) return 0;
        unchecked {
            // cast is safe for the next millenium
            return uint16((block.timestamp - firstEpochTimestamp) / EPOCH_LENGTH) + 1;
        }
    }

    /// @notice Returns the total amount of user's staked GEAR
    function balanceOf(address user) external view override returns (uint256) {
        return _voteLockData[user].totalStaked;
    }

    /// @notice Returns user's balance available for voting or unstaking
    function availableBalance(address user) external view override returns (uint256) {
        return _voteLockData[user].available;
    }

    /// @notice Returns user's amounts withdrawable now and over the next 4 epochs
    function getWithdrawableAmounts(address user)
        external
        view
        override
        returns (uint256 withdrawableNow, uint256[EPOCHS_TO_WITHDRAW] memory withdrawableInEpochs)
    {
        WithdrawalData memory wd = _withdrawalData[user];

        uint16 epochDiff = getCurrentEpoch() - wd.epochLastUpdate;
        unchecked {
            for (uint256 i; i < EPOCHS_TO_WITHDRAW; ++i) {
                if (i < epochDiff) withdrawableNow += wd.withdrawalsPerEpoch[i];

                withdrawableInEpochs[i] =
                    (i + epochDiff < EPOCHS_TO_WITHDRAW) ? wd.withdrawalsPerEpoch[i + epochDiff] : 0;
            }
        }
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets the status of contract as an allowed voting contract
    /// @param  votingContract Address to set the status for
    /// @param  status The new status of the contract, see `VotingContractStatus`
    /// @dev    Reverts if caller is not owner
    /// @custom:tests U:[GS-6]
    function setVotingContractStatus(address votingContract, VotingContractStatus status) external override onlyOwner {
        if (status != allowedVotingContract[votingContract]) {
            allowedVotingContract[votingContract] = status;
            emit SetVotingContractStatus(votingContract, status);
        }
    }

    /// @notice Sets a new successor contract.
    ///         Successor is a new staking contract where staked GEAR can be migrated, bypassing the withdrawal delay.
    ///         This is used to upgrade staking contracts when new functionality is added.
    /// @param  newSuccessor Address of the new successor contract
    /// @dev    Reverts if caller is not owner
    /// @dev    Reverts if `newSuccessor` doesn't have this contract set as migrator
    /// @custom:tests U:[GS-8]
    function setSuccessor(address newSuccessor) external override onlyOwner {
        if (successor != newSuccessor) {
            if (IGearStakingV3(newSuccessor).migrator() != address(this)) revert IncompatibleSuccessorException();
            successor = newSuccessor;
            emit SetSuccessor(newSuccessor);
        }
    }

    /// @notice Sets a new migrator contract.
    ///         Migrator is a contract (usually the previous staking contract) that can deposit GEAR on behalf of users
    ///         during migration in order for them to move their staked GEAR, bypassing the withdrawal delay.
    /// @param  newMigrator Address of the new migrator contract
    /// @dev    Reverts if caller is not owner
    /// @custom:tests U:[GS-9]
    function setMigrator(address newMigrator) external override onlyOwner {
        if (migrator != newMigrator) {
            migrator = newMigrator;
            emit SetMigrator(newMigrator);
        }
    }
}
