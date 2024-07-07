// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {IControlledTrait} from "./base/IControlledTrait.sol";
import {IRateKeeper} from "./base/IRateKeeper.sol";
import {IVotingContract} from "./base/IVotingContract.sol";

struct QuotaRateParams {
    uint16 minRate;
    uint16 maxRate;
    uint96 totalVotesLpSide;
    uint96 totalVotesCaSide;
}

struct UserTokenVotes {
    uint96 votesLpSide;
    uint96 votesCaSide;
}

/// @title Gauge V3 interface
interface IGaugeV3 is IControlledTrait, IVotingContract, IRateKeeper {
    // ------ //
    // EVENTS //
    // ------ //

    /// @notice Emitted when epoch is updated
    event UpdateEpoch(uint16 epochNow);

    /// @notice Emitted when a user submits a vote
    event Vote(address indexed user, address indexed token, uint96 votes, bool lpSide);

    /// @notice Emitted when a user removes a vote
    event Unvote(address indexed user, address indexed token, uint96 votes, bool lpSide);

    /// @notice Emitted when a new quota token is added to the gauge
    event AddQuotaToken(address indexed token, uint16 minRate, uint16 maxRate);

    /// @notice Emitted when quota interest rate parameters are changed
    event SetQuotaTokenParams(address indexed token, uint16 minRate, uint16 maxRate);

    /// @notice Emitted when the frozen epoch status changes
    event SetFrozenEpoch(bool status);

    // ------- //
    // GETTERS //
    // ------- //

    function voter() external view returns (address);

    function updateEpoch() external;

    function epochLastUpdate() external view returns (uint16);

    function getRates(address[] calldata tokens) external view override returns (uint16[] memory);

    function userTokenVotes(address user, address token) external view returns (UserTokenVotes memory);

    function quotaRateParams(address token) external view returns (QuotaRateParams memory);

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function epochFrozen() external view returns (bool);

    function setFrozenEpoch(bool status) external;

    function addQuotaToken(address token, uint16 minRate, uint16 maxRate) external;

    function changeQuotaMinRate(address token, uint16 minRate) external;

    function changeQuotaMaxRate(address token, uint16 maxRate) external;
}
