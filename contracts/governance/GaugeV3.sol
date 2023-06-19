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
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";

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
contract GaugeV3 is IGaugeV3, IVotingContractV3, ACLNonReentrantTrait {
    /// @notice Contract version
    uint256 public constant version = 3_00;

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
        ACLNonReentrantTrait(IPoolV3(_pool).addressProvider())
        nonZeroAddress(_gearStaking) // U:[GA-01]
    {
        pool = _pool; // U:[GA-01]
        voter = _gearStaking; // U:[GA-01]
        epochLastUpdate = IGearStakingV3(voter).getCurrentEpoch(); // U:[GA-01]
    }

    /// @dev Reverts if the function is called by an address other than the voter
    modifier onlyVoter() {
        _revertIfCallerNotVoter(); // U:[GA-02]
        _;
    }

    /// @notice Rolls the new epoch and updates all quota rates
    function updateEpoch() external {
        _checkAndUpdateEpoch(); // U:[GA-14]
    }

    /// @dev IMPLEMENTATION: updateEpoch()
    function _checkAndUpdateEpoch() internal {
        uint16 epochNow = IGearStakingV3(voter).getCurrentEpoch(); // U:[GA-14]

        if (epochNow > epochLastUpdate) {
            epochLastUpdate = epochNow; // U:[GA-14]

            /// The PQK retrieves all rates from the Gauge on its own and saves them
            /// Since this function is only callable by the Gauge, active rates can only
            /// be updated once per epoch at most
            _poolQuotaKeeper().updateRates(); // U:[GA-14]

            emit UpdateEpoch(epochNow); // U:[GA-14]
        }
    }

    /// @notice Computes rates for a set of tokens
    /// @dev While this will compute rates based on current votes,
    ///      the actual rates can differ, since they are only updates
    ///      once per epoch
    /// @param tokens Array of tokens to computes rates for
    /// @return rates Array of rates, in the same order as passed tokens
    function getRates(address[] calldata tokens) external view override returns (uint16[] memory rates) {
        uint256 len = tokens.length; // U:[GA-15]
        rates = new uint16[](len); // U:[GA-15]

        unchecked {
            for (uint256 i; i < len; ++i) {
                address token = tokens[i]; // U:[GA-15]

                if (!isTokenAdded(token)) revert TokenNotAllowedException(); // U:[GA-15]

                QuotaRateParams memory qrp = quotaRateParams[token]; // U:[GA-15]

                uint96 votesLpSide = qrp.totalVotesLpSide; // U:[GA-15]
                uint96 votesCaSide = qrp.totalVotesCaSide; // U:[GA-15]
                uint256 totalVotes = votesLpSide + votesCaSide; // U:[GA-15]

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
                    : uint16((uint256(qrp.minRate) * votesCaSide + uint256(qrp.maxRate) * votesLpSide) / totalVotes); // U:[GA-15]
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
        onlyVoter // U:[GA-02]
    {
        (address token, bool lpSide) = abi.decode(extraData, (address, bool)); // U:[GA-10,11,12]
        _vote({user: user, token: token, votes: votes, lpSide: lpSide}); // U:[GA-10,11,12]
    }

    /// @dev IMPLEMENTATION: vote
    /// @param user User to assign votes to
    /// @param votes Amount of votes to add
    /// @param token Token to add votes to
    /// @param lpSide Side to add votes to: `true` for LP side, `false` for CA side
    function _vote(address user, uint96 votes, address token, bool lpSide) internal {
        if (!isTokenAdded(token)) revert TokenNotAllowedException(); // U:[GA-10]

        _checkAndUpdateEpoch(); // U:[GA-11]

        QuotaRateParams storage qp = quotaRateParams[token]; // U:[GA-12]
        UserVotes storage uv = userTokenVotes[user][token];

        if (lpSide) {
            qp.totalVotesLpSide += votes; // U:[GA-12]
            uv.votesLpSide += votes; // U:[GA-12]
        } else {
            qp.totalVotesCaSide += votes; // U:[GA-12]
            uv.votesCaSide += votes; // U:[GA-12]
        }

        emit Vote({user: user, token: token, votes: votes, lpSide: lpSide}); // U:[GA-12]
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
        onlyVoter // U:[GA-02]
    {
        (address token, bool lpSide) = abi.decode(extraData, (address, bool)); // U:[GA-10,11,13]
        _unvote({user: user, token: token, votes: votes, lpSide: lpSide}); // U:[GA-10,11,13]
    }

    /// @dev IMPLEMENTATION: unvote
    /// @param user User to assign votes to
    /// @param votes Amount of votes to add
    /// @param token Token to remove votes from
    /// @param lpSide Side to remove votes from: `true` for LP side, `false` for CA side
    function _unvote(address user, uint96 votes, address token, bool lpSide) internal {
        if (!isTokenAdded(token)) revert TokenNotAllowedException(); // U:[GA-10]

        _checkAndUpdateEpoch(); // U:[GA-11]

        QuotaRateParams storage qp = quotaRateParams[token]; // U:[GA-13]
        UserVotes storage uv = userTokenVotes[user][token]; // U:[GA-13]

        if (lpSide) {
            qp.totalVotesLpSide -= votes; // U:[GA-13]
            uv.votesLpSide -= votes; // U:[GA-13]
        } else {
            qp.totalVotesCaSide -= votes; // U:[GA-13]
            uv.votesCaSide -= votes; // U:[GA-13]
        }

        emit Unvote({user: user, token: token, votes: votes, lpSide: lpSide}); // U:[GA-13]
    }

    //
    // CONFIGURATION
    //

    /// @notice Sets the GEAR staking contract, which is the only entity allowed to vote/unvote directly
    /// @param newVoter The new voter contract
    function setVoter(address newVoter)
        external
        nonZeroAddress(newVoter)
        configuratorOnly // U:[GA-03]
    {
        if (newVoter == voter) return;
        voter = newVoter; // U:[GA-09]

        emit SetVoter({newVoter: newVoter}); // U:[GA-09]
    }

    /// @dev Adds a new quoted token to the Gauge and PoolQuotaKeeper, and sets the initial rate params
    /// @param token Address of the token to add
    /// @param minRate The minimal interest rate paid on token's quotas
    /// @param maxRate The maximal interest rate paid on token's quotas
    function addQuotaToken(address token, uint16 minRate, uint16 maxRate)
        external
        nonZeroAddress(token) // U:[GA-04]
        configuratorOnly // U:[GA-03]
    {
        _checkParams({minRate: minRate, maxRate: maxRate}); // U:[GA-04]

        quotaRateParams[token] =
            QuotaRateParams({minRate: minRate, maxRate: maxRate, totalVotesLpSide: 0, totalVotesCaSide: 0}); // U:[GA-05

        _poolQuotaKeeper().addQuotaToken({token: token}); // U:[GA-05]

        emit AddQuotaToken({token: token, minRate: minRate, maxRate: maxRate}); // U:[GA-05]
    }

    /// @dev Changes the rate params for a quoted token
    /// @param minRate The minimal interest rate paid on token's quotas
    /// @param maxRate The maximal interest rate paid on token's quotas
    function changeQuotaTokenRateParams(address token, uint16 minRate, uint16 maxRate)
        external
        nonZeroAddress(token) // U:[GA-04]
        controllerOnly // U:[GA-03]
    {
        _changeQuotaTokenRateParams(token, minRate, maxRate);
    }

    function _changeQuotaTokenRateParams(address token, uint16 minRate, uint16 maxRate) internal {
        if (!isTokenAdded(token)) revert TokenNotAllowedException(); // U:[GA-06]

        _checkParams(minRate, maxRate); // U:[GA-04]

        QuotaRateParams storage qrp = quotaRateParams[token]; // U:[GA-06]
        if (minRate == qrp.minRate && maxRate == qrp.maxRate) return;
        qrp.minRate = minRate; // U:[GA-06]
        qrp.maxRate = maxRate; // U:[GA-06]

        emit SetQuotaTokenParams({token: token, minRate: minRate, maxRate: maxRate}); // U:[GA-06]
    }

    function _checkParams(uint16 minRate, uint16 maxRate) internal pure {
        if (minRate == 0 || minRate > maxRate) {
            revert IncorrectParameterException(); // U:[GA-04]
        }
    }

    function isTokenAdded(address token) public view returns (bool) {
        return quotaRateParams[token].maxRate != 0; // U:[GA-08]
    }

    /// @dev Returns quota keeper connected to the pool
    function _poolQuotaKeeper() private view returns (IPoolQuotaKeeperV3) {
        return IPoolQuotaKeeperV3(IPoolV3(pool).poolQuotaKeeper());
    }

    /// @dev Reverts if caller is not voter
    function _revertIfCallerNotVoter() internal view {
        if (msg.sender != voter) {
            revert CallerNotVoterException(); // U:[GA-02]
        }
    }
}
