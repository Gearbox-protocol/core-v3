// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;
pragma abicoder v1;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {AddressProvider} from "@gearbox-protocol/core-v2/contracts/core/AddressProvider.sol";
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";

// interfaces
import {IGauge, QuotaRateParams, UserVotes} from "../interfaces/IGauge.sol";
import {IPoolQuotaKeeper} from "../interfaces/IPoolQuotaKeeper.sol";
import {IGearStaking} from "../interfaces/IGearStaking.sol";

import {RAY, SECONDS_PER_YEAR, MAX_WITHDRAW_FEE} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";
import {PoolV3} from "./PoolV3.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

/// @title Gauge for quota interest rates
/// @dev Quota interest rates in Gearbox V3 are determined
///      by GEAR holders voting to shift the rate within a predetermined
///      interval. While there are notable mechanic differences, the overall
///      dynamic of token holders controlling strategy yields is similar to
///      Curve's gauge system, and thus the contract carries the same name
contract Gauge is IGauge, ACLNonReentrantTrait {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    /// @notice Address of the address provider
    address public immutable addressProvider;

    /// @notice Address of the pool
    PoolV3 public immutable pool;

    /// @notice Mapping from token address to its rate parameters
    mapping(address => QuotaRateParams) public quotaRateParams;

    /// @notice Mapping from (user, token) to vote amounts committed by user to each side
    mapping(address => mapping(address => UserVotes)) userTokenVotes;

    /// @notice GEAR locking and voting contract
    IGearStaking public voter;

    /// @notice Epoch when the rates were last recomputed
    uint16 public epochLU;

    /// @notice Contract version
    uint256 public constant version = 3_00;

    //
    // CONSTRUCTOR
    //

    /// @dev Constructor
    /// @param _pool Address of the borrowing pool
    /// @param _gearStaking Address of the GEAR staking contract
    constructor(address _pool, address _gearStaking)
        ACLNonReentrantTrait(address(PoolV3(_pool).addressProvider()))
        nonZeroAddress(_pool)
        nonZeroAddress(_gearStaking)
    {
        addressProvider = address(PoolV3(_pool).addressProvider()); // F:[P4-01]
        pool = PoolV3(_pool); // F:[P4-01]
        voter = IGearStaking(_gearStaking);
        epochLU = voter.getCurrentEpoch();
    }

    /// @dev Reverts if the function is called by an address other than the voter
    modifier onlyVoter() {
        if (msg.sender != address(voter)) {
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
        uint16 epochNow = voter.getCurrentEpoch();
        if (epochNow > epochLU) {
            epochLU = epochNow;

            /// The PQK retrieves all rates from the Gauge on its own and saves them
            /// Since this function is only callable by the Gauge, active rates can only
            /// be updated once per epoch at most
            IPoolQuotaKeeper(pool.poolQuotaKeeper()).updateRates();
        }
    }

    /// @notice Computes rates for a set of tokens
    /// @dev While this will compute rates based on current votes,
    ///      the actual rates can differ, since they are only updates
    ///      once per epoch
    /// @param tokens Array of tokens to computes rates for
    /// @return rates Array of rates, in the same order as passed tokens
    function getRates(address[] memory tokens) external view override returns (uint16[] memory rates) {
        uint256 len = tokens.length;
        rates = new uint16[](len);

        for (uint256 i; i < len;) {
            address token = tokens[i];

            QuotaRateParams storage qrp = quotaRateParams[token];

            uint96 votesLpSide = qrp.totalVotesLpSide;
            uint96 votesCaSide = qrp.totalVotesCaSide;

            uint96 totalVotes = votesLpSide + votesCaSide;

            /// Quota interest rates are determined by GEAR holders through voting
            /// for one of two sides (for each token) - CA side or LP side.
            /// There are two parameters for each token determined by the governance -
            /// Min risk rate and max rate, and the actual rate fluctuates between
            /// those two extremes based on votes. Voting for CA side reduces the rate
            /// towards minRiskRate, while voting for LP side increases it towards maxRate.
            /// Rates are only updated once per epoch (1 week), to avoid manipulation and
            /// make strategies more predictable.

            rates[i] = uint16(
                totalVotes == 0
                    ? qrp.minRiskRate
                    : (qrp.minRiskRate * votesCaSide + qrp.maxRate * votesLpSide) / totalVotes
            );

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Submits a vote to move the quota rate for a token
    /// @param user The user that submitted a vote
    /// @param votes Amount of staked GEAR the user voted with
    /// @param extraData Gauge specific parameters (encoded into extraData to adhere to a general VotingContract interface)
    ///                  * token - address of the token to vote for
    ///                  * lpSide - votes in favor of LPs (increasing rate) if true, or in favor of CAs (decreasing rate) if false
    function vote(address user, uint96 votes, bytes memory extraData) external onlyVoter {
        (address token, bool lpSide) = abi.decode(extraData, (address, bool));
        _vote(user, votes, token, lpSide);
    }

    /// @dev IMPLEMENTATION: vote
    /// @param user User to assign votes to
    /// @param votes Amount of votes to add
    /// @param token Token to add votes to
    /// @param lpSide Side to add votes to: `true` for LP side, `false` for CA side
    function _vote(address user, uint96 votes, address token, bool lpSide) internal {
        _checkAndUpdateEpoch();

        QuotaRateParams storage qp = quotaRateParams[token];
        UserVotes storage uv = userTokenVotes[user][token];
        if (lpSide) {
            qp.totalVotesLpSide += votes;
            uv.votesLpSide += votes;
        } else {
            qp.totalVotesCaSide += votes;
            uv.votesCaSide += votes;
        }

        emit Vote(user, token, votes, lpSide);
    }

    /// @notice Removes the user's existing vote from the provided token and side
    /// @param user The user that submitted a vote
    /// @param votes Amount of staked GEAR to remove
    /// @param extraData Gauge specific parameters (encoded into extraData to adhere to a general VotingContract interface)
    ///                  * token - address of the token to unvote from
    ///                  * lpSide - whether the side unvoted from is LP side
    function unvote(address user, uint96 votes, bytes memory extraData) external onlyVoter {
        (address token, bool lpSide) = abi.decode(extraData, (address, bool));
        _unvote(user, votes, token, lpSide);
    }

    /// @dev IMPLEMENTATION: unvote
    /// @param user User to assign votes to
    /// @param votes Amount of votes to add
    /// @param token Token to remove votes from
    /// @param lpSide Side to remove votes from: `true` for LP side, `false` for CA side
    function _unvote(address user, uint96 votes, address token, bool lpSide) internal {
        _checkAndUpdateEpoch();

        QuotaRateParams storage qp = quotaRateParams[token];
        UserVotes storage uv = userTokenVotes[user][token];
        if (lpSide) {
            qp.totalVotesLpSide -= votes;
            uv.votesLpSide -= votes;
        } else {
            qp.totalVotesCaSide -= votes;
            uv.votesCaSide -= votes;
        }

        emit Unvote(user, token, votes, lpSide);
    }

    //
    // CONFIGURATION
    //

    /// @notice Sets the GEAR staking contract, which is the only entity allowed to vote/unvote directly
    /// @param newVoter The new voter contract
    function setVoter(address newVoter) external configuratorOnly {
        voter = IGearStaking(newVoter);

        emit SetVoter(newVoter);
    }

    /// @dev Adds a new quoted token to the Gauge and PoolQuotaKeeper, and sets the initial rate params
    /// @param token Address of the token to add
    /// @param _minRiskRate The minimal interest rate paid on token's quotas
    /// @param _maxRate The maximal interest rate paid on token's quotas
    function addQuotaToken(address token, uint16 _minRiskRate, uint16 _maxRate) external configuratorOnly {
        quotaRateParams[token] =
            QuotaRateParams({minRiskRate: _minRiskRate, maxRate: _maxRate, totalVotesLpSide: 0, totalVotesCaSide: 0});

        IPoolQuotaKeeper keeper = IPoolQuotaKeeper(pool.poolQuotaKeeper());
        keeper.addQuotaToken(token);

        emit AddQuotaToken(token, _minRiskRate, _maxRate);
    }

    /// @dev Changes the rate params for a quoted token
    /// @param _minRiskRate The minimal interest rate paid on token's quotas
    /// @param _maxRate The maximal interest rate paid on token's quotas
    function changeQuotaTokenRateParams(address token, uint16 _minRiskRate, uint16 _maxRate)
        external
        configuratorOnly
    {
        QuotaRateParams memory qrp = quotaRateParams[token];
        qrp.minRiskRate = _minRiskRate;
        qrp.maxRate = _maxRate;
        quotaRateParams[token] = qrp;

        emit SetQuotaTokenParams(token, _minRiskRate, _maxRate);
    }
}
