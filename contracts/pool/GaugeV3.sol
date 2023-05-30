// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;
pragma abicoder v1;

// INTERFACES
import {IGaugeV3, QuotaRateParams, UserVotes} from "../interfaces/IGaugeV3.sol";
import {IVotingContractV3} from "../interfaces/IVotingContractV3.sol";
import {IGearStakingV3} from "../interfaces/IGearStakingV3.sol";
import {IPoolQuotaKeeperV3} from "../interfaces/IPoolQuotaKeeperV3.sol";
import {IPoolV3} from "../interfaces/IPoolV3.sol";

// TRAITS
import {ACLTrait} from "../traits/ACLTrait.sol";

// EXCEPTIONS
import {
    CallerNotVoterException,
    IncorrectParameterException,
    TokenNotAllowedException
} from "../interfaces/IExceptions.sol";

/// @title Gauge for quota interest rates
/// @dev Quota interest rates in Gearbox V3 are determined
///      by GEAR holders voting to shift the rate within a predetermined
///      interval. While there are notable mechanic differences, the overall
///      dynamic of token holders controlling strategy yields is similar to
///      Curve's gauge system, and thus the contract carries the same name
contract GaugeV3 is IGaugeV3, IVotingContractV3, ACLTrait {
    /// @notice Contract version
    uint256 public constant version = 3_00;

    /// @notice Address of the address provider
    address public immutable addressProvider;

    /// @notice Address of the pool
    address public immutable override pool;

    /// @notice Mapping from token address to its rate parameters
    mapping(address => QuotaRateParams) public override quotaRateParams;

    /// @notice Mapping from (user, token) to vote amounts committed by user to each side
    mapping(address => mapping(address => UserVotes)) public override userTokenVotes;

    /// @notice GEAR locking and voting contract
    address public override voter;

    /// @notice Epoch when the rates were last recomputed
    uint16 public override epochLastUpdate;

    //
    // CONSTRUCTOR
    //

    /// @dev Constructor
    /// @param _pool Address of the borrowing pool
    /// @param _gearStaking Address of the GEAR staking contract
    constructor(address _pool, address _gearStaking)
        ACLTrait(IPoolV3(_pool).addressProvider())
        nonZeroAddress(_pool)
        nonZeroAddress(_gearStaking)
    {
        addressProvider = IPoolV3(_pool).addressProvider(); // F:[P4-01]
        pool = _pool; // F:[P4-01]
        voter = _gearStaking;
        epochLastUpdate = IGearStakingV3(voter).getCurrentEpoch();
    }

    /// @dev Reverts if the function is called by an address other than the voter
    modifier onlyVoter() {
        if (msg.sender != voter) {
            revert CallerNotVoterException();
        }
        _;
    }

    /// @notice Rolls the new epoch and updates all quota rates
    function updateEpoch() external {
        _checkAndUpdateEpoch();
    }

    /// @dev IMPLEMENTATION: updateEpoch()
    function _checkAndUpdateEpoch() internal {
        uint16 epochNow = IGearStakingV3(voter).getCurrentEpoch();

        if (epochNow > epochLastUpdate) {
            epochLastUpdate = epochNow;

            /// The PQK retrieves all rates from the Gauge on its own and saves them
            /// Since this function is only callable by the Gauge, active rates can only
            /// be updated once per epoch at most
            _poolQuotaKeeper().updateRates();

            emit UpdateEpoch(epochNow);
        }
    }

    /// @notice Computes rates for a set of tokens
    /// @dev While this will compute rates based on current votes,
    ///      the actual rates can differ, since they are only updates
    ///      once per epoch
    /// @param tokens Array of tokens to computes rates for
    /// @return rates Array of rates, in the same order as passed tokens
    function getRates(address[] calldata tokens) external view override returns (uint16[] memory rates) {
        uint256 len = tokens.length;
        rates = new uint16[](len);

        unchecked {
            for (uint256 i; i < len; ++i) {
                address token = tokens[i];

                if (!isTokenAdded(token)) revert TokenNotAllowedException();

                QuotaRateParams memory qrp = quotaRateParams[token];

                uint96 votesLpSide = qrp.totalVotesLpSide;
                uint96 votesCaSide = qrp.totalVotesCaSide;
                uint256 totalVotes = votesLpSide + votesCaSide;

                /// Quota interest rates are determined by GEAR holders through voting
                /// for one of two sides (for each token) - CA side or LP side.
                /// There are two parameters for each token determined by the governance -
                /// Min risk rate and max rate, and the actual rate fluctuates between
                /// those two extremes based on votes. Voting for CA side reduces the rate
                /// towards minRate, while voting for LP side increases it towards maxRate.
                /// Rates are only updated once per epoch (1 week), to avoid manipulation and
                /// make strategies more predictable.

                rates[i] = totalVotes == 0
                    ? qrp.minRate
                    : uint16((uint256(qrp.minRate) * votesCaSide + uint256(qrp.maxRate) * votesLpSide) / totalVotes);
            }
        }
    }

    /// @notice Submits a vote to move the quota rate for a token
    /// @param user The user that submitted a vote
    /// @param votes Amount of staked GEAR the user voted with
    /// @param extraData Gauge specific parameters (encoded into extraData to adhere to a general VotingContract interface)
    ///                  * token - address of the token to vote for
    ///                  * lpSide - votes in favor of LPs (increasing rate) if true, or in favor of CAs (decreasing rate) if false
    function vote(address user, uint96 votes, bytes calldata extraData)
        external
        override(IGaugeV3, IVotingContractV3)
        onlyVoter
    {
        (address token, bool lpSide) = abi.decode(extraData, (address, bool));
        _vote({user: user, token: token, votes: votes, lpSide: lpSide});
    }

    /// @dev IMPLEMENTATION: vote
    /// @param user User to assign votes to
    /// @param votes Amount of votes to add
    /// @param token Token to add votes to
    /// @param lpSide Side to add votes to: `true` for LP side, `false` for CA side
    function _vote(address user, uint96 votes, address token, bool lpSide) internal {
        _checkAndUpdateEpoch();

        if (!isTokenAdded(token)) revert TokenNotAllowedException();

        QuotaRateParams storage qp = quotaRateParams[token];
        UserVotes storage uv = userTokenVotes[user][token];
        if (lpSide) {
            qp.totalVotesLpSide += votes;
            uv.votesLpSide += votes;
        } else {
            qp.totalVotesCaSide += votes;
            uv.votesCaSide += votes;
        }

        emit Vote({user: user, token: token, votes: votes, lpSide: lpSide});
    }

    /// @notice Removes the user's existing vote from the provided token and side
    /// @param user The user that submitted a vote
    /// @param votes Amount of staked GEAR to remove
    /// @param extraData Gauge specific parameters (encoded into extraData to adhere to a general VotingContract interface)
    ///                  * token - address of the token to unvote from
    ///                  * lpSide - whether the side unvoted from is LP side
    function unvote(address user, uint96 votes, bytes calldata extraData)
        external
        override(IGaugeV3, IVotingContractV3)
        onlyVoter
    {
        (address token, bool lpSide) = abi.decode(extraData, (address, bool));
        _unvote({user: user, token: token, votes: votes, lpSide: lpSide});
    }

    /// @dev IMPLEMENTATION: unvote
    /// @param user User to assign votes to
    /// @param votes Amount of votes to add
    /// @param token Token to remove votes from
    /// @param lpSide Side to remove votes from: `true` for LP side, `false` for CA side
    function _unvote(address user, uint96 votes, address token, bool lpSide) internal {
        _checkAndUpdateEpoch();

        if (!isTokenAdded(token)) revert TokenNotAllowedException();

        QuotaRateParams storage qp = quotaRateParams[token];
        UserVotes storage uv = userTokenVotes[user][token];

        if (lpSide) {
            qp.totalVotesLpSide -= votes;
            uv.votesLpSide -= votes;
        } else {
            qp.totalVotesCaSide -= votes;
            uv.votesCaSide -= votes;
        }

        emit Unvote({user: user, token: token, votes: votes, lpSide: lpSide});
    }

    //
    // CONFIGURATION
    //

    /// @notice Sets the GEAR staking contract, which is the only entity allowed to vote/unvote directly
    /// @param newVoter The new voter contract
    function setVoter(address newVoter) external nonZeroAddress(newVoter) configuratorOnly {
        voter = newVoter;

        emit SetVoter({newVoter: newVoter});
    }

    /// @dev Adds a new quoted token to the Gauge and PoolQuotaKeeper, and sets the initial rate params
    /// @param token Address of the token to add
    /// @param minRate The minimal interest rate paid on token's quotas
    /// @param maxRate The maximal interest rate paid on token's quotas
    function addQuotaToken(address token, uint16 minRate, uint16 maxRate) external configuratorOnly {
        _checkParams({minRate: minRate, maxRate: maxRate});

        quotaRateParams[token] =
            QuotaRateParams({minRate: minRate, maxRate: maxRate, totalVotesLpSide: 0, totalVotesCaSide: 0});

        _poolQuotaKeeper().addQuotaToken({token: token});

        emit AddQuotaToken({token: token, minRate: minRate, maxRate: maxRate});
    }

    /// @dev Changes the rate params for a quoted token
    /// @param minRate The minimal interest rate paid on token's quotas
    /// @param maxRate The maximal interest rate paid on token's quotas
    function changeQuotaTokenRateParams(address token, uint16 minRate, uint16 maxRate)
        external
        nonZeroAddress(token)
        configuratorOnly
    {
        _checkParams(minRate, maxRate);

        QuotaRateParams storage qrp = quotaRateParams[token];
        qrp.minRate = minRate;
        qrp.maxRate = maxRate;

        emit SetQuotaTokenParams({token: token, minRate: minRate, maxRate: maxRate});
    }

    function _checkParams(uint16 minRate, uint16 maxRate) internal pure {
        if (minRate == 0 || minRate > maxRate) {
            revert IncorrectParameterException();
        }
    }

    function isTokenAdded(address token) public view returns (bool) {
        return quotaRateParams[token].minRate != 0;
    }

    /// @dev Returns quota keeper connected to the pool
    function _poolQuotaKeeper() private view returns (IPoolQuotaKeeperV3) {
        return IPoolQuotaKeeperV3(IPoolV3(pool).poolQuotaKeeper());
    }
}
