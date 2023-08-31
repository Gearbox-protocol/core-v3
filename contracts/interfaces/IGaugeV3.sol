// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

import {IVotingContractV3} from "./IVotingContractV3.sol";

struct QuotaRateParams {
    uint16 minRate;
    uint16 maxRate;
    uint96 totalVotesLpSide;
    uint96 totalVotesCaSide;
}

struct UserVotes {
    uint96 votesLpSide;
    uint96 votesCaSide;
}

interface IGaugeV3Events {
    /// @notice Emitted when epoch is updated
    event UpdateEpoch(uint16 epochNow);

    /// @notice Emitted when a user submits a vote
    event Vote(address indexed user, address indexed token, uint96 votes, bool lpSide);

    /// @notice Emitted when a user removes a vote
    event Unvote(address indexed user, address indexed token, uint96 votes, bool lpSide);

    /// @notice Emitted when a new quota token is added in the PoolQuotaKeeper
    event AddQuotaToken(address indexed token, uint16 minRate, uint16 maxRate);

    /// @notice Emitted when quota interest rate parameters are changed
    event SetQuotaTokenParams(address indexed token, uint16 minRate, uint16 maxRate);

    /// @notice Emitted when the frozen epoch status changes
    event SetFrozenEpoch(bool status);
}

/// @title Gauge V3 interface
interface IGaugeV3 is IGaugeV3Events, IVotingContractV3, IVersion {
    function pool() external view returns (address);

    function voter() external view returns (address);

    function updateEpoch() external;

    function epochLastUpdate() external view returns (uint16);

    function getRates(address[] calldata tokens) external view returns (uint16[] memory rates);

    function userTokenVotes(address user, address token)
        external
        view
        returns (uint96 votesLpSide, uint96 votesCaSide);

    function quotaRateParams(address token)
        external
        view
        returns (uint16 minRate, uint16 maxRate, uint96 totalVotesLpSide, uint96 totalVotesCaSide);

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function epochFrozen() external view returns (bool);

    function setFrozenEpoch(bool status) external;

    function isTokenAdded(address token) external view returns (bool);

    function addQuotaToken(address token, uint16 minRate, uint16 maxRate) external;

    function changeQuotaMinRate(address token, uint16 minRate) external;

    function changeQuotaMaxRate(address token, uint16 maxRate) external;
}
