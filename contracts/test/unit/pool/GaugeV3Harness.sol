// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.23;

// INTERFACES
import {GaugeV3, QuotaRateParams, UserTokenVotes} from "../../../pool/GaugeV3.sol";

contract GaugeV3Harness is GaugeV3 {
    constructor(address acl, address _pool, address _gearStaking) GaugeV3(acl, _pool, _gearStaking) {}

    function setQuotaRateParams(
        address token,
        uint16 minRate,
        uint16 maxRate,
        uint96 totalVotesLpSide,
        uint96 totalVotesCaSide
    ) external {
        _quotaRateParams[token] = QuotaRateParams({
            minRate: minRate,
            maxRate: maxRate,
            totalVotesLpSide: totalVotesLpSide,
            totalVotesCaSide: totalVotesCaSide
        });
    }

    function setUserTokenVotes(address user, address token, uint96 votesLpSide, uint96 votesCaSide) external {
        _userTokenVotes[user][token] = UserTokenVotes({votesLpSide: votesLpSide, votesCaSide: votesCaSide});
    }
}
