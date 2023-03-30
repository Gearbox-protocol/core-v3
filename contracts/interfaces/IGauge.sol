// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {IGearStaking} from "./IGearStaking.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

struct QuotaRateParams {
    uint16 minRiskRate;
    uint16 maxRate;
    uint96 totalVotesLpSide;
    uint96 totalVotesCaSide;
}

struct UserVotes {
    uint96 votesLpSide;
    uint96 votesCaSide;
}

interface IGaugeEvents {
    /// @dev Emits when a user submits a vote
    event VoteFor(address indexed user, address indexed token, uint96 votes, bool lpSide);

    /// @dev Emits when a user removes a vote
    event UnvoteFrom(address indexed user, address indexed token, uint96 votes, bool lpSide);

    /// @dev Emits when the Voter contract is changed
    event VoterUpdated(address indexed newVoter);

    /// @dev Emits when a new quota token is added in the PoolQuotaKeeper
    event QuotaTokenAdded(address indexed token, uint16 minRate, uint16 maxRate);

    /// @dev Emits when quota interest rate parameters are changed
    event QuotaParametersChanged(address indexed token, uint16 minRate, uint16 maxRate);
}

/// @title IGauge

interface IGauge is IGaugeEvents, IVersion {
    /// @dev Returns the main voting contract
    function voter() external view returns (IGearStaking);

    /// @dev Rolls the new epoch and updates all quota rates
    function updateEpoch() external;

    /// @dev Submits a vote to move the quota rate for a token
    /// @param user The user that submitted a vote
    /// @param votes Amount of staked GEAR the user voted with
    /// @param extraData Gauge specific parameters (encoded into extraData to adhere to a general VotingContract interface)
    ///                  * token - address of the token to vote for
    ///                  * lpSide - votes in favor of LPs (increasing rate) if true, or in favor of CAs (decreasing rate) if false
    function vote(address user, uint96 votes, bytes memory extraData) external;

    /// @dev Removes the user's existing vote from the provided token and side
    /// @param user The user that submitted a vote
    /// @param votes Amount of staked GEAR to remove
    /// @param extraData Gauge specific parameters (encoded into extraData to adhere to a general VotingContract interface)
    ///                  * token - address of the token to unvote from
    ///                  * lpSide - whether the side unvoted from is LP side
    function unvote(address user, uint96 votes, bytes memory extraData) external;

    //
    // GETTERS
    //
    function getRates(address[] memory tokens) external view returns (uint16[] memory rates);
}
